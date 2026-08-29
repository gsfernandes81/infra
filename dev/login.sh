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
#   git over ssh -> /run/infra-secrets  (mounted; nothing to do in here)
#   the fleet    -> /run/infra-secrets  (mounted; nothing to do in here)
#   GitHub CLI   -> infra-gh     volume ($GH_CONFIG_DIR)
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

# ── 1/4  git over ssh ────────────────────────────────────────────────────────
# Nothing to log into: the deploy key arrives through the read-only secrets mount and
# the entrypoint copies it into ~/.ssh on every start. So this step only ever reports,
# and when it reports a failure the fix is on zero, not in here.
bold "1/4  git over ssh (the infra deploy key)"
if ssh -o BatchMode=yes -T git@github.com 2>&1 | grep -q 'successfully authenticated'; then
  ok "github.com accepts the deploy key — commits from here can be pushed."
elif [ ! -f "$HOME/.ssh/id_ed25519_infra_deploy" ]; then
  warn "No deploy key in this container."
  info "It comes from \$INFRA_SECRETS/id_ed25519_infra_deploy on zero, which"
  info "ansible/playbooks/prepare-dev-host.yml generates there. Add it and restart:"
  info "    cd ~/infra/dev && make restart"
else
  warn "The deploy key is present but github.com does not accept it."
  info "Add its public half to the repo as a deploy key. The playbook printed"
  info "the command; it is also:"
  info "    gh repo deploy-key add <pubkey-file> --repo gsfernandes81/infra --allow-write"
fi

# ── 2/4  the fleet ───────────────────────────────────────────────────────────
# Not a login either — but it is the thing this container exists for, so it is a step
# rather than a footnote. Asked of each host in turn, because "ansible works" and
# "all three answer" are different claims and the second is the useful one.
bold "2/4  the fleet (zero, one, two)"
if [ ! -f "$HOME/.ssh/id_ed25519_fleet" ]; then
  ok "not configured — the default. This container develops the repo; it does not"
  info "operate the fleet, and running playbooks against the three hosts stays on the"
  info "phone. That is a deferred decision rather than a missing step: putting a control"
  info "node inside a container on a box it controls is a real question, and it is"
  info "written up in docs/management-plane.md § \"A control node inside the fleet\"."
  info "It is not built: see that section for what would have to be decided first."
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

# ── 3/4  GitHub CLI ──────────────────────────────────────────────────────────
# The deploy key above covers git. gh covers everything git does not — PRs, issues,
# releases, `gh api` — and it is a login rather than a mounted key, which is why it is
# a step here at all.
bold "3/4  GitHub CLI (gh)"
if gh auth status >/dev/null 2>&1; then
  ok "$(gh auth status 2>&1 | grep -m1 'Logged in' | sed 's/^[[:space:]]*//')"
else
  warn "Not logged in."
  info "This container also holds an ssh key that reaches all three hosts, so give gh"
  info "the narrowest token that does what you need — 'repo' alone is usually it, and"
  info "a token pasted in is easier to scope than the browser flow's default set."
  info "There is no browser in here: the web flow prints a code to paste elsewhere."
  ask "Run 'gh auth login' now?" && gh auth login
fi

# ── 4/4  Claude Code ─────────────────────────────────────────────────────────
# The one that CANNOT be skipped by copying a file. or3-dev established that: the
# phone's credentials.json was copied in and the container blanked it one second
# later. An OAuth login belongs to the device that performed it.
bold "4/4  Claude Code"
if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
  ok "logged in — \`claude\` will start without a login flow."
else
  warn "Not logged in."
  info "No browser in here either: it prints a URL, and you paste back the code."
  info "--claudeai is the subscription login; --console would bill the API instead."
  ask "Run 'claude auth login' now?" \
    && claude auth login --claudeai --email "${GIT_USER_EMAIL:-gavinfernandes2012@pm.me}"
fi

bold "Done."
cat <<'EOF'

  This container is used over ssh. From the phone or a PC:

      ssh infra-dev                                  a shell
      ssh -t infra-dev abduco -A claude claude       a claude that survives the link

  abduco detaches with Ctrl-\ and re-attaches with the same command, so a dropped
  connection costs nothing. `abduco` on its own lists the sessions.

  The point of working in here rather than from the phone: the model traffic goes out
  over zero's home connection, and ansible reaches one and two over the home LAN.
  Neither touches the phone's radio. What crosses it is your keystrokes.

  From a terminal on zero:  cd ~/infra/dev && make shell | make claude | make status
  Re-run these logins:      make login
EOF
