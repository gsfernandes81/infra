#!/usr/bin/env bash
# PID 1 of the hub (under `init: true`). In order, because each step needs the one before:
#
#   hub key -> install into the shared volume -> GitHub tokens (first pass, then bg)
#   -> the container list -> sshd host key and authorized_keys -> environment for logins
#   -> mail loop (bg) -> [offloader (bg)] -> sshd (fg)
#
# Everything ahead of sshd is bounded and non-fatal, as in the dev containers' entrypoint:
# the door is the one thing that must come up. The compose healthcheck reads what the
# install step wrote, and every dev container waits on it (depends_on: service_healthy), so
# a container never starts against an empty volume.
#
# What it reads from the environment (dev/compose.yaml sets each):
#   HUB_REPO_<NAME>         each container's repo; the names ARE the containers the menu and
#                           the offloader reach, exported below as CLAUDE_SESSIONS_HOSTS
#   CLAUDE_SESSIONS_REMOTE  the binary's path inside them (/opt/claude-sessions/bin/…)
#   HUB_OFFLOAD             0 stops the offload timer starting                     (1)
#   HUB_GITHUB_*, HUB_REPO_*  the token broker's; github-tokens' own header lists them
#   HUB_MAIL, HUB_MAIL_*    the mail loop's (the volume, the limits, the tick); read by
#                           `claude-sessions mail-loop` itself, this file only names the dir
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
        # SUPERVISED: if the loop ever exits, it is said in the log and started again a minute
        # later, minting at once; --skip-first only on the first launch, because the pass just
        # above has minted already (one token per container per start, not two).
        setsid bash -c '
            first=--skip-first
            while :; do
                github-tokens loop "$1" $first
                rc=$?
                printf "%s the token loop exited (%s) — starting it again in 60 s\n" \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$1"
                first=
                sleep 60
            done' _ "$STATE/github-tokens.log" </dev/null >> "$STATE/github-tokens.log" 2>&1 &
    fi
    # ONLY HERE: the directories exist, so every container's subpath mount can be made. Without
    # them the hub stays unhealthy, which is true, and no dev container starts against it.
    : > "$TOKENS/.ready"
else
    say "WARNING: could not make the token directories — the hub stays unhealthy and no dev container starts"
fi

# ── which containers ───────────────────────────────────────────────────────────
# ONE LIST: the containers the hub mints tokens for are the containers it manages — the
# HUB_REPO_* names compose gives this container, sorted. Before the environment file below and
# the offload loop, which both carry it.
CLAUDE_SESSIONS_HOSTS="$(github-tokens hosts)"
export CLAUDE_SESSIONS_HOSTS

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

# ── agent mail: the loop that carries messages between the containers ──────────
# `claude-sessions mail-loop` (0.8.0; claude-sessions' docs/design.md § Agent mail, infra's
# decisions.md § Agent mail) pulls every container's /workspace/.mail/out/ into the `mail`
# volume at $HUB_MAIL, stamps the sender from the container it read, and pushes each queue
# into its receiver's /workspace/.mail/in/ — over the same ssh as everything else, so no
# container gains a credential. The limits and the tick are HUB_MAIL_* in the environment,
# which the loop reads itself; compose sets them. SUPERVISED like the token loop: an exit is
# said in the log and the loop starts again a minute later. One line per event in
# ~/.hub/mail.log, never a body; the loop touches $HUB_MAIL/.beat after every tick, and
# hub-health reads its age. AFTER the container list above, which the loop takes from
# CLAUDE_SESSIONS_HOSTS; a stopped container is skipped by the loop, said once, not an error.
HUB_MAIL="${HUB_MAIL:-$HOME/mail}"
export HUB_MAIL
if [ -d "$HUB_MAIL" ]; then
    # Touched now as offload.beat is: a hub that has only just started is not held unhealthy
    # for the 15 s before the first tick.
    touch "$HUB_MAIL/.beat"
    setsid bash -c '
        while :; do
            claude-sessions mail-loop
            rc=$?
            printf "%s the mail loop exited (%s) — starting it again in 60 s\n" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$1"
            sleep 60
        done' _ "$STATE/mail.log" </dev/null >> "$STATE/mail.log" 2>&1 &
    say "mail loop every ${HUB_MAIL_TICK:-15}s over: ${CLAUDE_SESSIONS_HOSTS:-(none)} — the volume at $HUB_MAIL, every event in ~/.hub/mail.log"
else
    say "WARNING: $HUB_MAIL is not a directory — no mail loop; the hub stays unhealthy"
fi

# ── the offloader, for every container ──────────────────────────────────────────
# `claude-sessions offload-all` runs `claude-sessions offload` in each container over ssh, all
# at once, and prints each container's lines prefixed with its name. THE 3-MINUTE CADENCE IS
# LOAD-BEARING (the CPU budget is per window), so the loop sleeps to a fixed rate. Each pass is
# kept, timestamped, in ~/.hub/passes.log, trimmed past 16 MB to its newest 8 MB from the first
# whole line, through a temp file and a rename — the per-container loop's rules, moved here.
# ONE SWITCH: HUB_OFFLOAD=0 stops the timer for every container. A slot that must stay loaded
# holds itself with `claude-sessions keepalive`, which every claude learns from the skill.
if [ "${HUB_OFFLOAD:-1}" = "1" ]; then
    # offload.beat is touched now and after every pass: hub-health reads its age, so a loop
    # that dies or wedges turns the hub unhealthy rather than going quiet.
    touch "$STATE/offload.beat"
    setsid bash -c '
        skipped=
        while :; do
            start=$(date +%s)
            stamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
            # ONLY THE CONTAINERS THAT ARE UP: a stopped one has no name on the project network,
            # so its pass would fail every 3 minutes ("Could not resolve hostname") for a state
            # someone chose — `make stop C=<name>`. Said once in the log when the
            # set changes, not on every pass; the menu shows them as not answering meanwhile.
            up= down=
            for h in $CLAUDE_SESSIONS_HOSTS; do
                if getent hosts "$h" >/dev/null 2>&1; then up="$up $h"; else down="$down $h"; fi
            done
            if [ "$down" != "$skipped" ]; then
                printf "%s not running, so not offloaded:%s\n" "$stamp" "${down:- none}" >> "$1"
                skipped=$down
            fi
            # An empty list would make the claude-sessions wrapper derive every container again.
            if [ -n "$up" ]; then
                out=$(CLAUDE_SESSIONS_HOSTS="${up# }" timeout 150 claude-sessions offload-all 2>&1)
                rc=$?
            else
                out= rc=0
            fi
            [ -n "$out" ] && printf "%s\n" "$out" | sed "s/^/$stamp /" >> "$1"
            if [ "$rc" -ne 0 ]; then
                printf "%s offload pass failed: exit %s%s\n" "$stamp" "$rc" \
                    "$([ "$rc" -eq 124 ] && echo " (timed out after 150 s)")" >> "$1"
            fi
            if [ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -gt 16777216 ]; then
                tail -c 8388608 "$1" | tail -n +2 > "$1.tmp" && mv -f "$1.tmp" "$1"
            fi
            touch "${1%/*}/offload.beat"
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
