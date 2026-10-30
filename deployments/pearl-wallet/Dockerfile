# pearl-wallet's image: Pearl's Oyster wallet daemon and prlctl, its RPC client, and
# nothing else. Built on zero by Compose, only when compose.yaml's tag is absent (its
# header says why).
#
# The binaries come from upstream's release tarball, checked against the sha256 upstream
# publishes in that release's checksums.txt, so the build fails rather than install a
# tarball that changed. Upstream's own wallet/Dockerfile is not used: it builds on an
# unpinned alpine:latest, and the release's oyster links glibc.
#
# A BUMP is the version and checksum here and the tag in compose.yaml, in one commit. The
# deploy's preflight hook refuses a tag that does not match the version below.

# Unpacks the tarball. Thrown away; only the two binaries and one empty directory leave
# it. The directory is the wallet volume's mountpoint, owned by the image's user: Docker
# copies a directory's owner into a NEW named volume mounted over it, and without this the
# volume is root's and oyster cannot write its first byte.
FROM debian:13.1-slim@sha256:a347fd7510ee31a84387619a492ad6c8eb0af2f2682b916ff3e643eb076f925a AS fetch
ADD https://github.com/pearl-research-labs/pearl/releases/download/v1.5.5/pearl-linux-arm64-v1.5.5.tar.gz /tmp/pearl.tar.gz
RUN echo "6ab6f4599b1a8bd3493ff244252b3447fca4344cf93ef34e9c5c8a9cc1e569fd  /tmp/pearl.tar.gz" | sha256sum -c - \
 && mkdir -p /out \
 && tar -xzf /tmp/pearl.tar.gz -C /out ./oyster ./prlctl \
 && install -d -o 65532 -g 65532 -m 0700 /out/dot-oyster

# Distroless cc: glibc and libgcc_s, which is all the two binaries link, and no shell.
# Debian 13, because oyster needs glibc 2.39 and Debian 12 ships 2.36. Runs as nonroot
# (65532), whose home is /home/nonroot.
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:3ee00291cf386ec52a552e6a858d555debd74776eb4bfa53fa3df2cd6677515e
COPY --from=fetch /out/oyster /out/prlctl /usr/local/bin/
COPY --from=fetch --chown=65532:65532 /out/dot-oyster /home/nonroot/.oyster

# The config is a read-only mount (compose.yaml), outside the volume, so the volume holds
# only what oyster writes. `run … --create` appends to this entrypoint (README, step 1).
ENTRYPOINT ["/usr/local/bin/oyster", "--configfile=/etc/oyster/oyster.conf"]
