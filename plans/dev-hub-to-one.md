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
   switch. **The planner's call:** not practical in a VM pulling the images, so
   `dev-smoke` checks that every bind carries `z` and that the containers read secrets
   through group 1001, and block 2 proves the SELinux half on `one` with a throwaway
   container.

**Second step, at the switch, in one commit:**

- `hosts/zero/dev` becomes `hosts/one/dev`. Never one on each host, or the deploy play
  deploys the stack on both.
- `dev_host` and `cf_target` default to `one` in `server-create-dev-container.yml`'s two
  halves, `dev_host` in `server-add-authorized-keys.yml`, and `target` in
  `server-start-dev-containers.yml`. The first two must move together:
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
   - Create the group `devstack`, gid 1001, with `gavin` as its only member. The plays run
     as `gavin` without `become`, and a user can set a file's group only to one they
     belong to. `gavin` owns the files anyway, so the membership grants nothing new.
     `hosts/one/leap/combustion/script` makes the same group, so a rebuilt `one` matches.
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

## Build plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the first step of *What changes in the repo*, merged to `main`, then the
handover blocks and the switch commit.

**Architecture:** the stack's uid becomes a literal 1001 in `dev/compose.yaml`; the host
side meets it with group 1001 on every secrets directory and file. Every bind carries
SELinux `z`. Nothing on `zero` changes in effect, because `gavin` is 1001:1001 there.

**Tech stack:** Docker Compose 5.6.1, GNU make, Ansible, GitHub Actions, fish for the
handover blocks.

**Spec:** this file's sections above.

### Global constraints

- uid and gid: `1001:1001`, a literal, read from nothing on the host.
- Secrets directories `0750`, files inside `0640`, group `1001`, owned by the ssh user.
- SELinux option: lowercase `z`, never `Z`.
- `zero`'s running containers see no change. `docker compose config` with the same `.env`
  differs only in the lines Task 1 names.
- Docs change in the same commit as what they describe (CLAUDE.md § Git & workflow).
- Tests run in their own call and are read before any commit; never chained to a push.
- Each task: the two-way secret scan before commit; a Fable review of the task's diff, its
  findings applied, before the merge.
- No step runs against the fleet. Blocks are handed to the owner.

### Review focus

1. A `dev/.env` from before this change, still carrying `HOST_UID=` and `HOST_GID=`, must
   pass `make check` and `docker compose config` unchanged. Task 1 tests it.
2. The host tunnels' callers of `_cf-tunnel.yml` (root-owned
   `/etc/cloudflared/<host>.json`) must still write mode `0600`. Task 2 tests it.
3. A re-run of `_dev-host.yml` against a host whose secrets are `0700`/`0600` (as on
   `zero` today) converges to `0750`/`0640`, group 1001, and does not refuse. Task 2
   tests it.
4. The long-form `tunnel.json` bind must still fail the start on a missing file after `z`
   is added (`create_host_path: false` kept). Task 1 tests it.
5. The hub built in CI at 1001 must still hit `dev-cache.yml`'s cache: the build args stay
   `USER_UID=1001`, `USER_GID=1001`. Task 1 tests it.

### Task 1: the fixed uid and SELinux `z` in the dev stack

**Files:**
- Modify: `dev/compose.yaml` (hub `build.args` at :141-142, sidecar `user:` at :234, the
  binds at :202, :243, :246-250, :299, :363, :413, :476, and the comments explaining them)
