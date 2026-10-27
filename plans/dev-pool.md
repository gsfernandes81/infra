# Plan: one memory pool for the dev containers, and a hub that manages every session

**Proposed 2026-10-25, and its main choices decided the same day by the owner: one compose
file in `infra`, cgroup v2, `claude-sessions` only in the hub** ([`docs/decisions.md`](../docs/decisions.md),
*Dev containers: one compose file in `infra`, …*). **Steps 2 to 4 are live on `zero` since the cutover of
2026-10-27** (decisions.md, *The hub, as built*; what the cutover left open is
[`docs/handoff/2026-10-26-dev-hub.md`](../docs/handoff/2026-10-26-dev-hub.md)). **Step 1, the
pool itself, is what is left.** It belongs to
Phase 5 ([`docs/management-plane.md`](../docs/management-plane.md), the phase table). This file
holds the shape and what is left; the reasons are in decisions.md.

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
   compose file builds each from its repo's GitHub URL (`main`).

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

5. **One `cloudflared` sidecar, one tunnel.** It serves the hub's hostname, `dev.<dns_zone>`.
   This replaces `infra-dev`'s connector started from its own entrypoint, and matches Phase 5's
   sidecar leaning. **As built, no per-container hostname but or3-dev's**, which moves onto
   this tunnel for the phone's reverse forward to the vessel; otherwise the break-glass path is
   `make shell C=<c>` on `zero`, which never depended on a tunnel.

## Open, the owner's

- ~~**The pool's size and swap limit.**~~ Decided 2026-10-27: 2560M and 6G. `zero` has 4 GB. Immich's machine learning peaks lower
  after v3.3.5, and ~2.3 GB was available on 2026-10-25 before that.
- ~~**`or3-dev`'s shared working tree.**~~ Decided 2026-10-27, the owner: every workspace,
  or3's included, is a clone in a volume (decisions.md).

## Order, and where each step stands

1. **Written, not installed (2026-10-27).** `hosts/zero/system/devpool`, an OpenRC service
   making `/sys/fs/cgroup/devpool` at 2560M of RAM and 6G of swap (the owner's, 2026-10-27:
   swap enough to reach through zram into the SSD swap). Its install and calibrated proof are `hosts/zero/system/README.md` §
   *devpool*. Until it is proved, `DEV_CGROUP_PARENT` stays empty and Compose sets no parent.
2. **Released, 2026-10-27.** The hub rewrite, in the claude-sessions repo: `agent`, `install`,
   `offload-all` and the containers-first menu, as `v0.5.0`, pinned and checksummed in
   `dev/hub/Dockerfile`.
3. **Live, 2026-10-27.** The one compose file in `infra`: the hub, the sidecar, the network,
   and `infra-dev`, with its workspace and `.env` files in volumes.
4. **Live, 2026-10-27, with step 3** (dd-dev and ds-dev stopped at rest, as before). `or3-dev`, `dd-dev` (with `dd-postgres`)
   and `ds-dev` are in `dev/compose.yaml`, built from their repos' own Dockerfiles on the new
   base, each working in its own clone in a volume, their old volumes named from the fleet
   inventory. Each child repo drops its compose file now that the cutover is done (the handoff). **or3-dev also re-points
   its hostname at the hub's tunnel** (`-e via_hub=true`), so the phone's `or3-tunnel` keeps
   reaching it; or3's `docs/dev-tunnel.md` then names `~/infra/dev` for `make tunnel-log`,
   `make up` and `make shell C=or3` in place of `~/or3/dev`, which is or3's change to make.

## Done when

All four steps are done, the reasoning is in `decisions.md`, and Phase 5's row says what was
built. Then this file is deleted.
