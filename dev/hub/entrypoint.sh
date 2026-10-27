#!/usr/bin/env bash
# PID 1 of the hub (under `init: true`). In order, because each step needs the one before:
#
#   hub key -> install into the shared volume -> GitHub tokens (first pass, then bg)
#   -> sshd host key and authorized_keys -> environment for logins -> [offloader (bg)]
#   -> sshd (fg)
#
# Everything ahead of sshd is bounded and non-fatal, as in the dev containers' entrypoint:
# the door is the one thing that must come up. The compose healthcheck reads what the
# install step wrote, and every dev container waits on it (depends_on: service_healthy), so
# a container never starts against an empty volume.
#
# What it reads from the environment (dev/compose.yaml sets each):
#   CLAUDE_SESSIONS_HOSTS   the containers, by name on the `dev` network
#   CLAUDE_SESSIONS_REMOTE  the binary's path inside them (/opt/claude-sessions/bin/…)
#   HUB_OFFLOAD             0 stops the offload timer starting                     (1)
#   HUB_GITHUB_*, HUB_REPO_*  the token broker's; github-tokens' own header lists them
set -u

say() { printf '[hub] %s\n' "$*"; }
STATE="$HOME/.hub"
SHARED=/opt/claude-sessions
SECRETS=/run/hub-secrets

mkdir -p "$STATE" "$HOME/.ssh/cm"
chmod 700 "$STATE" "$HOME/.ssh" "$HOME/.ssh/cm"

