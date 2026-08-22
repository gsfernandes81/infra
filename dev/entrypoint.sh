#!/usr/bin/env bash
# infra-dev PID 1 (under `init: true`, so detached sessions' orphans get reaped).
#
# Order matters and is not arbitrary:
#   ssh -> claude state -> pull -> sshd host key -> [tunnel(bg)] -> sshd(fg)
# Everything that could block on a prompt is settled first, because nothing in here
# can answer one.
#
# **sshd is the FOREGROUND process, and that is the whole design.** This container is
# used by ssh-ing into it — from Termux on the phone, or from a PC — and running
# claude inside an `abduco` session there. The thing whose lifetime the container's
# lifetime should equal is therefore the door. Nothing you type can end the container:
# `exit` closes an ssh session, `/exit` closes a claude, and PID 1 has not moved.
set -u

SECRETS=/run/infra-secrets
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

say() { printf '[entrypoint] %s\n' "$*"; }

# ── ssh: keys, config, known_hosts ──────────────────────────────────────────
# /run/infra-secrets is mounted read-only, and ssh refuses a key it considers
# world-readable, so the keys are COPIED out rather than symlinked — a symlink would
# carry the mount's modes and StrictModes would reject it.
#
# .ssh/cp is ansible.cfg's ControlPath directory. ssh does not create it; every task
# fails with an opaque `unix_listener: cannot bind` if it is absent, and it is absent
# on a fresh container because ~/.ssh is not a volume.
mkdir -p "$HOME/.ssh/cp"
chmod 700 "$HOME/.ssh" "$HOME/.ssh/cp"

for key in id_ed25519_infra_deploy id_ed25519_fleet; do
    if [ -f "$SECRETS/$key" ]; then
        cp -f "$SECRETS/$key" "$HOME/.ssh/$key"
        chmod 600 "$HOME/.ssh/$key"
    else
        say "WARNING: $SECRETS/$key is missing — whatever uses it will be refused."
    fi
done

# ~/.ssh/config = the host-specific fleet blocks, THEN the baked github.com block and
# the wildcard. That order is load-bearing: ssh takes the FIRST value it obtains for
# each keyword, so a wildcard placed above a Host block silently wins over it.
#
# The fleet blocks are not in the image because they carry addresses — this repo's own
# invariant puts those in a gitignored file. Nothing in the repo writes them today:
# fleet access is the deferred control-node question, so in practice this file is absent
# and the container has no route to zero, one or two. That is the default and the
# warning below says so rather than treating it as a fault.
{
    if [ -f "$SECRETS/ssh_config.fleet" ]; then
        cat "$SECRETS/ssh_config.fleet"
        printf '\n'
    fi
    cat /home/dev/ssh_config
} > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

if [ ! -f "$SECRETS/ssh_config.fleet" ]; then
    say "WARNING: no ssh_config.fleet in $SECRETS — zero, one and two are unreachable."
    say "         That is the DEFAULT — see docs/management-plane.md. Everything else works."
fi

# authorized_keys is what lets you in at all. Without it the container comes up and
# refuses every connection, which looks like a broken sshd rather than a missing file,
# so say so loudly.
if [ -f "$SECRETS/authorized_keys" ]; then
    cp -f "$SECRETS/authorized_keys" "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
else
    say "WARNING: no authorized_keys in $SECRETS — NOTHING can ssh in. Use: make shell"
    : > "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi

# known_hosts = the fleet's own keys, then github.com's, written from scratch on every
# start. `host_key_checking = True` in ansible.cfg means an unknown key FAILS rather
# than prompting — there is no tty on an ansible connection to prompt on — so the fleet
# half is not optional, it is what makes ansible work at all.
#
# github.com's two keys are literal here for the same reason or3-dev pins them: a
# changed key should be an edit to this file that someone reads, never a first-contact
# `yes` that nobody sees.
{
    [ -f "$SECRETS/known_hosts.fleet" ] && cat "$SECRETS/known_hosts.fleet"
    cat <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
EOF
} > "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/known_hosts"

if [ ! -f "$SECRETS/known_hosts.fleet" ]; then
    say "WARNING: no known_hosts.fleet in $SECRETS — every ansible task will fail on"
    say "         host key verification, which reads as a connection error. See README."
fi

# ── Claude login ────────────────────────────────────────────────────────────
# There is NO credentials-copying path here, not even behind a flag, and that is the
# one place this deliberately does less than or3-dev. Copying the phone's
# ~/.claude/.credentials.json in was tried there and does not work: claude contacted
# the auth server one second after starting and wrote the file back with zero-length
# access and refresh tokens — the container was logged out before anyone could use it,
# and the phone's own login had by then been through a refresh it did not initiate.
#
# An OAuth login is bound to the device that performed it. or3-dev keeps the copy
# behind OR3_SEED_CLAUDE_LOGIN=1 as a documented bad idea; repeating a bad idea in a
# second container is how it stops reading as one. Log in once:
#
#     cd ~/infra/dev && make login
#
# It persists in the infra-claude volume and survives rebuilds.
mkdir -p "$CFG"

