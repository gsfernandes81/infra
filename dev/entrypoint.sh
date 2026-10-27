#!/usr/bin/env bash
# PID 1 for every container built on this base (under `init: true`, so detached
# sessions' orphans get reaped).
#
# Order matters and is not arbitrary:
#   ssh (+ the hub's key) -> claude state -> clone or pull -> env links -> child-init
#   -> sshd host key -> reconcile -> keep-alive skill -> sshd(fg)
#
# NO OFFLOADER AND NO TUNNEL HERE since base 2026.10.26: both are the hub's (dev/hub/). The hub
# runs `claude-sessions offload` in this container over ssh every three minutes, and the way in
# is `ssh dev`, through the hub's own cloudflared sidecar.
# Everything that could block on a prompt is settled first, because nothing in here
# can answer one.
#
# **sshd is the FOREGROUND process, and that is the whole design.** This container is
# used by ssh-ing into it — from Termux on the phone, or from a PC — and running
# claude inside a session there (a zmx session, since claude-sessions v0.4.0). The thing whose lifetime the container's
# lifetime should equal is therefore the door. Nothing you type can end the container:
# `exit` closes an ssh session, `/exit` closes a claude, and PID 1 has not moved.
set -u

# WHAT THIS IS PARAMETERISED BY, because it serves more than one container now.
# Every default below is infra-dev's own behaviour, so a child that sets none of these
# gets exactly what this file did when it was infra-dev's alone:
#
#   DEV_NAME             the container's name in the lines this prints  (default: hostname)
#   DEV_SECRETS_DIR      where the read-only secrets mount lands        (/run/infra-secrets)
#   DEV_REPO             owner/name cloned into an empty /workspace     (unset = no clone)
#   DEV_ENV_FILES        workspace paths kept in ~/.env.d and linked in (".env" style; none)
#   DEV_CHILD_INIT_TIMEOUT  seconds child-init.sh gets before it is killed        (600)
#
# DEV_TUNNEL_HOSTNAME AND DEV_IDLE_OFFLOAD WENT on 2026-10-26 with the tunnel and the offload
# loop they switched, and CLAUDE_SESSIONS_OFFLOAD, the per-container switch that replaced the
# second, on 2026-10-27: the hub's HUB_OFFLOAD is the one switch.
#
# DEV_REMOTE_CONTROL IS GONE, 2026-08-25. Every container on this fleet is now reached the
# same way — ssh in, work in a held session — and none of them ships a remote-control
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
# what differs per container — infra-dev's would be id_ed25519_fleet if fleet access is ever
# given, or3-dev has id_ed25519_or3ecr_m for the vessel — and a list baked here is a list the
# base has to know about its children. None of them is a GitHub credential since 2026-10-27:
# that is the hub's token.
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
# invariant puts those in a gitignored file. Nothing in the repo writes them, and nothing
# will: the owner decided on 2026-10-25 that no container is a control node
# (docs/management-plane.md § "A control node inside the fleet"), so this file is absent and
# the container has no route to zero, one or two. Absence is the settled state, so it is
# not warned about; `make status` reports it.
#
# `rm -f` FIRST, AND THAT LINE IS LOAD-BEARING. A redirection follows a symlink and
# truncates its TARGET, so if anything in this container has made ~/.ssh/config a symlink
# — a child's child-init.sh pointing it at a file in a mount, or a person doing the
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


# authorized_keys: the keys allowed straight in, copied from the secrets mount — in practice
# only or3-dev has one, the phone's, for its vessel tunnel. Every container is reached through
# the hub, whose key is a file of its own (below), so none here is the normal state and not a
# fault. sshd reads both files (sshd_config), and nothing else names a key file since the
# drop-in seam went (2026-10-27).
if [ -f "$SECRETS/authorized_keys" ]; then
    cp -f "$SECRETS/authorized_keys" "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
else
    say "no authorized_keys in $SECRETS — no client key goes straight in; the hub's key"
    say "    (below) is the way in, and make shell C=<c> on zero the break glass."
    : > "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
fi

