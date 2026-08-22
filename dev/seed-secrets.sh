#!/usr/bin/env bash
# Puts everything infra-dev needs into $INFRA_SECRETS on zero.
#
#     cd ~/infra/dev && ./seed-secrets.sh
#
# RUN THIS ON ZERO, not on the phone — and that is the difference from or3-dev's
# script of the same name, which has to run on the phone because the or3ecr key and
# the Claude credentials live there. Nothing infra-dev needs is on the phone except
# one PUBLIC key, which is not secret and which this script asks you to paste. So:
#
#   - both private keys are GENERATED HERE and never transmitted anywhere
#   - the ssh config and host keys are COPIED FROM ZERO'S OWN WORKING SETUP, so the
#     container reaches `one` exactly the way zero does rather than via a second
#     description of the hop that is free to be wrong
#   - nothing crosses the phone's radio at all
#
# Idempotent: it never overwrites a key that exists, and re-running it re-derives the
# config fragments from whatever ~/.ssh says today. Safe to run again after adding a
# host or rotating a key.
set -eu

DIR="${INFRA_SECRETS:-$HOME/.infra-dev-secrets}"
FLEET=(zero one two)

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

[ "$(id -u)" != 0 ] || { echo "run this as your own account, not root — the keys" >&2
                         echo "and the ssh config it reads are yours, not root's." >&2; exit 1; }

bold "0/5  the directory"
mkdir -p "$DIR"
chmod 700 "$DIR"
ok "$DIR (mode $(stat -c %a "$DIR"))"

# ── 1  the GitHub deploy key ────────────────────────────────────────────────
# Scoped to gsfernandes81/infra and nothing else on GitHub. Read-write so a commit
# made in the container can be pushed. Generated here, so the private half has never
# been anywhere but this disk.
bold "1/5  GitHub deploy key"
if [ -f "$DIR/id_ed25519_infra_deploy" ]; then
    ok "already present — not regenerating (that would orphan the key on GitHub)"
else
    ssh-keygen -t ed25519 -f "$DIR/id_ed25519_infra_deploy" -N "" -C infra-dev-zero >/dev/null
    ok "generated"
fi
chmod 600 "$DIR/id_ed25519_infra_deploy"
info "Register the public half, once:"
info "  gh repo deploy-key add $DIR/id_ed25519_infra_deploy.pub \\"
info "      --repo gsfernandes81/infra --title infra-dev-zero --allow-write"

# ── 2  the fleet key ────────────────────────────────────────────────────────
# One key that reaches zero, one and two as your own account. A SEPARATE key from the
# one you use by hand, on purpose: it is revocable on its own — pull three
# authorized_keys lines and the container is locked out while your laptop still works
# — and it never leaves zero, so there is no copy of it to lose.
#
# It grants what your account grants, which on these boxes is `wheel`. sudo still
# wants a password, and this repo refuses NOPASSWD, so the container can read the
# fleet freely and can only change it when someone is at the keyboard to type -K.
# That is the intended shape, not a limitation to work around.
bold "2/5  fleet key"
if [ -f "$DIR/id_ed25519_fleet" ]; then
    ok "already present — not regenerating"
else
    ssh-keygen -t ed25519 -f "$DIR/id_ed25519_fleet" -N "" -C infra-dev-fleet >/dev/null
    ok "generated"
fi
chmod 600 "$DIR/id_ed25519_fleet"
info "Authorise it on each host — append, never rewrite:"
for h in "${FLEET[@]}"; do
    info "  ssh-copy-id -i $DIR/id_ed25519_fleet.pub $h"
done
info "ssh-copy-id appends. Do not edit authorized_keys by hand on \`two\`: it is the"
info "box whose only way in is that file, and a botched rewrite there is unrecoverable."

# ── 3  the fleet ssh config ─────────────────────────────────────────────────
# Lifted from your working ~/.ssh/config rather than composed, then pointed at the
# fleet key. Awk rather than sed because a Host block runs to the next Host line, and
# matching a range is what awk is for.
bold "3/5  ssh_config.fleet"
if [ ! -f "$HOME/.ssh/config" ]; then
    warn "no ~/.ssh/config on this host — write $DIR/ssh_config.fleet by hand."
