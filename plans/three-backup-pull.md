# `zero`'s backup: btrfs snapshots on `zero`, pulled by rsync to `three`

A design of 2026-11-19 for the owner to review before anything is built. It replaces
[`three-send-receive.md`](three-send-receive.md), whose transfer the owner dropped the same
day (`docs/decisions.md` § *`zero`'s backup is pulled by rsync from snapshots*), and keeps
that plan's layout on `zero`. Until it is built, `zero` has no off-site copy:
`mirror-backup` was removed from `zero` on 2026-11-18.

The aim the owner set: dead simple scripts, prebuilt tools where they exist, Python only
where a script would otherwise be complicated.

## The idea in one line

`zero` freezes its data in read-only snapshots; `three` copies the newest frozen snapshot
with rsync, as an unprivileged user, then freezes its copy in a snapshot of its own.

Each side owns its own history. Neither can delete the other's. Nothing runs as root on
the far side of the connection.

## Data flow

```
 zero (Alpine, critical)                          three (Leap, abroad)
 btrfs RAID1 array, top level at /mnt/ext         LUKS array, mounted at /media/mirror

 subvolume immich ───────────┐                    received-backups/
   data/   library upload    │ 04:00 btrbk        ├── immich/
           backups profile   │ snapshot, ro       │   ├── current/   ◄─────┐ rsync, as `backup`
   data/thumbs        (nested│ subvol: left out)  │   │   (plain copy,    │ --fake-super:
   data/encoded-video (nested│ subvol: left out)  │   │    writable)      │ owners in xattrs
   db/     Postgres          │                    │   ├── immich.<ts>  ◄─┤ btrbk, after
                             ▼                    │   ├── immich.<ts>    │ snapshot, ro,
 snapshots/immich/                                │   └── …  a ladder    │ after a good pull
   immich.<ts>   (ro) ◄── newest ── pulled ───────┼──────────────────────┘
   immich.<ts>   (ro)       over ssh, read-only   │
   …  last 7                                      │
                                                  │
 subvolume media-syncthing                        │
   not snapshotted, not pulled:                   └── (syncthing-three's own subvolume,
   nothing critical (owner, 2026-11-19)                separate, never pulled into)
```

Why each part is shaped this way:

- **One `immich` subvolume** holds both the library and Postgres's directory, so one
  snapshot freezes both at the same instant. rsync then copies a tree that is not
  changing, so the copy on `three` is consistent: the database and the photos agree.
  Postgres comes back from it as from a power cut.
- **Nested subvolumes are left out of a snapshot**, so `thumbs` and `encoded-video`
  never leave `zero`. In the snapshot they are empty directories, and rsync copies them as
  empty directories.
- **Syncthing's share is not backed up** (the owner, 2026-11-19): it holds nothing
  critical. So `media-syncthing` is neither snapshotted nor pulled, and the send/receive
  plan's step for its `config` subvolume is dropped from the move.
- **`current/` is an ordinary writable copy** that rsync updates in place (`--inplace`),
  so a changed file rewrites only its changed blocks. The read-only snapshots beside it are
  the history. btrfs shares every unchanged block between them by itself, so each snapshot
  costs only what changed since the one before; a photo kept in 30 snapshots is stored
  once.
- **`three` snapshots only after a good pull**, so no snapshot holds half a run, and the
  snapshot is named for the time `three` took it.

## Who can do what

```
 three ──ssh, key in three's backup user──► zero
          forced command: rsync's daemon, read-only module `snapshots`,
          run as user `mirror` with one extra capability: read any file
          from="<three's tailnet address>", restrict

 zero ──ssh, key /root/.ssh/restore────────► three
          forced command: rsync's daemon, read-only module `backups` over
          received-backups, `fake super` on so it sends real owners and modes,
          run as user `restore` with the one read-any-file capability
          from="<zero's tailnet address>", restrict
```

- **A compromised `zero`** can only read its own backups on `three`; it cannot write,
  delete or run anything there. The worst it can do is stop taking snapshots or serve bad
  data; `three`'s history from before then is untouched, because only `three`'s root makes
  or deletes those snapshots.
- **Restores need nothing set up on the day** (the owner, 2026-11-19): `zero` holds a
  read-only key to its own backups. A restore onto `zero`, as root, is
  `rsync -aHAX --numeric-ids restore@three::backups/immich/<snapshot>/ <target>/`, and the
  module's `fake super` turns the kept owners and modes back into real ones.
- **A compromised `three`** can read what the module serves, which is `zero`'s own backup
  data, the thing `three` exists to hold. It cannot write to `zero`, delete a snapshot, or
  run anything. The rsync daemon on `zero` runs as an unprivileged user with
  `CAP_DAC_READ_SEARCH` (read any file, nothing else), not as root, so even a bug in
  rsync's server, fed by a hostile client, has nothing to write with. Reading Postgres's
  files (mode 700, Postgres's own user) and the library needs that one capability. The
  forced command gets it through one sudoers line that allows exactly
  `setpriv --reuid=mirror --regid=mirror --init-groups --inh-caps=+dac_read_search
  --ambient-caps=+dac_read_search rsync --server --daemon --config=/etc/rsyncd-mirror.conf .`:
  root for the instant `setpriv` needs, then the system's own rsync, so a security update
  to rsync applies at once. The simpler alternative, the read-only daemon run as root, is
  open question 6.
- **On `three`**, rsync runs as the unprivileged `backup` user, so a hostile `zero`'s data
  is parsed without privilege. Owners and modes are kept in an xattr (`--fake-super`), as
  in the original rsync design.

This turns the one key the fleet allows between boxes into two read-only ones. Today's
rule is that no box holds a key to another, with `zero`'s backup key to `three` as the
agreed exception. Here `three` holds a read-only key to `zero`'s snapshots and `zero` a
read-only key to its own backups; neither can write to the other. The owner said on
2026-11-19 that the rule is theirs to relax; this needs their word.

## The pieces, and how much of each we own

| Where | Piece | What it is | Ours to maintain |
|---|---|---|---|
| `zero` | **btrbk**, snapshot-only | prebuilt; takes and prunes `zero`'s snapshots from a config file | a config of about 10 lines |
| `zero` | its 04:00 trigger | a periodic script that runs `btrbk run` in the 04 hour | about 5 lines of shell |
| `zero` | `mirror` user and key line | forced command in `authorized_keys` | 1 line |
| `zero` | a sudoers line | lets `mirror` start exactly one command: `setpriv`, which keeps only `CAP_DAC_READ_SEARCH` and runs rsync's daemon as `mirror` | 1 line |
| `zero` | `rsyncd-mirror.conf` | rsync's own daemon config: one read-only module | about 10 lines |
| `zero` | `mirror-backup-age-check` | kept or replaced, see the alert below | about 30 lines today |
| `three` | `mirror-pull` | picks the newest snapshot of each name and runs rsync | about 30 lines of shell |
| `three` | `mirror-pull.service` and `.timer` | systemd runs it as `backup` about every 15 minutes with a few minutes' jitter, only while the array is mounted; it never starts a second run while one is still pulling | two small units |
| `three` | **btrbk**, snapshot-only | prebuilt; snapshots `current/` after a good pull and prunes to the retention ladder | a config of about 10 lines |
| `three` | `mirror-snapshot.service` | systemd runs btrbk as root, started only by a successful pull (`OnSuccess=`) | one small unit |
| `three` | `restore` user, key line, sudoers line, `rsyncd-restore.conf` | `zero`'s read-only module over its own backups | about 12 lines |

No Python is needed: the only script with logic, `mirror-pull`, is a loop of three steps.
Everything with real logic (retention, snapshot naming, deciding what to prune) is btrbk's,
a maintained tool used widely for exactly this. Both Alpine and openSUSE package it; the
simulation's package check confirms both before the build relies on them.

### `mirror-pull` on `three`, in outline

```
for name in immich:          # one series today; the loop keeps a second cheap
    newest = rsync --list-only mirror@zero::snapshots/<name>/  | the last name, sorted
    if newest is the name in last-pulled-<name>: nothing new, next name
    rsync -aHAX --numeric-ids --fake-super --delete --inplace
          --timeout=900 -e "ssh <pinned options>"
          mirror@zero::snapshots/<name>/<newest>/  /media/mirror/received-backups/<name>/current/
    exit 24 (files vanished) counts as success; anything else stops the run
    write newest to last-pulled-<name> once three's snapshot of it is taken
```

`set -eu`, no pipelines whose status matters, no parsing beyond picking the last name of
a sorted list (btrbk's names sort by time) and comparing it with one remembered name. Most
runs find nothing new and end after one listing. The alert below notices when nothing new
arrives for days.

### btrbk's two configs, in outline

```
# zero: /etc/btrbk/btrbk.conf                     # three: /etc/btrbk/mirror.conf
timestamp_format         long                     timestamp_format         long
snapshot_preserve_min    2d                       snapshot_preserve_min    latest
snapshot_preserve        7d                       snapshot_preserve        14d 8w 12m
volume /mnt/ext                                   volume /media/mirror/received-backups
  snapshot_dir snapshots/immich                     subvolume immich/current
  subvolume immich                                    snapshot_dir    immich
                                                      snapshot_name   immich
```

btrbk prunes by the snapshot's own timestamp, on the clock of the box running it; on
`three` that is `three`'s clock, and only `three` writes those names.

## Alerting when the backup stops

The old age check ran on `zero` and read a marker `zero`'s own push wrote. With a pull,
`zero` no longer knows whether a pull succeeded. Two ways:

1. **A dead man's switch** (recommended): after each good snapshot, `three` pings a
   check URL; if no ping arrives for three days, the service alerts through ntfy. Healthchecks.io
   does this on its free tier and integrates with ntfy; it is a prebuilt service, and it
   also catches `three` being off entirely, which nothing on `three` can report. The
   check's URL is a secret kept on `three`, like the ntfy URL on `zero` today.
2. **`zero` reads its own daemon's log**: the rsync daemon logs each transfer, and
   `mirror-backup-age-check` alerts when the last completed one is too old. No outside
   service, but about 30 lines we keep, and parsing a log.

## What changes on each box

**`zero`:**
- The move from the send/receive plan, unchanged: `immich` as one subvolume, the nested
  subvolumes, the new mountpoint and its guard, the fstab line, Immich's `.env`.
- `/mnt/ext`, the array's top level, mounted at boot (today `noauto`), since btrbk works
  from it. It holds nothing new; its mode stays root-only.
- Packages: `btrbk`, and `setpriv` for the capability; `sudo` is there already.
- New: the btrbk config and trigger, the `mirror` user, its key line, `rsyncd-mirror.conf`.
- Removed: the rsync push in `mirror-backup` (the file goes), the push key
  `/root/.ssh/mirror-backup` (deleted once the pull works).

**`three`:**
- Layout: `received-backups/immich/current` as a subvolume owned by `backup` (rsync writes
  there), `received-backups` itself root's and mode 755 so `backup` can reach it; snapshots
  root's and read-only.
- Package: `btrbk`.
- New: `mirror-pull` with its service and timer, btrbk's config, `mirror-snapshot.service`
  (replacing today's snapshot script and timer), the private key for `backup` (made on
  `three`, its public half committed into `zero`'s key line), `zero`'s pinned host key.
- Removed: the rsync daemon config and the push key line (`rsync-backup.conf`,
  `backup-authorized-keys`), `mirror-snapshot` and its timer.

## How the simulation proves it

The `host` job's `three` run keeps a runner in `zero`'s place, laid out as `zero` will be,
with a small Postgres writing during the snapshot, and the runner's real btrbk and rsync
daemon serving it. It checks:

1. A first pull copies the newest snapshot; owners, modes and contents match by a hash of
   the tree, read back through `--fake-super`. `thumbs` and `encoded-video` are empty directories.
2. `three` takes a snapshot only after the pull succeeded; a pull cut off halfway leaves
   `current/` as it was and no new snapshot.
3. A second night pulls only what changed.
4. Least privilege: `three`'s key runs nothing but the read-only module; an upload, a
   delete and a path outside the module are refused; the daemon on the runner has the one
   capability and no other.
5. A locked array: the pull is skipped and the next night succeeds.
6. Pruning: with retention set to 0 days, btrbk keeps the newest on both sides.
7. A restore: a copy of a snapshot's `db` starts in a throwaway Postgres on `three` and
   returns the rows written before the snapshot.

## Slice 4, on the real boxes, once

As in the send/receive plan: the library's tree hash matches between `zero`'s snapshot and
`three`'s copy of it; a copy of the received `db` starts in a throwaway Postgres; then a
lock and an unlock. Repeated only after a change to the backup path.

## What carries over from today's work

The send/receive branch (`send-receive`) is not merged. From it this design keeps the
layout on `zero`, the move procedure, the snapshot naming per subvolume, `received-backups`
as the place on `three`, the simulation's runner-as-`zero` and its Postgres restore check,
and the `nosuid,nodev` mount options. Its `mirror-receive`, sudoers file and send script are
not needed. Draft PR #22's array play is updated to this layout.

## The owner's answers, 2026-11-19

1. **The design, and the keys: approved.** `three` reads from `zero` and `zero` reads from
   `three`, both read-only; neither holds a key that can write to the other.
2. **Snapshot names:** btrbk's format is acceptable if btrbk is used. Whether snapper
   replaces btrbk is open (below).
3. **The alert: deferred.** The owner wants a dead man's switch across the whole fleet, as
   a mesh, from a prebuilt tool, designed separately later. Until then nothing alerts
   when the pull stops; the gap is filed in the phase table.
4. **Polling** about every 15 minutes with jitter: agreed.
5. **`zero`'s retention**, 7 days and at least 2: agreed.
6. **`zero`'s daemon** as `mirror` with only `CAP_DAC_READ_SEARCH`: agreed.
7. **`three`'s retention:** no yearly step. Daily for 14 days, weekly for 8 weeks,
   monthly for 12 months (btrbk `14d 8w 12m`), or snapper's equivalent with its quarterly
   step if snapper is chosen.
8. **`zero`'s read-only access to its own backups:** agreed (decision 1).

**snapper, not btrbk, on both boxes** (the owner, 2026-11-19, after an investigation of
snapper on Alpine). `zero` ends on openSUSE, where snapper is native, so its configuration
carries over unchanged when `zero` moves instead of being rebuilt. These answers supersede
the btrbk parts of this plan above; the build rewrites them.

- **On `zero`:** snapper from Alpine's edge/testing (`snapper-0.13.1-r0`, the only Alpine
  package of it), installed once from a signature-checked file and pinned in apk's world, so
  it gets no updates until `zero` moves to Leap; revisit at Alpine 3.25, where a library
  change could break it. Run with `--no-dbus`: no D-Bus, no daemon, nothing on the boot
  path. An hourly periodic script, under `flock`, makes a timeline snapshot and runs
  timeline and number cleanup. Config `/etc/snapper/configs/immich`: hourly for 24 hours,
  daily for 7 days; `SNAPPER_CONFIGS=""` in `/etc/snapper/snapper`, so the package's own
  hourly script, which needs D-Bus, does nothing. `.snapshots` is made by hand, root's,
  mode 750. Snapshots live at `/media/immich/.snapshots/<N>/snapshot`; `/mnt/ext` stays
  `noauto`.
- **The pull: daily at 01:00, rate-limited to 32 Mbit/s** (the owner), not the 15-minute
  polling first agreed. `three` pulls the newest finished snapshot (the highest `<N>` with
  an `info.xml`), records N with `info.xml`'s time, and excludes `/.snapshots`. rsync's
  exit 24 (files vanished) is a failure: a frozen snapshot cannot lose files, so it means
  the snapshot was deleted mid-pull.
- **On `three`:** Leap's own snapper, `TIMELINE_CREATE="no"`, the snapshot made by the
  service a good pull starts. Retention daily 14, weekly 8, monthly 12, no quarterly or
  yearly step (the 12 monthlies cover a year).
- **`autodefrag` is dropped** from the `/media/immich` fstab line: it breaks the sharing
  between snapshots and their data and suits databases badly. A timed manual defrag is to
  be looked at later, issue #23, which notes that a defrag unshares snapshot extents too.
