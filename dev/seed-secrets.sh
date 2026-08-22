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
#   - the deploy key is GENERATED HERE and never transmitted anywhere
#   - nothing crosses the phone's radio at all
#
# BY DEFAULT IT DOES NOT GIVE THE CONTAINER ANY ROUTE TO THE FLEET. That half is
# opt-in behind INFRA_DEV_FLEET=1, because it turns a development container into a
# control node running on one of the boxes it controls — a real question, deferred
# rather than decided. ../docs/management-plane.md § "A control node inside the fleet".
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

bold "1/3  the directory"
mkdir -p "$DIR"
chmod 700 "$DIR"
ok "$DIR (mode $(stat -c %a "$DIR"))"

# ── 2  the GitHub deploy key ────────────────────────────────────────────────
# Scoped to gsfernandes81/infra and nothing else on GitHub. Read-write so a commit
# made in the container can be pushed. Generated here, so the private half has never
# been anywhere but this disk.
bold "2/3  GitHub deploy key"
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

# ══════════════════════════════════════════════════════════════════════════════
# OPTIONAL, AND OFF BY DEFAULT: reaching the fleet from inside the container.
#
#     INFRA_DEV_FLEET=1 ./seed-secrets.sh
#
# Everything below this line gives the container ssh to zero, one and two as your own
# account — which turns a development container into a control node running ON one of
# the boxes it controls. That is a real architectural question and it is DEFERRED, not
# decided: see ../docs/management-plane.md § "A control node inside the fleet".
#
# Nothing about developing this repo needs it. You can write playbooks, commit and push
# without it; what you cannot do is run them against the fleet from in here, which stays
# on the phone. The container starts, works and is fully usable with this skipped — the
# entrypoint treats every file below as absent-and-fine.
#
# The exposure is the reason for the default rather than the default being caution for
# its own sake: this key reaches all three hosts as an account in `wheel`, from a
# container that also runs a claude, on the box that runs Immich and the Cloudflare
# tunnel. Turning it on should be a decision with a date on it.
if [ "${INFRA_DEV_FLEET:-0}" = 1 ]; then
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
    bold "optional  fleet key"
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
    bold "optional  ssh_config.fleet"
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
        # THE HOST THIS RUNS ON WILL NOT HAVE A BLOCK FOR ITSELF, and that is not an
        # oversight in your config — nobody writes `Host zero` on zero. But the container is
        # a control node and zero is in its inventory, so it needs one. Synthesised here
        # rather than left to the warning below, because the failure it prevents reads as
        # "ansible cannot reach zero" and sends you looking at the key, not at a missing
        # four-line block. HostName is the bare name: compose's extra_hosts maps it to the
        # bridge gateway inside the container, so this stays right if the bridge renumbers.
        me=$(hostname -s 2>/dev/null || hostname)
        for h in "${FLEET[@]}"; do
            [ "$h" = "$me" ] || continue
            if ! grep -qiE "^[[:space:]]*Host[[:space:]].*\\b$h\\b" "$tmp"; then
                printf 'Host %s\n  HostName %s\n  User %s\n  IdentityFile ~/.ssh/id_ed25519_fleet\n\n' \
                       "$h" "$h" "$USER" >> "$tmp"
                ok "synthesised the block for $h — this host, which has none of its own"
            fi
        done
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
    bold "optional  known_hosts.fleet"
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
        # Same gap, other file: ~/.ssh/known_hosts on zero has no entry for zero. Take it
        # from the horse's mouth instead — the host key this machine's own sshd presents.
        # More authoritative than a known_hosts line, which only records a key someone once
        # accepted; this IS the key.
        me=$(hostname -s 2>/dev/null || hostname)
        for h in "${FLEET[@]}"; do
            [ "$h" = "$me" ] || continue
            grep -q "^$h " "$tmp" && continue
            for kt in ed25519 rsa ecdsa; do
                k="/etc/ssh/ssh_host_${kt}_key.pub"
                [ -r "$k" ] || continue
                printf '%s %s\n' "$h" "$(cut -d' ' -f1,2 "$k")" >> "$tmp"
                ok "took $h's host key from $k — this host has no known_hosts entry for itself"
                break
            done
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

else
bold "optional  fleet access — SKIPPED (the default)"
info "The container will have no route to zero, one or two, which is the default."
info "Nothing about working on this repo needs it; running playbooks against the"
info "fleet stays on the phone. To add it later:"
info "    INFRA_DEV_FLEET=1 ./seed-secrets.sh && cd ~/infra/dev && make restart"
info "Read ../docs/management-plane.md § \"A control node inside the fleet\" first."
fi
# ── 3  authorized_keys ──────────────────────────────────────────────────────
# Who may ssh INTO the container. Public keys only — nothing secret — which is why
# this is the one thing the phone contributes and why it is a paste rather than a
# transfer. Appended, never rewritten: this file is how a second client gets in and
# losing the first one's line while adding a second is the obvious way to lock
# yourself out of your own container.
bold "3/3  authorized_keys"
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

  ONE thing above is not done by this script, and without it the container comes up
  and cannot push: registering the deploy key on GitHub, which step 2 printed.

  Then:  cd ~/infra/dev && cp .env.example .env && \$EDITOR .env && make dev

  That is the whole of it. No fleet access, no Cloudflare — a container with a
  claude in it, reached from zero with \`make shell\`, or over ssh from the phone
  through zero once its key is in authorized_keys above. Both of the things this
  script skips are additions to that, decided separately and later.
EOF
