# infra-dev's fish configuration, baked into the image at ~/.config/fish/config.fish.
#
# /workspace — the bind-mounted host clone — is where the work is, so a shell that
# starts anywhere else moves there. The shells that start anywhere else are the
# LOGIN ones: sshd chdirs to the home directory before exec'ing the shell, so
# `ssh infra-dev` lands in /home/dev no matter what the image's WORKDIR says.
#
# Guarded on `status is-login` rather than run unconditionally, because
# `fish -c ...` from a script has to keep the directory its caller chose — a
# config that cd'd every fish would move the ground under anything scripted.
#
# THE CONSEQUENCE THAT BITES: an ssh RemoteCommand is `$SHELL -c '…'`, so it is not a
# login shell either and this does NOT run for it. A client whose ssh config says
# `RemoteCommand abduco -A claude claude` lands in /home/dev, and claude then asks to
# trust a directory that is not the repo — the entrypoint seeded the trust dialog for
# /workspace. The answer is /usr/local/bin/dev-claude, which cds and then execs abduco,
# so a client says `dev-claude` and knows none of this. Widening the guard here would
# fix that one case by breaking every scripted `fish -c`, which is the worse trade.
# Guarded on the directory too: a container brought up with the bind mount
# missing should still hand you a shell to find that out from.
if status is-login
    if test -d /workspace
        cd /workspace
    end
end