# A file left holding empty tokens is worse than no file: `claude auth status` reports
# loggedIn false either way, but the login flow can trip over the husk.
if [ -f "$CFG/.credentials.json" ] && ! grep -q '"accessToken": *"[^"]' "$CFG/.credentials.json" 2>/dev/null; then
    rm -f "$CFG/.credentials.json"
    say "removed a blanked .credentials.json — run: make login (in ~/infra/dev)"
fi

# The first-run dialogs a headless container cannot answer. Each defaults to unset on
# a fresh volume and each blocks claude on a prompt with no one there:
#   projects["/workspace"].hasTrustDialogAccepted — workspace trust. /workspace is not
#       $HOME, so unlike home-directory trust this has to be persisted.
#   theme, hasCompletedOnboarding — the first-run walkthrough.
# remoteDialogSeen is NOT seeded here, unlike or3-dev: nothing in this container starts
# remote-control, so the prompt it suppresses is one that never appears. Seeding it
# would be pre-consenting to a thing this container deliberately does not do.
python3 - "$CFG/.claude.json" /workspace <<'PY' || say "could not pre-seed .claude.json"
import json, os, sys

path, project = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        cfg = {}
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

dirty = False
entry = cfg.setdefault("projects", {}).setdefault(project, {})
if entry.get("hasTrustDialogAccepted") is not True:
    entry["hasTrustDialogAccepted"] = True
    dirty = True
if not cfg.get("theme"):
    cfg["theme"] = "dark"
    dirty = True
if cfg.get("hasCompletedOnboarding") is not True:
    cfg["hasCompletedOnboarding"] = True
    dirty = True

if dirty:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
PY

# ── the workspace ───────────────────────────────────────────────────────────
git config --global --add safe.directory /workspace 2>/dev/null || true
git config --global user.name  "${GIT_USER_NAME:-Gavin Fernandes}"
git config --global user.email "${GIT_USER_EMAIL:-gavinfernandes2012@pm.me}"

# Pull on start. --ff-only, and never fatal: a container that will not come up because
# the network is down, or because the tree has local work, is worse than one running a
# slightly old checkout — and /workspace is the HOST's clone, so a merge started here
# would be left half-done in the host's working tree.
if [ -d /workspace/.git ]; then
    if git -C /workspace pull --ff-only 2>&1 | sed 's/^/[entrypoint] git: /'; then :; else
        say "pull skipped (not fast-forward, or offline) — the checkout is unchanged"
    fi
fi

# ── sshd host key ───────────────────────────────────────────────────────────
mkdir -p "$HOME/.ssh-host"
chmod 700 "$HOME/.ssh-host"
[ -f "$HOME/.ssh-host/ssh_host_ed25519_key" ] || \
    ssh-keygen -t ed25519 -f "$HOME/.ssh-host/ssh_host_ed25519_key" -N "" -C infra-dev >/dev/null

# ssh sessions do not inherit this process's env, so publish it for sshd to read via
# PermitUserEnvironment. ANSIBLE_CONFIG is the one that matters: without it an ssh
# session gets no ansible.cfg unless it happens to be sitting in /workspace/ansible,
# and the symptom is "No inventory was parsed", which reads as a broken inventory
# rather than a wrong directory.
#
# One KEY=value per line, unquoted — that format takes no quoting, and shell noise in
# it makes sshd reject the whole file.
mkdir -p "$HOME/.local/share"
{
    echo "PATH=$PATH"
    env | grep -vE '^(PATH|PWD|SHLVL|_|HOME|OLDPWD|HOSTNAME)='
} > "$HOME/.ssh/environment"
chmod 600 "$HOME/.ssh/environment"

