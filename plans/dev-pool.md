# Plan: one memory pool for the dev containers, and a hub that manages every session

**A proposal, 2026-10-25, from the owner's direction in session; nothing here is decided
or built.** It belongs to Phase 5 ([`docs/management-plane.md`](../docs/management-plane.md),
the phase table) and changes what that phase builds. When it is taken, the reasoning moves
to [`docs/decisions.md`](../docs/decisions.md) and this file shrinks to what is left.

## Why

The owner has more repos than dev containers, and each extra container has been one more
place to ssh into to find out whether anything is running. Measured 2026-10-25:

- **An idle dev container is ~13 MB**: base `2026.10.16`, started here as
  `dev/compose.yaml` does, with no tunnel and no claude (sshd, the entrypoint, the offload
  loop). A `cloudflared` connector adds ~15 MB (the sidecars on `one`).
- **A live claude is ~250 MB**, per `dev/README.md`. That figure predates a real-login
  re-measure, which [`claude-sessions.md`](claude-sessions.md) still lists as open.

So what limits `zero` is the number of live sessions, not the number of containers. What
limits the owner is having to manage each container separately.

## The shape

1. **One small container per repo, as today.** The children are unchanged in kind: same
   base, same five seams, each repo's own secrets.

2. **One memory limit for all of them: a parent cgroup.** Every dev container sets
   `cgroup_parent: /devpool`, and the limit is written once, on the pool. Per-container
   `mem_limit`s stay, as ceilings inside it. When the pool is full the kernel kills a process
   inside it, and nothing outside (Immich) is touched.
   - **Tested here, 2026-10-25** (Docker 29, `cgroupfs` driver, cgroup v1): two containers
     under a 300 MB parent, each allocating 200 MB. The second pushed the pool over, and the
     kernel killed the first's process inside the pool. Compose 5.6.1 accepts
     `cgroup_parent:`.
   - **Read the kernel log, not Docker's flag:** Docker reported `OOMKilled=true` for both
     containers, including the one that was not killed.
   - **The victim is the pool's largest process**, which may be a busy session in another
     repo than the one that grew.
   - **Compose cannot set the pool's limit.** It is a tracked file in `hosts/zero/system/`,
     with an `infra-` header, run at boot before anything starts a dev container: create the
     cgroup and write its limit. On cgroup v2 it also enables `+memory` in the pool's
     `cgroup.subtree_control`. On MicroOS it becomes a `dev.slice` with `MemoryMax=`, which
     rootless podman can use there.

3. **A hub container: `claude-sessions`, rewritten for one consumer.** The owner is the only
   user, so `claude-sessions` becomes the tool that runs in its own small container and ssh-es
   into every dev container on the box.
   - **What the owner gets:** one menu listing every session in every container; Enter
     attaches (`ssh -t <container>` into the slot); any session can be stopped from it.
   - **Built in, not adopted:** off-the-shelf managers (Agent Deck's ssh remotes, CCManager,
     claude-squad) drive tmux sessions they started, and the slots here are zmx.
   - **It needs, in the claude-sessions repo:** a hub mode whose sources are the containers
     on the dev network, a machine-readable `list` per container, and a `stop SLOT` (today
     `close` refuses a running slot, and only the offloader stops one).
   - **Already in place:** the dev containers run a forwarded command as given (the door), so
     `ssh <container> claude-sessions list` works now.
   - **The hub holds one dedicated key, authorised in every dev container.** The owner's
     reasoning, accepted: the hub sits behind public-key auth and a Cloudflare Access login,
     and that reach is no wider than an ssh login on `zero` already gives (an attacker there
     waits for the next `sudo`). The rule that comes with it: **the key lives only in the
     hub, which runs no agent**. It is never mounted into a dev container, so no claude
     session can use it.

4. **One network, `dev`.** The hub and every dev container join it, and a container's sshd is
   reached on it by name. Nothing is published on `zero`, so the loopback ports `dd`, `ds` and
   `or3` still publish go.

5. **One `cloudflared` sidecar, one tunnel.** It serves the hub's hostname, plus a direct
   hostname per container as a break-glass path. This replaces `infra-dev`'s connector started
   from its own entrypoint, and matches Phase 5's sidecar leaning.

## Open, the owner's

- **One compose file in `infra`, or each repo keeps its own** and joins the pool and the
  network. The pool works either way. One file reverses *Claude dev containers stay in their
  own app repos* (decisions.md) for every child.
- **The pool's size and swap limit.** `zero` has 4 GB. Immich's machine learning peaks lower
  after v3.3.5, and ~2.3 GB was available on 2026-10-25 before that.
- **`zero`'s cgroup version** (`stat -fc %T /sys/fs/cgroup`: `cgroup2fs` is v2), which
  decides the pool file's exact lines.
- **Whether offloading moves to the hub** or stays per container. Measuring a slot's activity
  needs `/proc` in that container.

## Order, once taken

1. The pool file on `zero`, proved by attempting to over-allocate inside the pool and
   requiring the kill to land there (CLAUDE.md: calibrate the check first).
2. The hub mode, in the claude-sessions repo.
3. The hub container and the sidecar, in `dev/`.
4. Each child joins the pool and the network, and drops its published port, in its own repo
   or the shared compose file, per the open choice above.

## Done when

All four steps are done, the reasoning is in `decisions.md`, and Phase 5's row says what was
built. Then this file is deleted.