# THE HUB'S KEY, from the volume the hub publishes it in (read-only here), with
# `restrict,pty`: the hub runs commands and, for an attach, wants a terminal, and nothing
# else — no forwarding, no agent, no X11, no ~/.ssh/rc. The key itself never leaves the hub
# (decisions.md, the dev-pool rows); only its public half is here.
#
# ITS OWN FILE, NOT A LINE APPENDED TO authorized_keys: server-add-authorized-keys.yml
# refreshes that file in a running container by copying the secrets dir's over it, which
# would drop the hub's line until the next start and take the container out of the menu.
# sshd_config lists both files, and it is the only config sshd reads.
# rm -f first: a write follows a symlink, and nothing else should own this path.
HUB_PUB=/opt/claude-sessions/hub.pub
rm -f "$HOME/.ssh/authorized_keys.hub"
if [ -s "$HUB_PUB" ] && grep -q '^ssh-' "$HUB_PUB"; then
    printf 'restrict,pty %s\n' "$(head -1 "$HUB_PUB")" > "$HOME/.ssh/authorized_keys.hub"
    chmod 600 "$HOME/.ssh/authorized_keys.hub"
    say "the hub's key is authorised (restrict,pty) — the hub can reach this container"
else
    say "WARNING: no hub key at $HUB_PUB — the hub cannot reach this container. Is the hub up?"
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

# A fleet key without the fleet's host keys is the one half-state worth a word: ansible would
# fail on host key verification, which reads as a refused connection.
if [ -f "$SECRETS/id_ed25519_fleet" ] && [ ! -f "$SECRETS/known_hosts.fleet" ]; then
    say "WARNING: id_ed25519_fleet but no known_hosts.fleet in $SECRETS — ansible will fail on host keys"
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

# WHICH CLAUDE THIS CONTAINER STARTED WITH, and the reason it is worth a line in every
# boot log: the version is no longer a property of the image. Claude Code updates itself
# in place now — the reasoning is in Dockerfile.base's node block — so `make boot-log` is
# the only place that records what a container was actually running on a given day, and
# the difference between this line and `claude --version` today is the update that
# happened while it ran.
#
# `--version` asks nothing of the network and answers in milliseconds. The timeout is
# there because this runs ahead of the door and a readout must not be able to hold it
# shut, which is the same rule child-init.sh is bounded by.
#
# Captured before it is tested, not `… | head -1 || echo`: a `||` after a pipeline tests
# the LAST command in it, so `head` succeeding on empty input would report a claude that
# answered when none did. CLAUDE.md § *Shell traps* has the general form.
claude_version="$(timeout 20 claude --version 2>/dev/null | head -1)"
say "claude ${claude_version:-DID NOT ANSWER --version — this container has no working claude}"

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

# GITHUB IS THE HUB'S TOKEN, AND ONLY THAT (owner, 2026-10-27). /run/github/token holds an
# hourly token for this container's repo alone (dev/README.md § "GitHub tokens, one repo
# each"): git asks git-credential-hub for https://github.com, which reads that file on each
# call, and gh is handed it by its wrapper. No deploy key, no gh login, no rewrite of https to
# ssh — so every origin is https, and a token GitHub restricted to one repo is the only
# GitHub credential in the container. Set unconditionally: with no token yet the helper
# answers nothing, and git fails the way it would without it.
git config --global credential.https://github.com.helper hub
if [ -s /run/github/token ]; then
    say "github: the hub's token for ${DEV_REPO:-this repo} — git over https and gh, renewed every 30 min"
else
    say "WARNING: no GitHub token from the hub yet — clone, pull and push wait for it (make status C=hub)"
fi

