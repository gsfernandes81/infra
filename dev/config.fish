# infra-dev's fish configuration, baked into the image at ~/.config/fish/config.fish.
#
# /workspace — the container's own clone, in a volume — is where the work is, so a shell that
# starts anywhere else moves there. The shells that start anywhere else are the
# LOGIN ones: sshd chdirs to the home directory before exec'ing the shell, so
# `ssh infra-dev` lands in /home/dev no matter what the image's WORKDIR says.
#
# Guarded on `status is-login` rather than run unconditionally, because
# `fish -c ...` from a script has to keep the directory its caller chose — a
# config that cd'd every fish would move the ground under anything scripted.
#
# THE CONSEQUENCE THAT BITES: a forwarded ssh command — `ssh <c> cmd` through the door,
# or a client's RemoteCommand — is `$SHELL -c '…'`, so it is not a login shell either and
# this does NOT run for it, which is why such a command lands in ~. A `claude` started that
# way lands in /home/dev, and then asks to
# trust a directory that is not the repo — the entrypoint seeded the trust dialog for
# /workspace. The answer is /usr/local/bin/in-workspace, which cds and then execs
# whatever it was given, so no client has to name the path. Widening the guard here would
# fix that one case by breaking every scripted `fish -c` — including the ones claude
# itself runs, where a silent cd would move the ground under every relative path in an
# agent's command. That is the worse trade, and it is why this is documented rather than
# changed.
# Guarded on the directory too: a container whose workspace volume is missing
# should still hand you a shell to find that out from.
if status is-login
    if test -d /workspace
        cd /workspace
    end
end
