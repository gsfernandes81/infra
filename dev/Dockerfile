# syntax=docker/dockerfile:1

# infra-dev — a THIN CHILD of gsrpi-dev-base since 2d (2026-08-24). Everything shared
# lives in Dockerfile.base; this file is only what makes this image not or3-dev.
#
# PINNED TAG, never latest: compose.yaml's x-base-tag, passed as BASE_TAG, is the tag every
# dev container is built on, and this default is only the fallback for a build by hand. The
# base normally comes from ghcr — public, built by
# .github/workflows/dev-base.yml from dev/Dockerfile.base in this repo, on every push to
# main that changes it — so no host needs a build order any more. The corollary of it
# being automatic: after a BASE_TAG bump the tag is real only once that run finishes —
# about five minutes — and `make up` fails on the pull until then.
#
# `make base` remains the OFFLINE FALLBACK: it builds the identical image locally UNDER
# THE SAME NAME, and docker prefers a local image over a pull, so a GitHub outage or a
# metered month means building on the host with children none the wiser. Identical but
# for Crush, which is the latest release on the day it is built; with GitHub or
# repo.charm.sh down, `make base CRUSH_VERSION=none` builds without it.
ARG BASE_TAG=2026.10.26
FROM ghcr.io/gsfernandes81/gsrpi-dev-base:${BASE_TAG}

# The base ends as the dev user; the installs below write system paths.
USER root

# Ansible. THIS CONTAINER IS A CONTROL NODE, which is the substantive reason it
# exists rather than being a second shell on zero: an ansible run from Termux
# crosses the phone's metered radio to reach boxes that are on zero's own LAN, and
# the same run from in here crosses nothing that costs anything.
#
# ansible-core, never the `ansible` metapackage — the same rule as the phone, and
# ansible/README.md has the sizes. PINNED EXACTLY, and the contrast with Claude Code in
# the base is now the sharper one: that is unpinned AND updates itself, this cannot. The
# reason is specific to there being two control nodes — a playbook that works on one and
# not the other is the failure mode, and a floating version makes that arrive at a moment
# of its own choosing. A claude that is a week newer than the phone's costs nothing of
# the kind; an ansible that is costs a run you cannot reproduce. The phone is on 2.21.0
# as of 2026-08-22; that is a divergence and closing it means bumping the phone, not
# floating this.
ARG ANSIBLE_CORE_VERSION=2.21.3
RUN pip install --no-cache-dir "ansible-core==${ANSIBLE_CORE_VERSION}" \
    && ansible --version

# The collections, with the SAME version specs ansible/requirements.yml states.
# Installed system-wide so they are found from any directory and survive a rebuild
# without a volume. They are baked rather than installed at start because a start
# that reaches Galaxy is a start that fails when the network is down.
#
# THESE TWO LISTS MUST AGREE. They are in two places for a dull reason — the build
# context is dev/ and requirements.yml is a directory up, and widening the context
# to the repo root to read one file is worse. `make verify` compares what is
# installed against what requirements.yml asks for, so the drift is caught rather
# than assumed away.
RUN ansible-galaxy collection install --collections-path /usr/share/ansible/collections \
        'ansible.posix:>=2.2.2' \
        'community.general:>=13.3.0' \
        'community.docker:>=5.2.2' \
    && ansible-galaxy collection list

# The docker CLI and the Compose plugin, for ONE job: `docker compose config`, which
# renders a compose file without a daemon. CLAUDE.md asks for the `docker compose config`
# diff before any compose change, and this container could not make it. THERE IS NO
# DAEMON HERE AND THERE MUST NOT BE: no engine is installed, no socket is mounted, and
# DOCKER_HOST points at a path that does not exist, so anything that needs a daemon
# (`up`, `ps`, `pull`) fails at once and says why instead of reaching for a socket that
# somebody mounts later. `config` works under that setting; measured 2026-10-25. `gavin`
# stays out of the `docker` group on the hosts and none of this changes it.
#
# Render against a copy with a made-up `.env`, never the real one: `config` interpolates
# it, so its output IS the secrets (CLAUDE.md, "Verifying changes").
#
# Hash-pinned per architecture, like cloudflared. Both are vendor release assets, the CLI
# from download.docker.com (the static archive carries dockerd too; only the client is
# extracted) and Compose from its GitHub release, whose own .sha256 files these are.
# Compose is a v5 line; the hosts' Alpine `docker-cli-compose` may not be, and a
# difference between the two renderers would show as a diff in `config` output alone.
ARG DOCKER_VERSION=29.9.2
ARG DOCKER_SHA256_arm64=873b3e0207857c3b2f28392fb922f3ea6efe37620c16d4d4aaf2fef409c90b73
ARG DOCKER_SHA256_amd64=9ac225999fd5e863f7694c728ef23d480616b1e5639328fa309befd4243d69eb
ARG COMPOSE_VERSION=5.6.1
ARG COMPOSE_SHA256_arm64=42cfa75f51ad0ccf290bad37899e0038a8c10a0069e85233ecc1d53e3ff1347d
ARG COMPOSE_SHA256_amd64=47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      arm64) triple=aarch64; dsha="${DOCKER_SHA256_arm64}"; csha="${COMPOSE_SHA256_arm64}" ;; \
      amd64) triple=x86_64;  dsha="${DOCKER_SHA256_amd64}"; csha="${COMPOSE_SHA256_amd64}" ;; \
      *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/docker.tgz "https://download.docker.com/linux/static/stable/${triple}/docker-${DOCKER_VERSION}.tgz"; \
    echo "${dsha}  /tmp/docker.tgz" | sha256sum -c -; \
    tar -xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1 docker/docker; \
    rm /tmp/docker.tgz; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
      "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${triple}"; \
    echo "${csha}  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c -; \
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose; \
    docker --version; \
    docker compose version
ENV DOCKER_HOST=unix:///nonexistent-no-daemon-here.sock

# ansible.cfg is read from the CWD, which is why the phone needs `cd ~/infra/ansible`
# before every run and why forgetting it produces "No inventory was parsed" — a real
# half-hour, already spent once. Naming the file absolutely makes `ansible fleet -m ping`
# work from anywhere in the container, including from a claude that has cd'd elsewhere.
# It points into /workspace, so it is the REPO's config in force and there is no second
# copy in the image to drift from it.
#
# HERE AND NOT IN THE BASE, since 2026-08-24: /workspace is a different repo in every
# container built on that base, and the entrypoint publishes the environment into
# ~/.ssh/environment, so a path that is only right here would have reached every ssh
# session in or3-dev as well.
ENV ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg

# Back to the account every session runs as. WORKDIR and CMD are inherited.
USER dev