# ── the workspace: cloned once, pulled after ────────────────────────────────
# /workspace IS THIS CONTAINER'S OWN, a named volume, never the host's clone (dev/compose.yaml
# says why). An empty one is cloned from DEV_REPO over https with the hub's token. Bounded, like
# everything ahead of sshd, and never fatal: a container with an empty workspace is one you can
# ssh into and fix (`make login C=<c>` clones once the token is there). A volume that already
# holds something that is not a checkout is left alone and said so — it is somebody's work.
#
# Then the pull: --ff-only, and never fatal, as it always was. ${PIPESTATUS[0]}, and not the
# pipeline's own status — `if git … | sed …` tests SED, which is CLAUDE.md § Shell traps'
# entry for this very block; and not `set -o pipefail`, which would make a pull that SUCCEEDED
# print "unchanged" when sed died.
if [ ! -e /workspace/.git ] && [ -n "${DEV_REPO:-}" ]; then
    if [ -n "$(ls -A /workspace 2>/dev/null)" ]; then
        say "WARNING: /workspace holds files but no checkout — not cloning $DEV_REPO over them"
    else
        say "cloning $DEV_REPO into /workspace over https with the hub's token"
        timeout 300 git clone --quiet "https://github.com/$DEV_REPO.git" /workspace 2>&1 \
            | sed 's/^/[entrypoint] git: /'
        [ "${PIPESTATUS[0]}" = 0 ] || \
            say "WARNING: the clone failed — the workspace is empty; make login C=<c> clones it"
    fi
elif [ -d /workspace/.git ]; then
    git -C /workspace pull --ff-only 2>&1 | sed 's/^/[entrypoint] git: /'
    pull_rc=${PIPESTATUS[0]}
    [ "$pull_rc" = 0 ] || \
        say "pull skipped (not fast-forward, or offline) — the checkout is unchanged"
fi

