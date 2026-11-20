# `zero`'s backup: snapper snapshots on `zero`, pulled by rsync to `three`

The owner approved this design on 2026-11-19 (§ The owner's answers, at the end), and it is
**built in the repo** on the branch `backup-pull`: the tracked files on both boxes, the
simulation, and the owner's steps. What is left is on the boxes, in this order, so the plan
stays until they are done:

| Stage | Where | State |
|---|---|---|
| 1. The files on both boxes, the play for zero's restore key, the simulation | repo | **built**, proved by `microos-sim.yml` (`host`, `three`) and `alpine-sim.yml` |
| 2. zero's restore key and host key, committed into three's files | `zero`, then the infra agent | not done |
| 3. three's rename and layout, users, pull key and files | `three` | the pull key made 2026-11-19 and committed into zero's key line; the rest not done: `hosts/three/leap/README.md` § The rename, then § The pull's setup |
| 4. The move on `zero`: one `immich` subvolume, its `.snapshots`, the fstab line, Immich's `.env` | `zero` | not done: `plans/visit-runbook.md` § The move on `zero` |
| 5. zero's packages, backup user and files; the first snapshot | `zero` | the packages (snapper pinned, setpriv, rsync, sudo) and the `backup` user done 2026-11-19; the files and the first snapshot not done: `hosts/zero/system/README.md` § The backup |
| 6. The first pull, then slice 4's checks on the real data | `three`, `zero` | not done: `plans/visit-runbook.md` § Slice 3, step 6, and § Slice 4 |

It replaced the send/receive plan, `three-send-receive.md`, whose transfer the owner dropped
(`docs/decisions.md` § *`zero`'s backup is pulled by rsync from snapshots*); that plan's move
on `zero` now lives in the runbook, and the plan is deleted. Until stage 6, `zero` has no
off-site copy: `mirror-backup` never ran, and is removed. When stage 6 has passed, what
stays true moves to `docs/decisions.md` and the host READMEs, and this file is deleted.

The aim the owner set: dead simple scripts, prebuilt tools where they exist, Python only
where a script would otherwise be complicated. None was needed.

## The idea in one line

`zero` freezes its data in read-only snapper snapshots; `three` copies the newest frozen one
with rsync, as an unprivileged user, then freezes its copy in a snapper snapshot of its own.
Each side owns its own history, neither can delete the other's, and nothing runs as root on
the far side of a connection.

## Data flow

```
 zero (Alpine, snapper 0.13.1, --no-dbus)          three (Leap, snapper, --no-dbus)
 /media/immich: subvolume immich                   /media/backup/immich/
   data/   library upload backups profile            current/  ◄──────────┐ backup-pull, as `backup`,
   data/thumbs, data/encoded-video                     (writable copy)     │ daily 01:00 UTC, 32 Mbit/s,
           (nested subvolumes: left out)               .snapshots/<n>/     │ --fake-super --munge-links
   db/     Postgres                                      snapshot (ro) ◄─┐ │ --inplace --delete
   .snapshots/<N>/                                     ...  daily 14,    │ │ exclude and protect
     info.xml   (written once finished)                     weekly 8,    │ │ /.snapshots
     snapshot   (ro)  ◄── newest finished ── read ──────── monthly 12    │ │
   ... hourly 24, daily 7                          state/pulled  ────────┼─┘
                                                   last-pulled  ◄── backup-snapshot.service,
 media-syncthing: not snapshotted, not pulled            root, only after a good pull
```

- **One `immich` subvolume** holds the library and Postgres's directory, so one snapshot
  freezes both at the same instant. rsync copies a tree that is not changing, so the copy on
  `three` is consistent, and Postgres comes back from it as from a power cut.
- **Nested subvolumes are left out of a snapshot**, so `thumbs` and `encoded-video` never
  leave `zero`; rsync copies their placeholders as empty directories.
- **A snapshot is finished once its `info.xml` exists**: snapper writes it after the btrfs
  snapshot, and deleting the highest snapshot leaves its directory without one. The pull
  takes the highest number with an `info.xml`, and compares number and `info.xml`'s time with
  `last-pulled`, since a recreated config numbers from 1 again.
- **`current/` is an ordinary writable copy** that rsync updates in place, so a changed file
  rewrites only its changed blocks, and three's snapshots share every unchanged one.
- **`three` snapshots only after a good pull.** A cut pull, or rsync's exit 24 (files
  vanished, which a frozen snapshot cannot do), is a failure: no snapshot, no `last-pulled`
  change, and the next day finishes the copy. snapper deleting the snapshot mid-pull does not
  cause it: the simulation deleted one and the pull finished whole, the rsync sender's
  working directory keeping the deleted subvolume readable to the end.
- **snapper keeps its snapshots inside `current/`**, in `.snapshots`, so the pull excludes
  `/.snapshots` and protects it from `--delete` with an rsync filter. The backup user cannot
  enter it (root's, 754), a second guard; it can read the names, which rsync needs, since it
  reads the xattr of every entry in `current/` while deciding what to delete (exit 23 at
  750, the simulation's second run).
- **Syncthing's share is not backed up** (the owner, 2026-11-19): it holds nothing critical.

## Who can do what

```
 three ──ssh as backup, key /home/backup/.ssh/zero-pull──► zero
          restrict, from="100.101.45.78" (three's tailnet address)
          forced: sudo -n /bin/setpriv --reuid=backup ... rsync --server --daemon
                  --config=/etc/rsyncd-backup.conf .   (module `snapshots`, read only)

 zero ──ssh as restore, key /root/.ssh/restore─────────────► three
          restrict, from="100.121.158.58" (zero's tailnet address)
          forced: sudo -n /usr/bin/setpriv --reuid=restore ... rsync --server --daemon
                  --config=/etc/rsyncd-restore.conf .  (module `immich`, read only, fake super)
```

- **Each daemon runs as its own unprivileged user with one capability**,
  `CAP_DAC_READ_SEARCH`: read any file, change none. One sudoers line on each box allows
  exactly the forced command; `setpriv` (util-linux) keeps that capability alone in the
  inheritable and ambient sets and runs the system's own rsync. The simulation reads each
  daemon's `/proc/<pid>/status` mid-transfer: permitted, effective and ambient are `0x4`.
- **A compromised `zero`** can read its own backups on `three`, and serve bad data to the
  pull. It cannot write, delete or run anything on `three`, and `three`'s history from before
  is untouched. The data it serves is parsed by rsync as the unprivileged `backup` user in a
  sandbox that writes only `current/` and `state/`. A symlink it sends never becomes one on
  `three`: under `--fake-super` rsync keeps it as a plain file holding its target, munged
  besides, so none can steer the restore daemon, which reads anything, out of its module.
  The restore module turns them back into links on the way out.
- **A compromised `three`** can read `zero`'s snapshots, the data it exists to hold. It
  cannot write to `zero`, delete a snapshot, or run anything.
- **Both daemons refuse `--copy-links` and its kin**, so neither follows a symlink for the
  client. A path in the request that runs through a symlink already in the module is the
  one way out of a module without chroot; on `three` none exists, and on
  `zero` neither Immich nor Postgres keeps any.
- **The backup user could rename `current/.snapshots`**, since it owns `current/`: it could
  hide the history from snapper, never change or delete it. Snapshots are root's and
  read-only, deleting a subvolume needs root, and a rename cannot leave the subvolume.

This turns the one key the fleet allowed between boxes into two read-only ones (the owner,
2026-11-19).

## The pieces

| Where | File | What it is |
|---|---|---|
| `zero` | `snapper-config-immich` → `/etc/snapper/configs/immich` | hourly 24, daily 7, number cleanup for the owner's own (10), root alone, no qgroups, `BACKGROUND_COMPARISON="no"` |
| `zero` | `snapper-sysconfig` → `/etc/snapper/snapper` | `SNAPPER_CONFIGS=""`, so the package's D-Bus hourly script does nothing |
| `zero` | `snapper-immich` → `/etc/periodic/hourly/` | under `flock`: create a timeline snapshot, clean up timeline and number, `--no-dbus`, log to syslog |
| `zero` | `sudoers-backup`, `rsyncd-backup.conf`, `backup-authorized-keys` | the `backup` user's one command, its read-only module over `/media/immich/.snapshots`, and three's key line |
| `zero` | `fstab` | `autodefrag` gone from every array line |
| `three` | `backup-pull` → `/usr/local/bin/` | about 40 lines of POSIX shell: list, pick, compare, rsync, record |
| `three` | `backup-pull.service`, `.timer` | as `backup`, sandboxed, `ConditionPathIsMountPoint=`, `OnSuccess=backup-snapshot.service`; daily `01:00:00 UTC`, 10 minutes' jitter, `Persistent=` |
| `three` | `backup-snapshot.service` | as root: snapper create, cleanup timeline, write `last-pulled` |
| `three` | `snapper-config-received-immich` | `TIMELINE_CREATE="no"`, daily 14, weekly 8, monthly 12, no quarterly or yearly |
| `three` | `backup-ssh-config`, `zero-known-hosts` | zero by address, its one pinned host key; both root's |
| `three` | `sudoers-restore`, `rsyncd-restore.conf`, `restore-authorized-keys` | the `restore` user's one command, its read-only module `immich` over `/media/backup/immich` alone, zero's key line |
| control node | `server-create-restore-key.yml` | makes zero's restore key, prints it, zero's address and zero's host key |

Removed: `zero`'s `mirror-backup`; `three`'s `rsync-backup.conf`, `backup-authorized-keys`,
`mirror-snapshot` and `mirror-snapshot.timer`, and `mirror-snapshot.service`, whose job
`backup-snapshot.service` does. Kept and marked not used:
`backup-age-check` and `server-store-backup-ntfy-url.yml`, until the fleet-wide dead
man's switch is designed.

## How the simulation proves it

`microos-sim.yml`'s `host` job, `three`: the real first boot, `make-backup`, the README's
unlock, then the runner stands in for `zero`: an Alpine container of zero's release with
snapper from edge/testing, util-linux's `setpriv`, Alpine's sudo and rsync, zero's tracked
files at their paths, and its own sshd; a loop btrfs laid out as after the move; a Postgres
writing throughout. `alpine-sim.yml` runs zero's snapper install on arm64 with the pinned
SHA-256, and `install-system-file`'s new `visudo` check. `sim/microos/README.md` lists each
check and how it proves its point.

## Changes at the move, not before

`/media/immich-data` and `/media/immich-db` become `/media/immich/data` and
`/media/immich/db` only at the move. Until then these describe the fleet as it is, and are
left alone: `CLAUDE.md` § Shell traps, `docs/recovery.md`, `deployments/immich/.env.example`,
`.gitignore`'s comment, the Immich deploy hook's comment, `bin/check-mount-guards`' comments,
and `plans/visit-runbook.md` § Slice 2's check. The move's commit changes them, with the fstab
line; `docs/fleet-inventory.md` regenerates.

## The owner's answers, 2026-11-19

1. **The design, and the keys: approved.** `three` reads from `zero` and `zero` reads from
   `three`, both read-only; neither holds a key that can write to the other.
2. **Snapshot names:** snapper's numbers, since snapper replaced btrbk (below).
3. **The alert: deferred.** The owner wants a dead man's switch across the whole fleet, as
   a mesh, from a prebuilt tool, designed separately later. Until then nothing alerts
   when the pull stops; the gap is filed in the phase table.
4. **Polling** about every 15 minutes: superseded by the daily pull below.
5. **`zero`'s retention:** hourly for a day, daily for 7 days.
6. **`zero`'s daemon** as `backup` with only `CAP_DAC_READ_SEARCH`: agreed.
7. **`three`'s retention:** daily 14, weekly 8, monthly 12, no quarterly or yearly step.
8. **`zero`'s read-only access to its own backups:** agreed (decision 1).

**snapper, not btrbk, on both boxes** (the owner, after an investigation of snapper on
Alpine). `zero` ends on openSUSE, where snapper is native, so its configuration carries over
unchanged when `zero` moves.

- **On `zero`:** snapper from Alpine's edge/testing (`snapper-0.13.1-r0`), installed once
  from a signature-checked file and pinned in apk's world, so it gets no updates until
  `zero` moves to Leap; revisit at Alpine 3.25. Run with `--no-dbus`. An hourly periodic
  script, under `flock`, makes a timeline snapshot and runs timeline and number cleanup.
  `.snapshots` is made by hand at the move, root's, mode 750. `/mnt/ext` stays `noauto`.
- **The pull: daily at 01:00, rate-limited to 32 Mbit/s**, the newest finished snapshot,
  excluding `/.snapshots`; rsync's exit 24 is a failure.
- **On `three`:** Leap's own snapper, `TIMELINE_CREATE="no"`, the snapshot made by the
  service a good pull starts.
- **`autodefrag` is dropped**: it breaks the sharing between snapshots and their data and
  suits databases badly. A timed manual defrag is to be looked at later, issue #23, which
  notes that a defrag unshares snapshot extents too.

## Work in progress, 2026-11-20: the rename of three's array

The owner asked on 2026-11-19 for "mirror" to go wherever it means the backup, three's live
array included, and for the immich backup to sit at `/media/backup/immich/` with no
`received-backups` level. Built on the branch `backup-rename`, from `backup-pull`:

- **Done, in the repo:** every name (`docs/decisions.md` § *The backup's names and layout on
  `three`*); the layout in `make-backup` and every unit; the restore module `immich` over
  `/media/backup/immich` alone; `zero`'s `backup-age-check` and `/var/lib/backup-alert`, with
  the move of the stored URL in `hosts/zero/system/README.md` § The backup; the rename's
  procedure, `hosts/three/leap/README.md` § The rename, eighteen owner-run fish blocks with a
  way back at each; and its simulation, `microos-sim.yml`'s second `three` job
  (`SIM_VARIANT=migrate`).
- **Not done:** the CI runs on the branch's head; the Fable review; on the boxes, all of it.
- **PR #22** (the array as a play), for its change list: `lb_layout` accepts only top-level
  names (`^[A-Za-z0-9._-]+$`); the new layout needs nested entries (`immich`,
  `immich/current`, `immich/current/.snapshots`, `immich/state`), so the play must make
  parents first and refuse `..`; its labels become `backup-luks` and `backup`.
  `make-backup` is deleted when PR #22 merges.