# ── the hub's key — made once, kept in its own volume, never anywhere else ──────
# The key every dev container authorises. It lives only here: this container runs no agent,
# and the volume it is in is mounted by nothing else (decisions.md, the dev-pool rows).
if [ ! -f "$STATE/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "dev-hub" -f "$STATE/id_ed25519"
    say "made the hub's key: $STATE/id_ed25519"
fi
chmod 600 "$STATE/id_ed25519"

# ── into the shared volume: the binary, its hooks drop-in, the skill, the key's public half ──
# `claude-sessions install` writes each through a temporary name and a rename, so a container
# reading mid-install sees the old file or the new one; a hook already running keeps the binary
# it started from. The public key the same way, by hand: `>` onto the target would truncate it
# first and follow a link (CLAUDE.md § Shell traps).
if out=$(timeout 30 claude-sessions install "$SHARED" 2>&1); then
    say "claude-sessions $(claude-sessions --version | cut -d' ' -f2) installed into $SHARED"
else
    say "WARNING: claude-sessions install failed — the containers keep whatever $SHARED held:"
    printf '%s\n' "$out" | sed 's/^/[hub]     /'
fi
rm -f "$SHARED/.hub.pub.tmp"
if cp "$STATE/id_ed25519.pub" "$SHARED/.hub.pub.tmp" && chmod 644 "$SHARED/.hub.pub.tmp" \
    && mv -fT "$SHARED/.hub.pub.tmp" "$SHARED/hub.pub"; then
    say "hub key published: $SHARED/hub.pub (each container authorises it at its start)"
else
    rm -f "$SHARED/.hub.pub.tmp"
    say "WARNING: could not publish the hub key — no container will let the hub in"
fi

# ── GitHub tokens: one per container, each restricted to that container's repo ─────
# Each dev container mounts only its own directory of the tokens volume, read-only, as a
# SUBPATH — which must exist before the container can start at all. So the directories are
# made unconditionally, the first pass runs before the hub reports healthy (bounded: GitHub
# being down must not keep every container from starting; each then falls back to its own gh
# login and deploy key), and only then is .ready written, which the healthcheck waits for.
# With HUB_GITHUB_APP_ID empty the broker is off and says so once; nothing else changes.
TOKENS="${HUB_GITHUB_TOKENS:-$HOME/tokens}"
rm -f "$TOKENS/.ready"   # a marker from the last start would report this one ready early
if github-tokens dirs; then
    timeout 60 github-tokens once >> "$STATE/github-tokens.log" 2>&1 \
        || say "WARNING: the first GitHub token pass failed or timed out — ~/.hub/github-tokens.log"
    tail -n 5 "$STATE/github-tokens.log" 2>/dev/null | sed 's/^/[hub] github: /'
    if [ -n "${HUB_GITHUB_APP_ID:-}" ]; then
        setsid github-tokens loop "$STATE/github-tokens.log" </dev/null \
            >> "$STATE/github-tokens.log" 2>&1 &
    fi
else
    say "WARNING: could not make the token directories — containers whose mount needs one will not start"
fi
: > "$TOKENS/.ready"

# ── sshd: host key, and who may log in ─────────────────────────────────────────
[ -f "$STATE/ssh_host_ed25519_key" ] || \
    ssh-keygen -q -t ed25519 -N '' -C dev -f "$STATE/ssh_host_ed25519_key"
if [ -s "$SECRETS/authorized_keys" ]; then
    rm -f "$HOME/.ssh/authorized_keys"
    cp "$SECRETS/authorized_keys" "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
else
    say "WARNING: no authorized_keys in $SECRETS — NOTHING can ssh in. From zero:"
    say "         ssh -t zero 'cd ~/infra/dev && make shell C=hub'"
    rm -f "$HOME/.ssh/authorized_keys"
    : > "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi

# A login does not inherit this process's environment; sshd reads this file for it
# (PermitUserEnvironment). One KEY=value a line, no quoting.
rm -f "$HOME/.ssh/environment"
{
    echo "PATH=$PATH"
    env | grep -E '^(CLAUDE_SESSIONS_[A-Z_]*|TZ)='
} > "$HOME/.ssh/environment"
chmod 600 "$HOME/.ssh/environment"

# ── the offloader, for every container ──────────────────────────────────────────
# `claude-sessions offload-all` runs `claude-sessions offload` in each container over ssh, all
# at once, and prints each container's lines prefixed with its name. THE 3-MINUTE CADENCE IS
# LOAD-BEARING (the CPU budget is per window), so the loop sleeps to a fixed rate. Each pass is
# kept, timestamped, in ~/.hub/passes.log, trimmed past 16 MB to its newest 8 MB from the first
# whole line, through a temp file and a rename — the per-container loop's rules, moved here.
# A container whose owner wants nothing stopped sets DEV_IDLE_OFFLOAD=0 in dev/.env, which its
# compose service turns into CLAUDE_SESSIONS_OFFLOAD=0: its pass says so and stops nothing.
if [ "${HUB_OFFLOAD:-1}" = "1" ]; then
    setsid bash -c '
        while :; do
            start=$(date +%s)
            stamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
            out=$(timeout 150 claude-sessions offload-all 2>&1)
            rc=$?
            [ -n "$out" ] && printf "%s\n" "$out" | sed "s/^/$stamp /" >> "$1"
            if [ "$rc" -ne 0 ]; then
                printf "%s offload pass failed: exit %s%s\n" "$stamp" "$rc" \
                    "$([ "$rc" -eq 124 ] && echo " (timed out after 150 s)")" >> "$1"
            fi
            if [ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -gt 16777216 ]; then
                tail -c 8388608 "$1" | tail -n +2 > "$1.tmp" && mv -f "$1.tmp" "$1"
            fi
            elapsed=$(( $(date +%s) - start ))
            sleep $(( elapsed < 179 ? 180 - elapsed : 1 ))
        done' _ "$STATE/passes.log" </dev/null >/dev/null 2>&1 &
    say "offload-all every 3m over: ${CLAUDE_SESSIONS_HOSTS:-(none)} — every pass in ~/.hub/passes.log"
else
    say "offloader off (HUB_OFFLOAD=${HUB_OFFLOAD}) — idle sessions keep their memory"
fi

# ── sshd, in the foreground ─────────────────────────────────────────────────────
say "sshd on :2222 — ssh dev lands on the menu over: ${CLAUDE_SESSIONS_HOSTS:-(none)}"
exec /usr/sbin/sshd -D -e -f /home/dev/sshd_config
