# syntax=docker/dockerfile:1

# infra-dev — a THIN CHILD of gsrpi-dev-base since 2d (2026-08-24). Everything shared
# lives in Dockerfile.base; this file is only what makes this image not or3-dev.
#
# PINNED TAG, never latest: a base rebuild must not change this container until this
# line moves. The base normally comes from ghcr — public, built by
# .github/workflows/dev-base.yml from dev/Dockerfile.base in this repo — so no host
# needs a build order any more. `make base` remains the OFFLINE FALLBACK: it builds the
# identical image locally UNDER THE SAME NAME, and docker prefers a local image over a
# pull, so a GitHub outage or a metered month means building on the host with children
# none the wiser.
ARG BASE_TAG=2026.08.25
FROM ghcr.io/gsfernandes81/gsrpi-dev-base:${BASE_TAG}

# The base ends as the dev user; the installs below write system paths.
USER root

# Ansible. THIS CONTAINER IS A CONTROL NODE, which is the substantive reason it
# exists rather than being a second shell on zero: an ansible run from Termux
# crosses the phone's metered radio to reach boxes that are on zero's own LAN, and
# the same run from in here crosses nothing that costs anything.
#
# ansible-core, never the `ansible` metapackage — the same rule as the phone, and
# ansible/README.md has the sizes. PINNED EXACTLY, unlike Claude Code in the base, and
# for a reason specific to there being two control nodes: a playbook that works on
# one and not the other is the failure mode, and a floating version makes that
# arrive at a moment of its own choosing. The phone is on 2.21.0 as of 2026-08-22;
# that is a divergence and closing it means bumping the phone, not floating this.
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
