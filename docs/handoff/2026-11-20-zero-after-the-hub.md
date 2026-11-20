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
   images, so the owner sees the size before anything goes.
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
5. **The secrets**: `rm -r ~/.dev-secrets ~/.infra-dev-secrets ~/.or3-dev-secrets
   ~/.dd-dev-secrets ~/.ds-dev-secrets` and `~/infra/dev/.env`. The tunnel credentials
   must not stay on a box that could start a second connector.
6. **Then** `git -C ~/infra pull --ff-only` on `zero`. Not before step 2: the next `up` of
   a pulled checkout would recreate the stack there.

When it is done: strike phase 10 in the phase table, delete this section, and remove the
worktree `dev-hub-to-one` (branch `dev-hub-switch`, merged as PR #24) if it is still
there.

## 2. Phase 12: `zero` to Leap 16.1 Immutable

**What is decided** (the owner, 2026-11-20; the start of the design is
[`plans/zero-leap.md`](../../plans/zero-leap.md)):

- The owner is at `zero` with a new SD card and a Combustion stick made by
  `leap/make-stick` on Alpine. They boot the new card, the rest happens over ssh, and the
  Alpine card is the way back, so the move writes nothing Alpine cannot read on its next
  boot.
- Go or no-go when it is ready; a no-go is fine and nothing is rushed.
- The gate was a Pi 4's proof, already given. Phase 12 is ordered after 10 and 11 (the
  phase table).
- Immich and Syncthing come back first; Docker as today; pearl-wallet and the backup
  source `three` pulls from come too.

**What to do first:** the inventory, which the last session started and lost in the move.
For every item, file:line, and what it means for the move:

1. Every file in `hosts/zero/system/` against its Leap form: a file to adapt from
   `hosts/one/leap/system/` or `hosts/three/leap/system/`, something Leap does itself
   (bcache-tools' udev rule for `bcache-register`, zram-generator for `zram-swap`,
   crypttab for `dmcrypt`/`dm-crypt.conf`, snapper is native), or nothing.
2. The array: btrfs RAID1 over two bcache devices, one of them the LUKS2 member
   `data-luks-4` (mapping `data-4`, key file `/etc/keys/data.key` on the card); the cache
   SSD's `sda1` cache, `sda2` Docker store, `sda3` swap; each fstab entry's UUID and
   subvolid. Which way LUKS and bcache stack (`decisions.md` § *`zero`'s encrypted
   member*, `plans/visit-runbook.md` § Slice 2), and how crypttab orders against bcache
   assembly.
3. Immich's, Syncthing's and pearl-wallet's binds and named volumes. Leap's Docker cannot
   adopt Alpine's store, so `zero` needs a new store subvolume on `sda2`, as `one` got
   `var-lib-docker-leap`, and named volumes cross as tar files (`leap/README.md`).
4. The backup source: snapper's `immich` config and the hourly script, `sudoers-backup`,
   `rsyncd-backup.conf`, `backup-authorized-keys` with its `setpriv`, `backup-age-check`,
   the `backup` user and its state. What `three`'s pull needs unchanged: `zero`'s ssh host
   key (`hosts/three/leap/system/zero-known-hosts`) and its tailnet address.
5. The carry-over gaps in `leap/make-stick` and `leap/firstboot.sh` for `zero`: the LUKS
   key file, Tailscale's state (so the address stays), the `backup` user, `gavin` at 1001
   (`one` is 1000), host keys, `/etc/cloudflared/zero.json`, each deployment's `.env` and
   `~gavin/.<deployment>-secrets`.
6. The Pi 5: the image, the locked boot firmware, health-checker's fallback, and whether
   `sim/microos/run-host.sh` can boot a `zero` the way it boots `one` and `three`.
7. The plays that target `zero` and need a Leap path, and the `MOVED` marker convention.

**Traps already known**, each recorded where it says:

- A Leap first boot with a data disk missing goes to emergency mode despite `nofail`:
  Combustion leaves `/etc/selinux/.autorelabel`, and the relabel generator ignores
  `nofail` (`leap/README.md` § *What the November visit's first boots taught*).
- A data mount names its subvolume by `subvolid=`, never `subvol=`, or health-checker can
  strand the box (`plans/microos-cutover.md`).
- Every `/media` entry needs `context=system_u:object_r:container_file_t:s0`, and home-dir
  binds need `:z` (`decisions.md`, calibre-web's row).
- The first-boot script is not safe to re-run, and the docs overstate its rollback (phase
  12's own prerequisites in the phase table).
- The first `up` of the dev stack would recreate it; that is `one`'s concern now, not
  `zero`'s, but `zero`'s own deployments may have the same recreate puzzle (phase table).

Then the design, in `plans/zero-leap.md`: what `zero` runs that `one` and `three` did not,
the carry-over, the day, and the questions only the owner can answer.

**Delete this note** once both pieces are done or filed, after moving anything durable
into `decisions.md`.