- Modify: `dev/Makefile` (`HOST_UID`/`HOST_GID` at :49-50, :60, :70; `_require-uid` at
  :196-208 and its uses in `check` and `base`; `base` at :240-243 builds at 1001;
  `_require-secrets`' mode warning at :231 expects 750)
- Modify: `dev/.env.example` (:10-15, the *whose files* block goes)
- Modify: `.github/workflows/dev-smoke.yml` (:106-107, :117-118), `dev-cache.yml` (:18-20,
  :80, :97-98), `dev-base.yml` (:287-292 comment)
- Modify: `dev/README.md:1203-1206`, `CLAUDE.md:50` (the `HOST_UID` sentence)
- Modify: `docs/decisions.md`, a new row: *The dev stack runs as 1001 on every host*

**Interfaces:**
- Produces: compose no longer reads `HOST_UID`/`HOST_GID`; Task 2 stops writing them.

- [ ] **Step 1: Capture the baseline.** With a stand-in `.env` built as `dev-smoke.yml`
  builds it (`HOST_UID=1001`, `HOST_GID=1001`), run
  `COMPOSE_PROFILES=tunnel docker compose config > $SCRATCH/before.yaml` in `dev/`. No
  daemon is needed for `config`.
- [ ] **Step 2: Add the failing CI checks to `dev-smoke.yml`.**
  - *every bind carries z:* `docker compose config --format json | jq` lists every volume
    of `type: bind` and fails unless each has `bind.selinux == "z"`.
  - *secrets read through the group:* the stand-in secrets directories are made
    `chown 0:1001`, `0750`, files `0640`, so the container user is not the owner, and the
    existing smoke steps (hub healthy, a container reads its secrets mount) must pass.
  - *an old .env still works:* `HOST_UID=1001` and `HOST_GID=1001` appended to the
    stand-in `.env`, then `make check` and `docker compose config -q` must pass.
- [ ] **Step 3: Run the checks locally where they can run** (the jq check against the
  current compose file must fail, listing every bind). Expected: FAIL naming the binds.
- [ ] **Step 4: Implement.** Hub `USER_UID: "1001"`, `USER_GID: "1001"`; sidecar
  `user: "1001:1001"`; `:ro,z` on the short-form binds; `bind: {create_host_path: false,
  selinux: z}` on the long form; Makefile, `.env.example`, workflows, README, CLAUDE.md
  and the decisions row as listed. `make base` passes `USER_UID=1001 USER_GID=1001`.
- [ ] **Step 5: Diff the config.** Same stand-in `.env`, `after.yaml`, then
  `diff before.yaml after.yaml`. Expected: only `selinux: z` lines added to binds, and
  the hub's args and the sidecar's user unchanged in value (1001).
- [ ] **Step 6: Check the missing-file case.** With `tunnel.json` absent and the tunnel
  profile on, `docker compose config` still shows `create_host_path: false` on that bind.
- [ ] **Step 7: Commit, push the branch, and read `dev-smoke` and `dev-cache` on it.**
  Message: `dev hub to one: the stack runs as 1001 on every host and every bind carries z,
  so one's gavin at 1000 and its selinux both serve it, with nothing changed on zero`.

### Task 2: the plays write the secrets for group 1001

**Files:**
- Modify: `ansible/playbooks/_dev-host.yml` (:51-56 directories `0750`, group 1001;
  :67-72 `authorized_keys` `0640`, group 1001; :84-106 the checkout-owner stat and the
  `HOST_UID`/`HOST_GID` lines go; :22-23 and :133 comments)
- Modify: `ansible/playbooks/server-add-authorized-keys.yml` (:185-191 create `0640`,
  group 1001; the live refresh at :233-266 is unchanged, and now reads)
- Modify: `ansible/playbooks/_cf-tunnel.yml:250-266`: `mode: "{{ cf_creds_mode |
  default('0600') }}"`; the dev caller (`_dev-container-tunnel.yml`) passes
  `cf_creds_mode: "0640"` and `cf_creds_group: "1001"`
- Modify: `dev/README.md` where it states the secrets modes

**Interfaces:**
- Consumes: Task 1's compose, which no longer reads `HOST_UID`.

- [ ] **Step 1: Write the failing check.** A scratch play or `--check --diff` run of
  `server-create-dev-container.yml` against a localhost stub whose secrets are
  `0700`/`0600`, expecting the diff to show `0750`/`0640` and group 1001. Expected: FAIL
  (the play still writes `0700`/`0600`).
- [ ] **Step 2: Implement the modes and groups as listed.**
- [ ] **Step 3: Run the check again.** Expected: the stub converges, and a second run
  reports no change.
- [ ] **Step 4: `ansible-playbook --syntax-check`** on `server-create-dev-container.yml`,
  `server-add-authorized-keys.yml` and every play that imports `_cf-tunnel.yml`
  (`grep -l _cf-tunnel ansible/playbooks`). Expected: all pass. Then
  `grep -n cf_creds_mode ansible/playbooks` shows only the dev caller setting it.
- [ ] **Step 5: Commit and push.** Message: `dev hub to one: the dev plays write secrets
  for group 1001, so a re-run against one cannot lock the hub out of its own keys`.

### Task 3: `make` on Leap hosts, and the Pi 5 gate withdrawn

**Files:**
- Modify: `leap/firstboot.sh:52-53` (`make` in `common_packages`), `leap/README.md` if it
  lists the packages
- Modify: `docs/decisions.md`, a row: *`zero` waits for a Pi 4's proof, not a Pi 5's*;
  ⚠︎SUPERSEDED on the text it replaces
- Modify: `plans/microos-cutover.md`, `docs/roadmap.md` §3, the Phase 9 row in
  `docs/management-plane.md`, wherever they say `zero` waits for a Pi 5

- [ ] **Step 1: Add `make` and the docs.**
- [ ] **Step 2: `grep -rn "Pi 5" docs plans`** and read each hit. Expected: none still
  says `zero` waits for one.
- [ ] **Step 3: Push and read `microos-sim`'s aarch64 package job.** Expected: green.
- [ ] **Step 4: Commit.** Message: `leap: make on every host, which the dev stack's
  management interface needs, and zero's move waits only on the pi 4's proof, as the owner
  meant`.

### Task 4: merge the first step

- [ ] A Fable review of the whole branch against this design; findings applied.
- [ ] `dev-smoke`, `dev-cache` and `microos-sim` green on the branch head.
- [ ] Merge to `main` and push. The branch stays for the switch.

### Task 5: the handover (the agent, not a sub-agent)

- [ ] Write blocks 1 and 2 (*The handover*) for the owner, in chat, and read their output.
  Block 2 adds the on-box proof: as the owner's user,
  ```fish
  sudo docker run --rm --user 1001:1001 -v ~/.dev-secrets:/s:ro,z alpine:3.22 \
      cat /s/authorized_keys
  ```
  must print the keys under SELinux on `one`.
- [ ] From block 1's sizes, write blocks 3 to 7 and the way back into
  `docs/handoff/<date>-dev-hub-to-one.md`, pushed before block 4, so the owner has them
  once the agent is down.

### Task 6: the switch commit

- [ ] On the branch, after Task 4's merge: the second step of *What changes in the repo*.
  Opened as a PR, not merged. The session that wakes on `one` merges it once block 7's
  checks pass, and deletes this file once nothing in it is open.