# ── the tunnel — INERT unless asked for ─────────────────────────────────────
# Two things must both be true or nothing starts: DEV_TUNNEL_HOSTNAME is set, and a
# credentials file exists in the read-only secrets mount. That is deliberate — the
# container must come up and be usable over the loopback port on a box that has never
# had a tunnel created for it, which is every box before the tunnel playbook is run.
#
# LOCALLY-MANAGED, not token-based, and that is the whole reason this is shaped the way
# it is. The host tunnels use `--token <secret>`, which puts a live credential in argv —
# host-setup.md's token-in-argv leak, and management-plane.md's rule that secrets never
# go in command_args. In a container there is no supervise-daemon writing argv to
# syslog, but `docker inspect` shows both argv and env, and .Config.Env is exactly what
# audit.yml refuses to read because it holds secrets. A credentials FILE, mounted
# read-only, is the spelling that puts the secret in neither.
#
# The second dividend is that ingress lives in a config file rather than in the
# Cloudflare dashboard, so what this container answers on is reviewable here.
TUNNEL_CREDS="$SECRETS/tunnel.json"
if [ -n "${DEV_TUNNEL_HOSTNAME:-}" ] && [ -s "$TUNNEL_CREDS" ]; then
    mkdir -p "$HOME/.cloudflared"
    chmod 700 "$HOME/.cloudflared"

    # The tunnel UUID comes out of the credentials file rather than being a second
    # setting. One source, so a config naming one tunnel and a credentials file for
    # another is not a state this can be in.
    TUNNEL_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["TunnelID"])' \
                 "$TUNNEL_CREDS" 2>/dev/null || true)"

    if [ -z "$TUNNEL_ID" ]; then
        say "WARNING: $TUNNEL_CREDS has no TunnelID — not starting the tunnel."
        say "         Re-run ansible/playbooks/cloudflare-dev-tunnel.yml; loopback works."
    else
        # metrics on 20241 to match what the host tunnels use, because that is the probe
        # recovery.md already trusts: /ready with readyConnections >= 1 was chosen there
        # over port-7844 socket counts and the log file, both of which read DEAD against
        # a tunnel that was serving normally. Reusing a probe that has been calibrated
        # against known-good state beats inventing a second one.
        cat > "$HOME/.cloudflared/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $TUNNEL_CREDS
metrics: 127.0.0.1:20241
no-autoupdate: true
ingress:
  - hostname: $DEV_TUNNEL_HOSTNAME
    service: ssh://localhost:2222
  - service: http_status:404
EOF
        # Bounded retry, and the bound counts CONSECUTIVE failures rather than restarts.
        # A transient edge or DNS failure at start must not leave the tunnel down for the
        # life of the container; a bad credentials file must not spin forever pretending
        # it might come good. Those want opposite treatment, and what tells them apart is
        # whether the last run achieved anything.
        #
        # ANY REAL UPTIME RESETS THE COUNT — or3's fetch_payload.py arrived at the same
        # rule for the same reason: "any forward progress resets the retry count, so a
        # flaky link is not mistaken for a dead one". A plain counter spends its six lives
        # on six ordinary reconnections over a fortnight and then quits on a tunnel that
        # had been serving perfectly, at an hour nobody chose. 60s is the line: an auth or
        # config failure is over in under a second, and anything that stayed up a minute
        # was connected.
        setsid bash -c '
            fails=0
            while [ "$fails" -lt 6 ]; do
                started=$(date +%s)
                echo "[tunnel] $(date -u +%FT%TZ) starting cloudflared (consecutive failures: $fails)"
                cloudflared --no-autoupdate --config "$HOME/.cloudflared/config.yml" --loglevel info tunnel run
                rc=$?
                ran=$(( $(date +%s) - started ))
                if [ "$ran" -ge 60 ]; then
                    echo "[tunnel] exited rc=$rc after ${ran}s of uptime — that was a real"
                    echo "[tunnel] connection, so the failure count resets to 0"
                    fails=0
                else
                    fails=$(( fails + 1 ))
                    echo "[tunnel] exited rc=$rc after only ${ran}s — failure $fails of 6"
                fi
                sleep $(( fails * 10 + 5 ))
            done
            echo "[tunnel] GAVE UP: six consecutive failures, none lasting 60s. That is a"
            echo "[tunnel] configuration or credentials problem, not a flaky link."
            echo "[tunnel] The container is unaffected and the loopback port still works:"
            echo "[tunnel]   ssh zero, then ssh -p <DEV_SSH_PORT> dev@127.0.0.1"
        ' </dev/null >>"$HOME/.local/share/tunnel.log" 2>&1 &
        say "tunnel starting for $DEV_TUNNEL_HOSTNAME (log: ~/.local/share/tunnel.log)"
    fi
elif [ -n "${DEV_TUNNEL_HOSTNAME:-}" ]; then
    say "DEV_TUNNEL_HOSTNAME is set but $TUNNEL_CREDS is missing — no tunnel."
    say "    Run ansible/playbooks/cloudflare-dev-tunnel.yml. Loopback is unaffected."
else
    say "no tunnel (DEV_TUNNEL_HOSTNAME unset — see dev/README.md § Cloudflare)"
fi

# ── sshd, in the foreground ─────────────────────────────────────────────────
# The container's payload. exec, so sshd IS this process: signals from `docker stop`
# reach it directly and the container's lifetime is exactly the door's.
#
# -D stops it daemonising — daemon(0,0) would point its stderr at /dev/null and throw
# away the -e log that `docker logs infra-dev` is now made of.
#
# Nothing beyond this line runs. A start-up failure is in the log above it, which is
# what `make boot-log` prints.
say "sshd on :2222 in the foreground — ssh in and work in an abduco session"
say "    ssh infra-dev                              a shell"
say "    ssh -t infra-dev abduco -A claude claude   a claude that survives the link"
exec /usr/sbin/sshd -D -e -f /home/dev/sshd_config
