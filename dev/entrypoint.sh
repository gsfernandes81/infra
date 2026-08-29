#!/usr/bin/env bash
# PID 1 for every container built on this base (under `init: true`, so detached
# sessions' orphans get reaped).
#
# Order matters and is not arbitrary:
#   ssh -> claude state -> pull -> sshd host key -> [rc(bg)] -> [tunnel(bg)] -> sshd(fg)
# Everything that could block on a prompt is settled first, because nothing in here
# can answer one.
#
# **sshd is the FOREGROUND process, and that is the whole design.** This container is
# used by ssh-ing into it — from Termux on the phone, or from a PC — and running
# claude inside an `abduco` session there. The thing whose lifetime the container's
# lifetime should equal is therefore the door. Nothing you type can end the container:
# `exit` closes an ssh session, `/exit` closes a claude, and PID 1 has not moved.
set -u

# WHAT THIS IS PARAMETERISED BY, because it serves more than one container now.
# Every default below is infra-dev's own behaviour, so a child that sets none of these
# gets exactly what this file did when it was infra-dev's alone:
#
#   DEV_NAME             the container's name in the lines this prints  (default: hostname)
#   DEV_SECRETS_DIR      where the read-only secrets mount lands        (/run/infra-secrets)
#   DEV_TUNNEL_HOSTNAME  cloudflared's ingress hostname                 (unset = no tunnel)
#   DEV_CHILD_INIT_TIMEOUT  seconds child-init.sh gets before it is killed        (600)
#   DEV_IDLE_OFFLOAD     0 stops the idle-claude offloader starting     (1)
#   DEV_IDLE_OFFLOAD_SECONDS / DEV_IDLE_POLL_SECONDS — offload-idle-claude.sh's own
#
# DEV_REMOTE_CONTROL IS GONE, 2026-08-25. Every container on this fleet is now reached the
# same way — ssh in, work in an abduco session — and none of them ships a remote-control
# daemon for this to start. A variable that names a thing no image contains is a variable
# somebody sets and then wonders about, so it is removed rather than left inert.
#
# and two files a child BAKES rather than sets, because their content is tracked and
# reviewable rather than host-specific:
#
#   /home/dev/ssh_config          its own ~/.ssh/config — infra-dev's names the fleet,
#                                 or3-dev's names or3ecr through the phone's tunnel
#   /home/dev/known_hosts.extra   host keys pinned in the child's own repo
#   /home/dev/child-init.sh       run at start, below — RUN WITH `bash`, so a child's own
#                                 shebang is not honoured and a script written for another
#                                 interpreter is parsed as bash. It is a hook in a bash
#                                 entrypoint, not a program the image execs.
SECRETS="${DEV_SECRETS_DIR:-/run/infra-secrets}"
DEV_NAME="${DEV_NAME:-$(hostname)}"
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

# EVERY private key in the mount, rather than a list of names. The names are precisely
# what differs per container — infra-dev has id_ed25519_infra_deploy and
# id_ed25519_fleet, or3-dev has id_ed25519_or3_deploy and id_ed25519_or3ecr_m — and a
# list baked here is a list the base has to know about its children.
#
# `.pub` halves are skipped: ssh does not need them, and a 600 on a public key reads as
# a secret to whoever finds it later.
#
# The old spelling named each missing key, and what replaces that is deliberate rather
# than lost. WHICH keys a container should have is stated in its own ~/.ssh/config, and
# an IdentityFile that is not there fails at the moment it is used, naming the file. A
# list here could only ever repeat that statement, one image layer further from it.
#
# The test is the file's own first line, not its name. A name test would take
# `id_ed25519_fleet.bak` — and stale key backups beside the original are a thing that
# has recurred on this fleet twice, which CLAUDE.md § *Backups of secret-bearing files*
# is about. IdentitiesOnly makes an extra key harmless rather than dangerous, but a
# mode-600 copy of a rotated-out key in ~/.ssh is exactly the artefact that rule exists
# to stop being left lying around.
copied=0
for key in "$SECRETS"/id_*; do
    [ -f "$key" ] || continue          # also the no-match case: the glob stays literal
    head -1 "$key" 2>/dev/null | grep -q -- '-----BEGIN .*PRIVATE KEY-----' || continue
    cp -f "$key" "$HOME/.ssh/${key##*/}"
    chmod 600 "$HOME/.ssh/${key##*/}"
    copied=$((copied + 1))
