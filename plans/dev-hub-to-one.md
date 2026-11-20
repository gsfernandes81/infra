# The dev hub moves from `zero` to `one`

A design from 2026-11-20, for the owner to review before anything is built. It moves the
whole `dev` Compose project, the hub, its `cloudflared` sidecar, `infra` and every other
repo's container, from `zero` to `one`, under Docker, over ssh. When it is done its
reasoning moves to [`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

## Why, and why now

The owner wants `zero` on Leap 16.1 Immutable (piece B, a later design). The infra agent
runs in the dev hub on `zero`, so on `zero`'s day it would be down exactly when the owner
wants it reading the ssh output. With the hub on `one`, the agent follows `zero`'s move
from start to end, with its memories and tools. `zero`'s move also shrinks to Immich,
Syncthing, pearl-wallet and the backup source. `one` has 8 GB against `zero`'s 4.2 GB, and
Immich already presses on `zero`'s memory. The move was already planned for after the
visit ([`microos-cutover.md`](microos-cutover.md),
[`visit-runbook.md`](visit-runbook.md)).

**The owner's calls, 2026-11-20.** The owner approved this design the same day.

1. The hub moves to `one` first, as its own piece. Piece B follows in this session if
   context allows, or from a handoff.
2. The stack comes back exactly as it is: every container, Docker, no memory pool.
3. The agent writes every handover block through to the bring-up on `one` before it goes
   down, and stays up until close to the end.
4. `zero`'s copy stays, stopped, until `one` has run the containers for about three days.
   Removing it is a block of its own then.
5. The stack's uid is a fixed 1001 on every host, and the secrets directories on `one` are
   readable by group 1001.
6. **The Pi 5 gate is withdrawn.** The owner meant `zero` waits for Leap to be proven on a
   Pi 4, which `one` and `three` have done. `decisions.md` gets a row saying so, and the
   ⚠︎SUPERSEDED marks where it says otherwise.
7. **The volumes move as tar files over ssh**, not by `btrfs send`. The volumes are
   directories inside `zero`'s Docker subvolume, so a send would carry the whole store,
   images included, and need a snapshot on `zero` and a copy out of it on `one`. The
   transport is the same two hops either way, since `sudo` on `one` cannot prompt inside a
   pipe. The only batch moved during downtime is small, so an incremental pass buys
   little.

## Goals, non-goals and anti-goals

**Goals:**
- `ssh dev` from the phone lands on the hub on `one`, with no host key warning.
- Every container comes back logged in, with its workspace, history, memories and `.env`.
- Nothing crosses the phone's metered link but keystrokes.
- Every step has a way back until `zero`'s copy is removed.

**Non-goals:** the memory pool (`devpool`, `plans/dev-pool.md` step 1), podman, piece B,
and any change to what the containers run.

**Anti-goals,** which would make it a failure even if `ssh dev` worked:
- both sidecars connected at once, so `ssh dev` lands on either hub at random;
- a volume restored empty, so a container comes up logged out or loses unpushed work;
- a secret left world-readable on either host, or in a file beside its original;
- any change to `one`'s own deployments or to `zero`'s running services.

## Constraints

- `gavin` is not in the docker group on either host, and `sudo` wants a password on a TTY.
  Every host step is a fish block for the owner to paste after `ssh <host>`.
- Leap's Docker starts with an empty store, so it cannot adopt Alpine's
  (`microos-cutover.md`). Every volume moves as a tar file.
- `one` enforces SELinux. Bind mounts need `z`, as `one`'s other deployments carry
  (`decisions.md`, calibre-web's row).
- `gavin` is 1001 on `zero` and 1000 on `one`. The published dev image bakes 1001.
- The owner flies on 2026-11-21. Nothing here needs a hand on a box, so the move can run
  from abroad.

## What changes in the repo

On the branch `dev-hub-to-one`, merged to `main` in two steps. Everything in the first
step is non-breaking on `zero` and lands before the move. The second step lands at the
switch.

**First step, before the move:**

1. **Bind mounts carry `z`.** Every bind in `dev/compose.yaml`: the five secrets
   directories, `cloudflared.yml`, and the long-form `tunnel.json` bind as `bind:
   {selinux: z}`. Lowercase `z`, since the hub and the sidecar share `HUB_SECRETS`. Docker
   on `zero` ignores it. `docker compose config` on `zero` changes only in those lines,
   and the commit shows that diff.
2. **The uid is a fixed 1001.** The hub's build argument and the sidecar's `user:` take
   1001 from one place in `compose.yaml`, not from the checkout's owner. The Makefile's
   `_require-uid` stops comparing against the host. Its reason, root-owned files in a
   mount, no longer applies, because nothing the containers write is a bind mount. The
   `HOST_UID` and `HOST_GID` lines go from `.env.example` and from what `_dev-host.yml`
   writes, and an old `.env` still carrying them must not be refused. The `dev-base.yml`
   comment that says `one` is 1001 is corrected.
3. **Secrets directories are mode 0750, group 1001.** The owner stays `gavin`. Files
   inside are 0640, group 1001. On `zero` group 1001 is `gavin`'s own, so nothing widens
   there. Every task that sets a mode on these follows, or a re-run against `one` would
   lock the hub out at its next restart: the Makefile's mode check, `_dev-host.yml`'s
   directory task and its `authorized_keys` chmod, `server-add-authorized-keys.yml`'s
   create and its live refresh, and `_cf-tunnel.yml`'s `tunnel.json` write.
4. **`make` joins `leap/firstboot.sh`'s packages,** for piece B and any later Leap host.
   `one` gets it by hand (*The handover*, block 1).
5. **A Leap run of the dev stack in CI,** if it fits the simulation's time limit: the hub,
   `infra` and the sidecar (with no tunnel) on the Leap VM, with SELinux enforcing, under
   the fixed uid. It proves that a container reads its GitHub token and its secrets
   directory, and that the hub reaches the container by ssh. The two traps that would
   break the switch are exactly what no CI covers today. The builder judges whether the
   x86_64 images make this practical. If not, block 2 below proves it on `one` before the
   switch.

**Second step, at the switch, in one commit:**

- `hosts/zero/dev` becomes `hosts/one/dev`. Never one on each host, or the deploy play
  deploys the stack on both.
- `dev_host` and `cf_target` default to `one` in `server-create-dev-container.yml`'s two
  halves, and `dev_host` in `server-add-authorized-keys.yml`. The two must move together:
  either alone splits a run across hosts.
- Every doc and message that says the stack is on `zero` follows: `dev/README.md`,
  `README.md` (the port table and the dev section), `CLAUDE.md`, `docs/recovery.md`,
  `docs/ssh-clients.md`, `ansible/README.md`, the Phase 5 row in `management-plane.md`,
  `dev/.env.example`, the headers of `dev/compose.yaml`, `dev/Makefile` and
  `dev/cloudflared.yml`, `hub/entrypoint.sh`'s break-glass line, `dev/login.sh`, the dev
  plays' comments and task names, `dev/status.sh`'s output, `group_vars/fleet.yml`'s `make
  base` comment, and the summaries in `.github/workflows/dev-*.yml`. `grep -rn zero dev/
  ansible/ docs/ *.md` finds them. `decisions.md`'s old rows stay as records.
- `decisions.md` gets three rows: the hub on `one`, the fixed uid, and the Pi 5 gate
  withdrawn. `microos-cutover.md` and `roadmap.md` §3 stop saying `zero` waits for a Pi 5.

## The handover

Fish blocks, each starting with a comment naming its step, each saying what output to
expect and the way back. The agent writes all of them before block 4 and stays up through
block 4.

1. **Prepare `one`, no downtime on `zero`.**
   - Check that gid 1001 is unused on `one` and that `/home/gavin` is mode 0700. If either
     fails, stop: the group read is only safe behind both.
   - Install `make` with `transactional-update pkg install make` and reboot `one`, at the
     owner's say, since `one`'s own apps go down for a few minutes.
   - Pull the branch's first step into `~/infra` on `one`.
   - Measure: on `zero`, every `dev` volume's size; on `one`, the SSD's free space.
   - Check that `one`'s cgroups include `memory` (`/sys/fs/cgroup/cgroup.controllers`),
     since the containers' `mem_limit` is the only ceiling without the pool.
   - Read the hub's `claude-sessions` version and the base tag `zero` runs. If they are
     older than `main`'s, the owner runs `make up` on `zero` first, a separate day, so a
     failure at block 7 means the move and not an upgrade.
   - Make a staging subvolume on `one`'s SSD, owned by `gavin`, mode 0700, mounted through
     the `noauto` top-level entry. Never the SD card.
2. **Secrets and images on `one`.**
   - Copy the five secrets directories and `dev/.env` from `zero` to `one` over the LAN,
     through the phone's forwarded agent (`ssh -A zero`, then to `192.168.86.101`). The
     first connection's host key is checked against `one`'s known fingerprint, not
     accepted blind.
   - Set each directory to 0750 and each file to 0640, group 1001.
   - `make build` on `one`, with `COMPOSE_PROFILES` empty so no tunnel can start. Nothing
     runs yet.
3. **The other repos' volumes.** Every container except the hub, the sidecar and `infra`
   is stopped on `zero` (`stop`, never `down`). Their sessions end. Their volumes are
   streamed with `sudo tar --numeric-owner` from `zero` into the staging subvolume, then
   restored on `one`: project volumes created with Compose's two labels, external ones by
   name, each listed by a throwaway container before its tar is deleted
   (`leap/README.md`'s recipe). One volume at a time, so only the largest exists twice on
   `one`. If even that does not fit, the caches (`*-uv-cache`, `*-zed-server`) are left
   behind and rebuilt. The agent stays up throughout.
4. **The agent goes down.** The agent writes its handoff note and pushes. The owner stops
   the rest of the project on `zero`: `infra` first, then the hub, then the sidecar.
   `docker ps` on `zero` must show no `dev-cloudflared`.
5. **The last volumes.** `hub-state`, `claude-sessions`, `github-tokens`, `queue`,
   `claude-login` and every `infra-*` volume, the same way as block 3.
6. **Bring-up on `one`.** Before `make up`, a check that every volume `compose.yaml`
   names, external and project-owned, exists on `one`. The Makefile's `_require-volumes`
   covers only the external ones, and `up` would create a missing project volume empty
   without a word: a missing `dev_hub-state` is a new host key on every client. `make
   volumes` is never run on `one`. Then `COMPOSE_PROFILES=tunnel` in `.env`, and `make
   up`.
7. **Checks.**
   - `ssh dev` from the phone shows no host key warning, and the menu lists every
     container.
   - The sidecar's log shows its connections registered.
   - In `infra`, the agent finds its memories, `/workspace` on `main` and its worktrees.
   - `make status` passes for each container.

**The way back,** at any point before `zero`'s copy is removed: stop the project on `one`,
sidecar first, then `docker compose start` on `zero`. That is `start`, never `up`, which
could recreate. Work done on `one` in between is pushed first, or it stays on `one`.

**After about three days:** remove `zero`'s copy, at the owner's say. Measure first. Then
`make down`, the external volumes by name, the project's volumes, the secrets directories
(the tunnel credentials must not be left on a host that could start a second connector),
and the dev images. "Exited" is not "absent" (CLAUDE.md).

## Left to the builder

- The fish blocks' exact text and the staging subvolume's name. If block 1 measures the
  last batch as large, rsync may move that batch instead of tar.
- Where the fixed 1001 is spelled in `compose.yaml`, and whether `.env` keeps a `DEV_UID`.
- Whether the CI run in step 5 is practical.
- Whether the caches (`*-uv-cache`, `*-zed-server`) move or are rebuilt. Moving is the
  default, since a cache rebuilt on a Pi 4 costs hours.