else
    tmp="$DIR/.ssh_config.fleet.tmp"
    : > "$tmp"
    for h in "${FLEET[@]}"; do
        awk -v want="$h" '
            /^[[:space:]]*[Hh]ost[[:space:]]/ {
                inblock = 0
                for (i = 2; i <= NF; i++) if ($i == want) inblock = 1
            }
            inblock { print }
        ' "$HOME/.ssh/config" >> "$tmp"
        printf '\n' >> "$tmp"
    done
    # Point every block at the fleet key. A copied block names whatever identity you
    # use by hand, which is not in the container; without this the container falls
    # back to offering nothing and the failure reads as "Permission denied (publickey)".
    if grep -qiE '^[[:space:]]*IdentityFile' "$tmp"; then
        sed -i -E 's|^([[:space:]]*)[Ii]dentity[Ff]ile.*|\1IdentityFile ~/.ssh/id_ed25519_fleet|' "$tmp"
    else
        sed -i -E 's|^([[:space:]]*)([Hh]ost[[:space:]].*)|\1\2\n  IdentityFile ~/.ssh/id_ed25519_fleet|' "$tmp"
    fi
    mv "$tmp" "$DIR/ssh_config.fleet"
    chmod 600 "$DIR/ssh_config.fleet"
    found=$(grep -ciE '^[[:space:]]*Host[[:space:]]' "$DIR/ssh_config.fleet" || true)
    if [ "$found" -eq "${#FLEET[@]}" ]; then
        ok "$found Host blocks written"
    else
        warn "$found of ${#FLEET[@]} Host blocks found in ~/.ssh/config"
        info "The missing ones need adding to $DIR/ssh_config.fleet by hand."
    fi
    info "Read it before trusting it — this is the one file here that was guessed at:"
    info "  cat $DIR/ssh_config.fleet"
fi

# ── 4  the fleet host keys ──────────────────────────────────────────────────
# ansible.cfg sets host_key_checking = True, which FAILS on an unknown key rather than
# prompting — there is no tty on an ansible connection. So the container needs these
# before its first run, and taking them from a known_hosts you have been using is the
# only honest source: it is the record of keys you already accepted and have been
# connecting against since.
bold "4/5  known_hosts.fleet"
if [ ! -f "$HOME/.ssh/known_hosts" ]; then
    warn "no ~/.ssh/known_hosts — ssh to each host once from here first."
else
    tmp="$DIR/.known_hosts.fleet.tmp"
    : > "$tmp"
    for h in "${FLEET[@]}"; do
        # ssh-keygen -F resolves the alias through ~/.ssh/config the way ssh does, and
        # prints the hashed or plain line as stored. -F needs the real hostname, so ask
        # ssh what it resolved to rather than assuming the alias is the hostname.
        real=$(ssh -G "$h" 2>/dev/null | awk '/^hostname /{print $2; exit}')
        [ -n "$real" ] || real="$h"
        if ssh-keygen -F "$real" -f "$HOME/.ssh/known_hosts" 2>/dev/null | grep -v '^#' >> "$tmp"; then
            :
        else
            warn "no known_hosts entry for $h ($real) — ssh $h once, then re-run this."
        fi
    done
    mv "$tmp" "$DIR/known_hosts.fleet"
    chmod 600 "$DIR/known_hosts.fleet"
    # `grep -c` exits 1 when the count is 0, which is the trap in ../CLAUDE.md — hence
    # the `|| echo 0`. And zero lines is a FAILURE, not a quiet success: the file exists,
    # the container starts, and every ansible task then fails host key verification in a
    # way that reads like a refused connection.
    lines=$(grep -c . "$DIR/known_hosts.fleet" || echo 0)
    if [ "$lines" -gt 0 ]; then
        ok "$lines host key lines"
    else
        warn "known_hosts.fleet is EMPTY — ansible will fail host key checking on every"
        info "host. ssh to each of ${FLEET[*]} once from here, then re-run this script."
    fi
fi

# ── 5  authorized_keys ──────────────────────────────────────────────────────
# Who may ssh INTO the container. Public keys only — nothing secret — which is why
# this is the one thing the phone contributes and why it is a paste rather than a
# transfer. Appended, never rewritten: this file is how a second client gets in and
# losing the first one's line while adding a second is the obvious way to lock
# yourself out of your own container.
bold "5/5  authorized_keys"
touch "$DIR/authorized_keys"
chmod 600 "$DIR/authorized_keys"
n=$(grep -c '^ssh-' "$DIR/authorized_keys" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then
    ok "$n key(s) already authorised"
else
    warn "empty — nothing can ssh into the container yet."
fi
info "Add the phone's public key (on the phone: cat ~/.ssh/id_ed25519.pub), then:"
info "  cat >> $DIR/authorized_keys"
info "Add a PC's the same way. \`make shell\` on zero works regardless of this file."

bold "Done."
cat <<EOF

  $DIR now holds:
$(ls -1 "$DIR" | sed 's/^/      /')

  Two things above are NOT done by this script and the container will start without
  them, quietly doing less than you expect:

      1. registering the deploy key on GitHub          (step 1's gh command)
      2. authorising the fleet key on all three hosts  (step 2's ssh-copy-id lines)

  Then:  cd ~/infra/dev && cp .env.example .env && \$EDITOR .env && make dev
EOF