done
if [ "$copied" = 0 ]; then
    say "WARNING: no id_* keys in $SECRETS — git push, and every ssh out of here, will be refused."
fi

# ~/.ssh/config = the host-specific fleet blocks, THEN the baked github.com block and
# the wildcard. That order is load-bearing: ssh takes the FIRST value it obtains for
# each keyword, so a wildcard placed above a Host block silently wins over it.
#
# The fleet blocks are not in the image because they carry addresses — this repo's own
# invariant puts those in a gitignored file. Nothing in the repo writes them today:
# fleet access is the deferred control-node question, so in practice this file is absent
# and the container has no route to zero, one or two. That is the default and the
# warning below says so rather than treating it as a fault.
#
# `rm -f` FIRST, AND THAT LINE IS LOAD-BEARING. A redirection follows a symlink and
# truncates its TARGET, so if anything in this container has made ~/.ssh/config a symlink
# — a child's child-init.sh pointing it at a file in the bind mount, or a person doing the
# same by hand — this write lands in that file instead. ~/.ssh is not a volume, but a
# `docker stop`/`start` reuses the container's filesystem, so the second boot is where it
# fires: the host's own gitignored ssh config is overwritten with the lines below, and the
# only sign is that pushes start failing. It is CLAUDE.md § *Shell traps*' first entry
# aimed at a path this file writes every start rather than at a file somebody names once.
rm -f "$HOME/.ssh/config"
{
    if [ -f "$SECRETS/ssh_config.fleet" ]; then
        cat "$SECRETS/ssh_config.fleet"
        printf '\n'
    fi
    cat /home/dev/ssh_config
} > "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

#
# SPLIT BY WHOSE CONTAINER THIS IS. The fleet sentence is infra-dev's: it names three
# hosts that mean nothing in or3-dev, dd-dev or ds-dev, and a warning that names the
# wrong thing is worse than none — it sends whoever reads it to look at a mount that was
# never meant to hold that file. A child that named its own DEV_SECRETS_DIR is by
# definition not infra-dev, so it gets the plain statement of what did not happen.
if [ ! -f "$SECRETS/ssh_config.fleet" ]; then
    if [ -z "${DEV_SECRETS_DIR:-}" ]; then
        say "WARNING: no ssh_config.fleet in $SECRETS — zero, one and two are unreachable."
        say "         That is the DEFAULT — see docs/management-plane.md. Everything else works."
    else
        say "no ssh_config.fleet in $SECRETS — nothing is prepended to ~/.ssh/config."
    fi
fi

