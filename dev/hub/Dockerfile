# syntax=docker/dockerfile:1

# dev-hub — the one container an ssh login to the dev containers lands on (`ssh dev`).
#
# It runs claude-sessions' menu over every dev container, and the offload timer that
# measures them, and nothing else: no Claude Code, no node, no repo. Every container's
# sessions are still read and changed inside that container, by the same binary, which this
# image carries and installs into the `claude-sessions` volume they all mount read-only
# (claude-sessions' docs/design.md § "The hub"). So the version every dev container's hooks,
# agent and offload pass run is pinned HERE, once, and reaches them at the hub's next start —
# no base bump, no child bump.
#
# It holds one key that every dev container authorises (decisions.md, the dev-pool rows):
# generated at first start in its own volume, never mounted anywhere else, and the reason
# this image runs no agent of any kind. Its sshd is reached only through the cloudflared
# sidecar in dev/compose.yaml; nothing is published on the host.
#
# SAME BOTTOM LAYERS AS gsrpi-dev-base, on purpose: the python base by the same digest
# (Dockerfile.base explains the pin), so on zero, which already holds the base, this image
# costs only its own few layers. Bump the two digests together.
# ── claude-sessions: the hub's menu, and every container's hooks, agent and offloader ──
# A PINNED RELEASE, HASH-CHECKED PER ARCHITECTURE, the shape Dockerfile.base used for it and
# for cloudflared: the claim is "the same bytes", and every claude on the fleet runs these
# bytes on every prompt. NEVER COMPILED HERE (a Rust build under QEMU is unusable).
#
# IN A STAGE OF ITS OWN, `fetch`, so the smoke test (.github/workflows/dev-smoke.yml) can
# put a binary built from claude-sessions' source in its place with a named build context —
# that is how an UNRELEASED claude-sessions is tested against this image before it is
# published. Nothing else ever overrides it: zero builds this stage as written.
#
# A BUMP is the version and both hashes together, from the new release's SHA256SUMS asset
# (also in its notes). A wrong hash fails this build at `sha256sum -c`, loudly, by design.
FROM python:3.13-slim-trixie@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c AS fetch
ARG CLAUDE_SESSIONS_VERSION=0.7.0
ARG CLAUDE_SESSIONS_SHA256_arm64=feac17055ab87caa5bb7ee0e8fde6e15fcbf0f8ece80802a5b606f466dfe5b25
ARG CLAUDE_SESSIONS_SHA256_amd64=b8ca08fa80f7aabdd8da6293aab07a4cd2d9b1479836a49b027a1b4696506cb2
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) triple=aarch64; sha="${CLAUDE_SESSIONS_SHA256_arm64}" ;; \
      amd64) triple=x86_64;  sha="${CLAUDE_SESSIONS_SHA256_amd64}" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out; \
    curl -fsSLo /out/claude-sessions \
      "https://github.com/gsfernandes81/claude-sessions/releases/download/v${CLAUDE_SESSIONS_VERSION}/claude-sessions-v${CLAUDE_SESSIONS_VERSION}-${triple}-linux-musl"; \
    echo "${sha}  /out/claude-sessions" | sha256sum -c -; \
    chmod 0755 /out/claude-sessions

FROM python:3.13-slim-trixie@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# openssh-server is the door; openssh-client reaches the containers; procps for whoever
# debugs it; openssl signs the GitHub App's JWT (github-tokens).
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server openssh-client procps ca-certificates tzdata less openssl \
    && rm -rf /var/lib/apt/lists/*

# `--version` IS FATAL and compared exactly: a static musl binary has no excuse, and it is
# also what proves a binary the smoke test put in place is the version this file pins.
ARG CLAUDE_SESSIONS_VERSION=0.7.0
# The binary sits off PATH; what PATH finds is hub/claude-sessions, which hands it the container
# list (that file says why). `install` copies the running binary, so the containers get this one.
COPY --from=fetch /out/claude-sessions /usr/local/libexec/claude-sessions
COPY claude-sessions /usr/local/bin/claude-sessions
RUN chmod 0755 /usr/local/bin/claude-sessions \
    && test "$(/usr/local/libexec/claude-sessions --version)" = "claude-sessions ${CLAUDE_SESSIONS_VERSION}"

# The door — sshd's ForceCommand: the menu at a terminal, a shell otherwise or if it fails.
# Root-owned, on PATH, above the USER line for the reason Dockerfile.base gives for its own.
COPY door /usr/local/bin/hub-door
# The GitHub token broker (dev/README.md § "GitHub tokens, one repo each"). Python's standard
# library, which this image is built on, and openssl for the App's RS256 signature.
COPY github-tokens /usr/local/bin/github-tokens
# The healthcheck, and `make status`'s word on the hub (health says why).
COPY health /usr/local/bin/hub-health
RUN chmod 0755 /usr/local/bin/hub-door /usr/local/bin/github-tokens /usr/local/bin/hub-health

# The dev user, at the uid that owns the checkout — the same uid as every dev container's
# `dev`, so the files this writes into the shared volume read as their own user's there
# (sshd's StrictModes checks the owner of the key it is handed). bash, not fish: this
# container's shell is for when the menu fails, and nothing else.
RUN if ! getent group "${USER_GID}" >/dev/null; then groupadd --gid "${USER_GID}" "${USERNAME}"; fi \
    && if ! getent passwd "${USER_UID}" >/dev/null; then \
        useradd --uid "${USER_UID}" --gid "${USER_GID}" --shell /bin/bash -m "${USERNAME}"; fi \
    && mkdir -p /opt/claude-sessions && chown "${USER_UID}:${USER_GID}" /opt/claude-sessions

ENV TZ=Etc/UTC

USER ${USERNAME}
WORKDIR /home/dev

# The volumes' mountpoints, made as dev so an empty volume inherits dev's ownership.
# Every volume's mountpoint, as `dev`: a new named volume takes the owner of the directory it
# mounts over, and one the image lacks is root's. ~/tokens was missing until the smoke test's
# first run (2026-10-27): the broker could not make a container's directory, and the hub never
# reported healthy.
RUN mkdir -p /home/dev/.hub /home/dev/.ssh/cm /home/dev/tokens /home/dev/.claude-login \
    && chmod 700 /home/dev/.hub /home/dev/.ssh /home/dev/.ssh/cm /home/dev/.claude-login

COPY --chown=${USER_UID}:${USER_GID} sshd_config /home/dev/sshd_config
COPY --chown=${USER_UID}:${USER_GID} ssh_config /home/dev/.ssh/config
COPY --chown=${USER_UID}:${USER_GID} entrypoint.sh /home/dev/entrypoint.sh
EXPOSE 2222

CMD ["bash", "/home/dev/entrypoint.sh"]
