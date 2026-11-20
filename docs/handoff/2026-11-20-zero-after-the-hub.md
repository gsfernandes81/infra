# Handoff, 2026-11-20: `zero` after the dev hub left it

The dev hub runs on `one` since 2026-11-20 (`decisions.md` § *The dev hub runs on `one`*).
Two pieces of work on `zero` are left, and this note is the next session's orders for
both. The session that wrote it ran out of room to design the second.

**First orders:** read this note, check each line against the repo (`git log`, the files
named) and against what the owner pastes from a box, report where things stand, and wait
for the owner to pick one of the two pieces. Findings go into the phase table of
`docs/management-plane.md`, not into work.

**How the owner works**, all of it from the last session:

- Short numbered replies; a running list of what is left at the end of each reply, top
  items by priority and a last item of low-priority, blocked or later things.
- Handover blocks for fish on a TTY, each starting with a comment naming its step, and
  **every block repeated in full when it is next up**, never "the block above".
- Designs reviewed before builds. A design goes through a Fable builder check; a build
  through a sub-agent per task, a review per task and a whole-branch Fable review, with
  the findings applied before the merge. Merges to `main` on the owner's word.
- From the laptop's WSL, the fleet ssh config shares connections, so `ssh -A` and a
  just-added group need `ssh -o ControlPath=none host` (or `ssh -O exit host` first).
  Windows' own `ssh` does not share.

## 1. Phase 10's end: remove `zero`'s copy of the dev stack

`zero`'s dev project is stopped, not removed, as the way back. The owner's call: it goes
once `one` has run the containers for about three days, so **from about 2026-11-23**, at
the owner's say. Until then, never `make up` or `start` it on `zero` except as the way
back: its `.env` still names the tunnel, so a second connector would start and `ssh dev`
would land on either hub.

The way back, while it exists: on `one`, `sudo docker stop dev-cloudflared` then `cd
~/infra/dev; and sudo docker compose stop`; on `zero`, `cd ~/infra/dev; and sudo docker
compose start` (`start`, never `up`).

Write the removal as fish blocks for `ssh zero`, in this order:

1. **Measure**: `sudo du -sh` each volume below, and `sudo docker images` for the dev
   images, so the owner sees the size before anything goes. First, on `one`, `sudo docker
   volume ls` and a `du -sh` of the same volumes, so each copy on `one` is shown to exist
   and not be empty before its original on `zero` goes. And `sudo docker volume inspect`
   the anonymous volume `294c1145…` (in the 2026-11-20 paste), which no compose file
   names: find its owner before anything is removed.
2. **The containers and network**: `cd ~/infra/dev; and sudo docker compose down`.
   "Exited" is not "absent" (CLAUDE.md), so this comes before any file is deleted.
3. **The volumes**, by name, each `sudo docker volume rm`:
   - the project's own: `dev_claude-sessions dev_hub-state dev_github-tokens dev_queue
     dev_claude-login` and `dev_<x>-workspace dev_<x>-env` for `infra or3 dd ds invective
     nibbles ionic claude-sessions`;
   - the external ones, as named in `dev/compose.yaml`'s `volumes:` (each with `external:
     true, name: …`): `infra-dev_infra-*`, `or3-dev_or3-*`, `destiny-director_dd-*`,
     `dossier_ds-*`, `invective-dev_invective-*`, `nibbles-dev_nibbles-*`,
     `ionic-dev_ionic-*`, `claude-sessions_claude-sessions-*`;
   - **and `destiny-director_dd-mysql-data`**, which no compose file names: the owner said
     on 2026-11-20 it is unimportant and can be deleted outright.

   List them from `dev/compose.yaml`, never from a glob over `/var/lib/docker/volumes`,
   which also holds Immich's and Syncthing's.
4. **The dev images** (`dev-hub infra or3 destiny-director dossier invective nibbles
   ionic-traces claude-sessions` and the base `ghcr.io/gsfernandes81/gsrpi-dev-base`).
   The project also pulled `postgres:17-alpine` and `cloudflare/cloudflared:2026.10.3`;
   each goes only if `sudo docker ps -a --format '{{.Image}}'` shows no Immich,
   Syncthing or pearl-wallet container using it.
5. **The secrets**: `rm -r ~/.dev-secrets ~/.infra-dev-secrets ~/.or3-dev-secrets
   ~/.dd-dev-secrets ~/.ds-dev-secrets` and `~/infra/dev/.env`. The tunnel credentials
   must not stay on a box that could start a second connector.
6. **Then** `git -C ~/infra pull --ff-only` on `zero`. Not before step 2: the next `up` of
   a pulled checkout would recreate the stack there.

When it is done: strike phase 10 in the phase table and delete this section. With it,
in the repo: delete `hosts/zero/system/devpool`, which was written and never installed
and now has no stack to limit, with its row and section in `hosts/zero/system/README.md`
and the `dev/README.md` paragraph that names it (the `plans/dev-pool.md` item under
*Open items: dev* decides whether a pool on `one` replaces it). The worktree
`dev-hub-to-one` and its branch are already gone.

## 2. Phase 12: `zero` to Leap 16.1 Immutable

Filed: the inventory and the design are in
[`plans/zero-leap.md`](../../plans/zero-leap.md), with the traps this section listed. The
owner's questions are open there.

**Delete this note** once both pieces are done or filed, after moving anything durable
into `decisions.md`.