# authorized_keys is what lets you in at all. Without it the container comes up and
# refuses every connection, which looks like a broken sshd rather than a missing file,
# so say so loudly.
#
# THE MIDDLE BRANCH IS NOT A SPECIAL CASE, it is the drop-in seam telling the truth. A
# child may point sshd at a different file — dd-dev and ds-dev serve the HOST account's
# authorized_keys, bind-mounted read-only, which is how those two were reached before
# they were built on this base and is not a thing to re-key. sshd takes the first
# AuthorizedKeysFile it obtains and the Include is at the top of sshd_config, so a
# drop-in wins; this file is then simply not what the door reads, and saying "NOTHING can
# ssh in" about it would be false at the moment it is most likely to be believed.
#
# The test is the drop-in's own text rather than an environment variable, for the reason
# `sshd -t` runs before the exec: the artefact is the authority on what sshd will do, and
# a flag is a second place for that to be stated wrongly.
#
# `*.conf` AND NOT THE WHOLE DIRECTORY. That glob is what the Include globs, so a
# `10-authorized-keys.conf.bak` or a README in there is not something sshd reads — and a
# stale `.bak` beside the original is the artefact CLAUDE.md § *Backups of secret-bearing
# files* has now found on this fleet twice. Testing the directory recursively would let
# exactly that file silence the one warning that says the door is shut. The glob is
# unquoted, and the no-match case stays literal and fails the grep, which is the answer
# wanted anyway.
if grep -qiE '^[[:space:]]*AuthorizedKeysFile' /home/dev/sshd_config.d/*.conf 2>/dev/null; then
    authkeys_dropin=1
else
    authkeys_dropin=
fi

if [ -f "$SECRETS/authorized_keys" ]; then
    cp -f "$SECRETS/authorized_keys" "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
    # BOTH present is the quietly wrong case, and the mirror of the one above: the copy
    # just made lands in a file the door does not read, so a key added to the mount has
    # no effect and nothing says so. First-match-wins cuts this way too.
    [ -z "$authkeys_dropin" ] || \
        say "NOTE: a drop-in sets AuthorizedKeysFile — the copy from $SECRETS is NOT what sshd reads."
elif [ -n "$authkeys_dropin" ]; then
    say "authorized_keys comes from a drop-in in sshd_config.d, not from $SECRETS."
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
# github.com's two keys are literal here for the same reason or3-dev pins or3ecr's: a
# changed key should be an edit to a tracked file that someone reads, never a
# first-contact `yes` that nobody sees.
#
# known_hosts.extra is that same rule for a CHILD's hosts. It is a baked file and not a
# secrets-mount one, and the difference is the point: or3ecr's key is not a secret and
# not host-specific, it is a pin, and a pin belongs where a diff shows it changing.
{
    [ -f /home/dev/known_hosts.extra ] && cat /home/dev/known_hosts.extra
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
#
# remoteDialogSeen WAS SEEDED HERE and is not any more, 2026-08-25. It suppresses the
# one-time "Enable Remote Control? [y/N]" consent, which only a container that starts a
# remote-control daemon ever meets — and no container on this fleet does. Seeding it now
# would be pre-consenting, on four containers, to a thing none of them does.
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

# The host's clone has an https `origin`, and the only git credential in here is the
# deploy key copied out of the secrets mount above — an ssh credential. Rewrite the
# TRANSPORT rather than the remote: --global is /home/dev/.gitconfig, which is neither
# the bind mount nor one of the four named volumes, so the host's .git/config is left
# exactly as it is and gavin's own git on zero keeps working the way it does today.
#
# THE TWO SIBLING REPOS DIVERGE HERE and this follows destiny-director, not or3.
# or3 needs no rewrite because its clone is made over ssh to begin with
# (or3/dev/seed-secrets.sh) — a fix that lives on the host and cannot be shipped in an
# image. destiny-director/docker-entrypoint.dev.sh does this, for the same reason it
# applies here: the host stays on https and nothing outside the container has to change.
# It is also a no-op if that clone is ever re-made over ssh — insteadOf rewrites https
# URLs and leaves git@ ones alone — so the two approaches do not fight.
#
# Without this, the --ff-only pull below has never once run: it fails on "could not read
# Username", and the message in its failure branch names neither cause.
git config --global url."git@github.com:".insteadOf "https://github.com/"

# Pull on start. --ff-only, and never fatal: a container that will not come up because
# the network is down, or because the tree has local work, is worse than one running a
# slightly old checkout — and /workspace is the HOST's clone, so a merge started here
# would be left half-done in the host's working tree.
#
# ${PIPESTATUS[0]}, AND NOT THE PIPELINE'S OWN STATUS. `if git … | sed …` tests SED, so
# the branch below had never once been taken — a failed pull printed git's error and then
# nothing, which reads as a pull that worked. That is the trap CLAUDE.md § *Shell traps*
# states in the abstract, sitting in this file.
#
# `set -o pipefail` was the first fix and is not the right one: it answers "did anything
# in the pipeline fail", so a `sed` that dies on a full stdout would make a pull that
# SUCCEEDED print "the checkout is unchanged" — a false statement about the tree, from
# the fix for a false statement about the tree. PIPESTATUS[0] asks the question actually
# being asked. It must be read before anything else runs; the assignment is that read.
if [ -d /workspace/.git ]; then
    git -C /workspace pull --ff-only 2>&1 | sed 's/^/[entrypoint] git: /'
    pull_rc=${PIPESTATUS[0]}
    [ "$pull_rc" = 0 ] || \
        say "pull skipped (not fast-forward, or offline) — the checkout is unchanged"
fi

# ── the child's own start-up, if it ships one ───────────────────────────────
# THE FIFTH SEAM, added 2026-08-24 for dd-dev and ds-dev. Both bake their dependencies
# into /home/dev/venv at build time and both must add the editable project once
# /workspace is mounted, which is a thing to RUN at start and not a file to place — so
# none of the other four seams could express it, and this file's own header says that is
# when the base changes.
#
# HERE AND NOT EARLIER: after the pull, so a lockfile that just moved is the one the
# child installs from; before the supervisor and before sshd, so no session — remote
# control's or a person's — can arrive to a half-installed environment. A child that
# wraps the CMD instead gets neither of those, which is why this is a hook and not a
# convention.
#
# NON-FATAL, like the pull above and for the same reason: the door is the one thing that
# must come up. A child whose venv did not sync is a container you can ssh into and fix;
# a container that refused to start over it is one nobody on this fleet has a route to.
# The failure is loud, and it is the child's own output that says what broke.
#
# AND BOUNDED, because non-fatal only covers the half of that which EXITS. This runs
# ahead of sshd, so a child-init that hangs — `uv sync` blocked on a lock in the bind
# mount another container holds, or retrying against a network that is down rather than
# refusing — costs the door just as completely as a fatal one would, and on a
# `restart: no` container nobody in an agent session has a route to. `timeout` makes the
# hang land in the same warning branch as the failure. -k because timeout signals only
# the process it started, and uv's children would otherwise outlive it.
CHILD_INIT_TIMEOUT="${DEV_CHILD_INIT_TIMEOUT:-600}"
if [ -f /home/dev/child-init.sh ]; then
    say "child-init.sh — this image's own start-up (up to ${CHILD_INIT_TIMEOUT}s)"
    timeout -k 10 "$CHILD_INIT_TIMEOUT" bash /home/dev/child-init.sh 2>&1 \
        | sed 's/^/[child-init] /'
    rc=${PIPESTATUS[0]}
    if [ "$rc" = 0 ]; then
        say "child-init.sh finished"
    elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
        say "WARNING: child-init.sh still running after ${CHILD_INIT_TIMEOUT}s — killed so"
        say "         sshd can start. Whatever it sets up is INCOMPLETE. Its output is above."
    else
        say "WARNING: child-init.sh exited $rc — starting anyway. Its output is above."
    fi
fi

# ── sshd host key ───────────────────────────────────────────────────────────
mkdir -p "$HOME/.ssh-host"
chmod 700 "$HOME/.ssh-host"
[ -f "$HOME/.ssh-host/ssh_host_ed25519_key" ] || \
    ssh-keygen -t ed25519 -f "$HOME/.ssh-host/ssh_host_ed25519_key" -N "" -C "$DEV_NAME" >/dev/null

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

# ── the idle-claude offloader ───────────────────────────────────────────────
# WHAT USED TO BE HERE was the Claude Remote Control hook: a child baked an
# rc-supervisor.sh, set DEV_REMOTE_CONTROL=1, and this started it. Remote control is off
# this fleet as of 2026-08-25 — every container is reached the same way now, by ssh with
# the work held in an abduco session — so the hook has gone with the daemons it started.
#
# WHAT REPLACES IT IS THE OPPOSITE JOB. abduco is why a session survives a dropped link,
# and it is also why a conversation nobody has touched since Tuesday is still resident:
# measured on infra-dev, one idle session's process tree held 1,146 MB. The offloader
# stops those and leaves the conversation on disk for `claude --resume`. It refuses to
# touch an attached session, a session with work running under it, or one it has no
# transcript to time — offload-idle-claude.sh's header has the whole of the reasoning,
# and `--dry-run` prints its verdict on every session without acting on any of them.
#
# BACKGROUNDED WITH setsid AND ITS OUTPUT DISCARDED, like every other daemon here: it
# keeps its own log, and a daemon writing to this stream would be interleaved with sshd's
# for the life of the container.
if [ "${DEV_IDLE_OFFLOAD:-1}" = "1" ]; then
    setsid bash /home/dev/offload-idle-claude.sh </dev/null >/dev/null 2>&1 &
    say "idle-claude offloader started (log: ~/.local/share/claude-offload.log)"
    say "    it stops a detached, idle, not-working claude and leaves it resumable"
else
    say "idle-claude offloader off (DEV_IDLE_OFFLOAD=0) — idle sessions keep their memory"
fi

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
# audit-fleet.yml refuses to read because it holds secrets. A credentials FILE, mounted
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
        say "         Re-run ansible/playbooks/create-dev-tunnel.yml; loopback works."
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
    say "    Run ansible/playbooks/create-dev-tunnel.yml. Loopback is unaffected."
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
# A DROP-IN THAT DOES NOT PARSE MUST NOT COST THE CONTAINER. sshd is exec'd as PID 1
# under `restart: "no"`, so a config it refuses means the container exits and stays
# exited — and no agent session on this fleet has a route to a box to fix it from. The
# door is the one thing that must come up.
#
# So: test first, and on failure come up WITHOUT the child's drop-ins rather than not at
# all. The stripped config is the base's own file minus the Include line, which is the
# only thing a child can have broken. Loud, because a container that is up and quietly
# ignoring its drop-in is how `AllowTcpForwarding yes` goes missing for a fortnight.
#
# The subtle failure this catches: a `Match` block in a drop-in. Include is processed
# inline and first, so everything after it in the main file falls inside that Match
# context, where Port and HostKey are illegal — and the error names those lines rather
# than the drop-in that caused them.
# The error text is captured into a VARIABLE and not a file. `2>/tmp/sshd-t.err` was
# the first spelling and it has a failure of its own: an unwritable /tmp makes the
# redirection fail before sshd -t ever runs, so a perfectly good config takes the
# failure branch and a child loses its drop-ins for no reason. A variable depends on
# nothing.
SSHD_CONF=/home/dev/sshd_config
NODROP=/home/dev/sshd_config.nodrop
if ! sshd_err="$(/usr/sbin/sshd -t -f "$SSHD_CONF" 2>&1)"; then
    say "WARNING: sshd refused $SSHD_CONF —"
    printf '%s\n' "$sshd_err" | sed 's/^/[entrypoint] sshd: /'
    # Removed before it is written, and the write is CHAINED to the test that promotes
    # it. Otherwise a stale copy from an earlier boot survives a failed write — and the
    # second `sshd -t` would validate that file and promote it, which is the one way
    # this preflight could serve a config nobody in this container wrote.
    rm -f "$NODROP"
    if grep -v '^Include /home/dev/sshd_config.d/' "$SSHD_CONF" > "$NODROP" \
       && /usr/sbin/sshd -t -f "$NODROP" 2>/dev/null; then
        SSHD_CONF="$NODROP"
        say "STARTING WITHOUT THE DROP-INS in /home/dev/sshd_config.d — the container is"
        say "    up and reachable, and whatever they set is NOT in force. Fix the .conf"
        say "    in the repo's dev/ and rebuild."
        # "up and reachable" is the one claim above that a stripped drop-in can falsify,
        # and the line that said authorized_keys comes from a drop-in was printed
        # hundreds of lines ago, before this preflight had decided anything. Say it
        # again, here, where it is now true: the base config's AuthorizedKeysFile is
        # ~/.ssh/authorized_keys, and in that branch nothing ever wrote one.
        if [ -n "$authkeys_dropin" ] && [ ! -s "$HOME/.ssh/authorized_keys" ]; then
            say "    AND ONE OF THEM SET AuthorizedKeysFile: sshd now reads"
            say "    $HOME/.ssh/authorized_keys, which is empty, so NOTHING can ssh in."
            say "    A docker exec from the host is the only way in until it is fixed."
        fi
    else
        say "could not fall back — either that copy could not be written, or the base"
        say "    config alone does not parse either. Starting on the original anyway,"
        say "    so the failure is sshd's own message rather than this script's guess."
    fi
fi

say "sshd on :2222 in the foreground — ssh in and work in an abduco session"
say "    ssh $DEV_NAME                              a shell"
say "    ssh -t $DEV_NAME abduco -A claude claude   a claude that survives the link"
exec /usr/sbin/sshd -D -e -f "$SSHD_CONF"