# ── the repo's untracked secrets: in their own volume, linked into the workspace ──
# DEV_ENV_FILES names the files a repo expects beside its tracked ones (".env", say). Each
# lives in ~/.env.d — a volume of its own, so the workspace volume, which a clone can be
# thrown away and remade in, never holds one — and the workspace gets a symlink to it. A
# HARD link cannot cross two volumes (they are two mounts, and link(2) refuses across mounts),
# so it is a symlink; editing /workspace/.env writes through it.
#
# Never clobbered: a REGULAR file where the link should be is said and left — an editor that
# saves by rename, or `sed -i`, replaces a symlink with a file, and that file is the newest
# copy. Moving it back is a person's call: `mv /workspace/.env ~/.env.d/.env`, then restart.
# Each link is added to the checkout's .git/info/exclude, so it is never committed whatever
# the repo's .gitignore says.
mkdir -p "$HOME/.env.d"
chmod 700 "$HOME/.env.d"
for f in ${DEV_ENV_FILES:-}; do
    case $f in /*|*..*) say "WARNING: DEV_ENV_FILES entry $f is not a plain workspace path — skipped"; continue ;; esac
    link="/workspace/$f"
    target="$HOME/.env.d/$f"
    if [ -L "$link" ]; then
        :
    elif [ -e "$link" ]; then
        say "WARNING: $link is a regular file, not the link to $target — it holds the newest copy;"
        say "         move it back with: mv $link $target   (then restart)"
        continue
    elif [ -d /workspace/.git ]; then
        mkdir -p "$(dirname "$link")" "$(dirname "$target")"
        ln -s "$target" "$link"
        [ -e "$target" ] || say "$f: linked to $target, which is empty until you write it"
    else
        continue
    fi
    ex=/workspace/.git/info/exclude
    if [ -d /workspace/.git ] && ! grep -qxF "/$f" "$ex" 2>/dev/null; then
        mkdir -p "$(dirname "$ex")" && printf '/%s\n' "$f" >> "$ex"
    fi
done

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

# ── claude-sessions reconcile — before anything reads the registry ──────────
# The registry (~/.local/share/claude-sessions, one JSON file per slot) is on a volume, so
# it outlives the container while every process it names does not. reconcile marks the
# slots whose pid and start time are gone. Since v0.4.0 a slot is a zmx session and
# reconcile sweeps no sockets: `zmx list` removes a dead daemon's socket itself when the
# connection is refused, and zmx's socket directory is /tmp/zmx-<uid>, which a recreate
# empties anyway. Its line reads `reconcile: N slot(s) offloaded, M zmx session(s), K not
# answering`, or plain `reconcile: N slot(s) offloaded` with a warning when zmx cannot be
# asked. Here because it must come before the offloader below and before sshd lets a
# session in, and as `dev` because that is who runs claude. Non-zero only
# on a real error, which is printed and does not stop the door. Time-bounded for the
# reason child-init.sh is: anything ahead of sshd that hangs costs the door.
if ! command -v claude-sessions >/dev/null 2>&1; then
    say "WARNING: no claude-sessions on PATH — the hub's volume is not mounted at /opt/claude-sessions,"
    say "         so there are no hooks and the hub cannot see this container's sessions"
elif out=$(timeout 30 claude-sessions reconcile 2>&1); then
    say "claude-sessions ${out:-reconcile: said nothing}"
else
    say "claude-sessions reconcile FAILED (exit $?) — the registry may name dead sessions:"
    printf '%s\n' "$out" | sed 's/^/[entrypoint]     /'
fi

# ── claude-sessions' keep-alive skill — at every start, into the config volume ──
# Since v0.4.7 the offloader stops a detached slot that is measured quiet for 10 minutes,
# and nothing it reads can tell a quiet WAIT (a sleep before a check, CI, a ScheduleWakeup)
# from an idle session. `claude-sessions keepalive <duration>` holds the slot, and this
# skill, which the hub's `claude-sessions install` puts in its volume beside the binary, is
# what tells claude to use it and for how short. Claude Code's config directory is a volume,
# so the image cannot carry the file; copied at every start, which also brings it up to date
# with the hub's version. Through a temp file and
# a rename, never a redirection onto the target: `>` truncates before the command runs and
# follows a symlink, so a failed `skill` would leave an empty file, and a re-pointed path
# would be written through; the temp path is cleared first for the same reason, and `mv -T`
# refuses to move INTO a directory (or a link to one) where the file should be.
# Removed when the hub's volume has none (a rollback past v0.4.7 has no `keepalive` either): a
# stale file would tell every claude to run a command that does not exist. A failure is said and does not stop the door; the cost is a
# claude that does not know to ask, so a quiet wait in a detached slot can be offloaded.
skill_dir="$CFG/skills/keepalive"
skill_src=/opt/claude-sessions/skills/keepalive/SKILL.md
rm -f "$skill_dir/.SKILL.md.tmp"
if mkdir -p "$skill_dir" \
    && [ -s "$skill_src" ] \
    && cp "$skill_src" "$skill_dir/.SKILL.md.tmp" \
    && mv -fT "$skill_dir/.SKILL.md.tmp" "$skill_dir/SKILL.md"; then
    say "claude-sessions keep-alive skill: $skill_dir/SKILL.md (from the hub's $skill_src)"
else
    rm -f "$skill_dir/.SKILL.md.tmp" "$skill_dir/SKILL.md"
    say "claude-sessions keep-alive skill NOT installed (and any old copy removed) — claude will not know to ask for time before a quiet wait"
fi

# ── the offloader and the tunnel: the hub's, since base 2026.10.26 ────────────
# This entrypoint started both until then: a fixed-rate loop running `claude-sessions offload`
# every three minutes, and cloudflared for DEV_TUNNEL_HOSTNAME. The hub runs the first for
# every container at once, over ssh (`claude-sessions offload-all`, dev/hub/entrypoint.sh, its
# pass log in the hub's ~/.hub/passes.log), and its sidecar is the only tunnel. Git history
# has both blocks, and their reasoning moved with them.

# ── sshd, in the foreground ─────────────────────────────────────────────────
# The container's payload. exec, so sshd IS this process: signals from `docker stop`
# reach it directly and the container's lifetime is exactly the door's.
#
# -D stops it daemonising — daemon(0,0) would point its stderr at /dev/null and throw
# away the -e log that `docker logs infra-dev` is now made of.
#
# Nothing beyond this line runs. A start-up failure is in the log above it, which is
# what `make boot-log` prints.
# sshd runs this image's own sshd_config and nothing else — no drop-ins since 2026-10-27 — so
# a config it refuses is a base build bug, which the smoke test (.github/workflows/dev-smoke.yml)
# meets before any container on zero does. Its own error lands in `make boot-log`.
say "sshd on :2222 in the foreground — reached through the hub: ssh dev, then $DEV_NAME"
say "    from zero: make shell C=$DEV_NAME   (a shell here, without the hub)"
exec /usr/sbin/sshd -D -e -f /home/dev/sshd_config
