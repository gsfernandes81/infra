# Plan: one memory pool for the dev containers, and a hub that manages every session

**Proposed 2026-10-25, and its main choices decided the same day by the owner: one compose
file in `infra`, cgroup v2, `claude-sessions` only in the hub** ([`docs/decisions.md`](../docs/decisions.md),
*Dev containers: one compose file in `infra`, …*). **Nothing is built.** It belongs to Phase 5 ([`docs/management-plane.md`](../docs/management-plane.md),
the phase table) and changes what that phase builds. This file holds the shape and what is
left; the reasons are in decisions.md.

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

1. **One small container per repo, all in one compose file in `infra`.** The children keep
   their base, their seams, their own secrets and their own Dockerfiles in their repos; the
   compose file builds each from an absolute checkout path in its `.env` (no `..`).

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
     cgroup and write its limit. **`zero` is on cgroup v2** (the owner, 2026-10-25, set up as
     Alpine recommends; the file's first step confirms `cgroup2fs`), so the file writes
     `memory.max` and `memory.swap.max` and enables `+memory +pids` in the pool's
     `cgroup.subtree_control`. The test above was v1; **v2 is proved on `zero`** in step 1
     below. On MicroOS it becomes a `dev.slice` with `MemoryMax=`, which rootless podman can
     use there.

3. **A hub container: `claude-sessions`, rewritten for one consumer, and run nowhere else.**
   The owner is the only user, so `claude-sessions` becomes the tool that runs in its own small
   container and manages every dev container over ssh — the menu, attaching, stopping **and
   the offloader**, which keeps its rule (measured activity, ten quiet minutes, a keep-alive
   holds a slot) and measures each container's slots remotely.
   - **What the owner gets:** one menu listing every session in every container; Enter
     attaches (`ssh -t <container>` into the slot); any session can be stopped from it.
   - **Built in, not adopted:** off-the-shelf managers (Agent Deck's ssh remotes, CCManager,
     claude-squad) drive tmux sessions they started, and the slots here are zmx.
   - **The rewrite, in the claude-sessions repo, has to settle what a dev container keeps**
     once the binary is gone from it: something the hub can read for its slots (zmx sessions)
     and their activity (`/proc`, over ssh), a keep-alive a claude in the slot can still set,
     and replacements for the two things the binary supplies through Claude Code's managed
     settings today — the hooks that feed the registry, and the status line.
   - **The door leaves the dev containers.** A login to one lands in a shell, or attaches the
     slot it names; the menu is the hub's. A forwarded command already runs as given, which is
     what the hub's ssh calls need.
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

- **The pool's size and swap limit.** `zero` has 4 GB. Immich's machine learning peaks lower
  after v3.3.5, and ~2.3 GB was available on 2026-10-25 before that.
- **`or3-dev`'s shared working tree.** Its `/workspace` is `zero`'s own clone, by or3's design
  (management-plane.md, *The `or3-dev` caveat*); moving its definition into `infra` can keep
  that bind mount, but it is or3's trade to confirm.

## Order, once taken

1. The pool file on `zero`, proved by attempting to over-allocate inside the pool and
   requiring the kill to land there (CLAUDE.md: calibrate the check first).
2. The hub rewrite, in the claude-sessions repo.
3. The one compose file in `infra`: the hub, the sidecar, the network, and `infra-dev` first.
4. Each child moves in, joins the pool, and drops its published port; its repo keeps the
   Dockerfile and loses its compose file.

## Done when

All four steps are done, the reasoning is in `decisions.md`, and Phase 5's row says what was
built. Then this file is deleted.
