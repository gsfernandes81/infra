#!/usr/bin/env bash
# The interactive login walkthrough for infra-dev. Baked into the image at
# /home/dev/login.sh; run from a terminal on zero with:
#
#     cd ~/infra/dev && make login        # or: make dev, which does up + this
#
# Every step is IDEMPOTENT — it reads the current state and only prompts when
# something is NOT already set up — so re-running it is safe and usually silent.
# Everything it fills lives in a persisted volume or in the read-only secrets mount,
# so this is normally done once per machine and not again after a rebuild:
#
#   GitHub       -> /run/github, the hub's token  (nothing to do in here; checked)
#   the fleet    -> /run/infra-secrets  (absent by decision; reported)
#   Claude Code  -> infra-claude volume ($CLAUDE_CONFIG_DIR)
#
# It is a script in the image rather than a Makefile recipe because every step of it
# needs a tty and every credential store it touches is in here, not on zero.
set -u

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
ask()  { # ask "question" -> 0 on yes; empty answer means yes
  local reply
  read -r -p "  $1 [Y/n] " reply || return 1
  [ -z "$reply" ] || [ "$reply" = y ] || [ "$reply" = Y ]
}

# ── 1/3  GitHub: the hub's token ─────────────────────────────────────────────
# Nothing to log into, since 2026-10-27: the hub mints this container an hourly token for its
# own repo and nothing else, git and gh both use it, and there is no deploy key or gh login
# beside it. So this step only reports — and NOT through `gh auth status`, which fails for an
# installation token (it has no user) while every repo command works.
bold "1/3  GitHub (the hub's token)"
if [ -s /run/github/token ]; then
  if git ls-remote "https://github.com/${DEV_REPO:-gsfernandes81/infra}.git" HEAD >/dev/null 2>&1; then
    ok "the hub's token for ${DEV_REPO:-this repo} works — git and gh need nothing else."
  else
    warn "a token is here but GitHub refuses it for ${DEV_REPO:-this repo}."
    info "Is the App installed on that repo? ~/.hub/github-tokens.log in the hub says what"
    info "GitHub answered: on zero, cd ~/infra/dev && make logs C=hub"
  fi
else
  warn "no token from the hub yet."
  info "The hub writes one at its start and every 30 min; make status C=hub on zero says why"
  info "it has not (HUB_GITHUB_APP_ID, github-app.pem, or GitHub's own answer)."
fi

# ── 2/3  the fleet ───────────────────────────────────────────────────────────
# Not a login either — but it is the thing this container exists for, so it is a step
# rather than a footnote. Asked of each host in turn, because "ansible works" and
# "all three answer" are different claims and the second is the useful one.
bold "2/3  the fleet (zero, one, two)"
if [ ! -f "$HOME/.ssh/id_ed25519_fleet" ]; then
  ok "not configured — the default. This container develops the repo; it does not"
  info "operate the fleet, and running playbooks against the three hosts stays on the"
  info "phone. The owner decided so on 2026-10-25: docs/management-plane.md"
  info "§ \"A control node inside the fleet\" has the reasoning."
elif [ ! -s "$HOME/.ssh/known_hosts" ]; then
  warn "A fleet key is present but known_hosts is empty — it was added by hand."
else
  for h in zero one two; do
    if out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" hostname 2>&1); then
      ok "$h answered: $(printf '%s' "$out" | tr -d '\r')"
    else
      warn "$h did not answer: $(printf '%s' "$out" | head -1)"
    fi
  done
  info "Then, for the real check: cd /workspace/ansible && ansible fleet -m ping"
fi

# ── 3/3  Claude Code ─────────────────────────────────────────────────────────
# The one that CANNOT be skipped by copying a file. or3-dev established that: the
# phone's credentials.json was copied in and the container blanked it one second
# later. An OAuth login belongs to the device that performed it.
bold "3/3  Claude Code"
if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  ok "logged in — \`claude\` will start without a login flow."
else
  warn "Not logged in."
  info "No browser in here either: it prints a URL, and you paste back the code."
  info "--claudeai is the subscription login; --console would bill the API instead."
  ask "Run 'claude auth login' now?" \
    && claude auth login --claudeai --email "${GIT_USER_EMAIL:-gavinfernandes2012@pm.me}"
fi

# ── the workspace ────────────────────────────────────────────────────────────
# /workspace is this container's own volume, cloned at first start from DEV_REPO with the
# hub's token. A start before the token arrived leaves it empty; this is where it gets filled.
bold "the workspace (/workspace)"
if [ -d /workspace/.git ]; then
  ok "$(git -C /workspace remote get-url origin 2>/dev/null) at $(git -C /workspace log --oneline -1 2>/dev/null)"
elif [ -z "${DEV_REPO:-}" ]; then
  warn "No DEV_REPO set for this container, so nothing to clone — see dev/compose.yaml."
elif [ -n "$(ls -A /workspace 2>/dev/null)" ]; then
  warn "/workspace holds files but no checkout; not cloning ${DEV_REPO} over them."
else
  ask "Clone ${DEV_REPO} into /workspace now?" \
    && git clone "https://github.com/${DEV_REPO}.git" /workspace
fi

bold "Done."
cat <<'EOF'

  This container is reached through the hub. From the phone or a PC:

      ssh dev                 every container; Enter on this one for its sessions,
                              s for a shell in it

  Every session the menu opens is a zmx session: Ctrl-\ detaches and the menu
  comes back, and a dropped connection costs nothing — ssh in again and press Enter.

  The point of working in here rather than from the phone: the model traffic goes out
  over zero's home connection, and ansible reaches one and two over the home LAN.
  Neither touches the phone's radio. What crosses it is your keystrokes.

  From a terminal on zero:  cd ~/infra/dev && make shell | make claude | make status
  Re-run these logins:      make login        (C=<container> for another one)
EOF
