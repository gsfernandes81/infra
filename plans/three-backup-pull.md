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
   db/     Postgres          │                    │   ├── immich.<ts>  ◄─┤ 05:00+ btrbk
                             ▼                    │   ├── immich.<ts>    │ snapshot, ro,
 snapshots/immich/                                │   └── …  90 days     │ after a good pull
   immich.<ts>   (ro) ◄── newest ── pulled ───────┼──────────────────────┘
   immich.<ts>   (ro)       over ssh, read-only   │
   …  last 7                                      │
                                                  │
 subvolume media-syncthing ──┐                    ├── syncthing/
   (share)                   │ 04:00              │   ├── current/   ◄─────┐
   config/   (nested subvol: │ left out)          │   ├── syncthing.<ts> ◄─┤ snapshot after
                             ▼                    │   └── …  90 days     │ a good pull
 snapshots/syncthing/                             │                      │
   syncthing.<ts> (ro) ◄── newest ── pulled ──────┼──────────────────────┘
   …  last 7                                      │
                                                  └── (syncthing-three's own subvolume,
                                                       separate, never pulled into)
```

Why each part is shaped this way:

- **One `immich` subvolume** holds both the library and Postgres's directory, so one
  snapshot freezes both at the same instant. rsync then copies a tree that is not
  changing, so the copy on `three` is consistent: the database and the photos agree.
  Postgres comes back from it as from a power cut.
- **Nested subvolumes are left out of a snapshot**, so `thumbs`, `encoded-video` and
  Syncthing's `config` (which holds `zero`'s device key) never leave `zero`. In the
  snapshot they are empty directories, and rsync copies them as empty directories.
- **`current/` is an ordinary writable copy** that rsync updates in place each night.
  `--delay-updates` keeps it whole until the end of a run. The read-only snapshots beside
  it are the history.
- **`three` snapshots only after a good pull**, so no snapshot holds half a run, and the
  snapshot is named for the time `three` took it.

## Who can do what

```
 three ──ssh, key in three's backup user──► zero
          forced command: rsync's daemon, read-only module `snapshots`,
          run as user `mirror` with one extra capability: read any file
          from="<three's tailnet address>", restrict

 zero ──────────────────────────────────────► three
          nothing: zero holds no key to three
```

- **A compromised `zero`** cannot reach `three` at all. The worst it can do is stop taking
  snapshots or serve bad data; `three`'s history from before then is untouched, because
  only `three`'s root makes or deletes those snapshots.
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

This reverses the direction of the one key the fleet allows between boxes. Today's rule is
that no box holds a key to another, with `zero`'s backup key to `three` as the agreed
exception. Here the exception is `three`'s read-only key to `zero` instead. The owner said
on 2026-11-19 that the rule is theirs to relax; this needs their word.

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
| `three` | `mirror-pull.service` and `.timer` | systemd runs it as `backup`, at 05:00, only while the array is mounted | two small units |
| `three` | **btrbk**, snapshot-only | prebuilt; snapshots `current/` after a good pull and prunes to 90 days | a config of about 10 lines |
| `three` | `mirror-snapshot.service` | systemd runs btrbk as root, started only by a successful pull (`OnSuccess=`) | one small unit |

No Python is needed: the only script with logic, `mirror-pull`, is a loop of three steps.
Everything with real logic (retention, snapshot naming, deciding what to prune) is btrbk's,
a maintained tool used widely for exactly this. Both Alpine and openSUSE package it; the
simulation's package check confirms both before the build relies on them.

### `mirror-pull` on `three`, in outline

```
for name in immich syncthing:
    newest = rsync --list-only mirror@zero::snapshots/<name>/  | the last name, sorted
    rsync -aHAX --numeric-ids --fake-super --delete --delete-delay --delay-updates
          --timeout=900 -e "ssh <pinned options>"
          mirror@zero::snapshots/<name>/<newest>/  /media/mirror/received-backups/<name>/current/
    exit 24 (files vanished) counts as success; anything else stops the run
write which snapshot was pulled, for the log
```

`set -eu`, no pipelines whose status matters, no parsing beyond picking the last name of
a sorted list (btrbk's names sort by time). If `newest` is the same as last night's, the
pull still runs and finds nothing to copy; a check below notices when that goes on.

### btrbk's two configs, in outline

```
# zero: /etc/btrbk/btrbk.conf                     # three: /etc/btrbk/mirror.conf
timestamp_format         long                     timestamp_format         long
snapshot_preserve_min    2d                       snapshot_preserve_min    latest
snapshot_preserve        7d                       snapshot_preserve        90d
volume /mnt/ext                                   volume /media/mirror/received-backups
  snapshot_dir snapshots/immich                     subvolume immich/current
  subvolume immich                                    snapshot_dir    immich
  snapshot_dir snapshots/syncthing                    snapshot_name   immich
  subvolume media-syncthing                         subvolume syncthing/current
    snapshot_name syncthing                           snapshot_dir    syncthing
                                                      snapshot_name   syncthing
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
- Layout: `received-backups/immich/current` and `received-backups/syncthing/current` as
  subvolumes owned by `backup` (rsync writes there), `received-backups` itself root's and
  mode 755 so `backup` can reach them; snapshots root's and read-only.
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
   the tree, read back through `--fake-super`. `thumbs` and `config` are empty directories.
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

## For the owner to decide

1. **The design as a whole**, and the reversed key: `three` holds a read-only key to `zero`.
2. **btrbk's snapshot names.** btrbk names snapshots `immich.20261120T0400` (its "long"
   format; there is also `immich.20261120T040000+0000`). The owner asked for
   `immich-2026-11-20T0400Z`. Taking btrbk's format means no snapshot script to own;
   keeping the owner's format means a snapshot-and-prune script of about 40 lines on each
   side instead of btrbk. Recommended: btrbk's format.
3. **The alert**: the dead man's switch (recommended), or `zero` reading its daemon log.
4. **The pull time**: 05:00, an hour after `zero`'s 04:00 snapshot. Recommended.
5. **`zero`'s retention**: 7 days, at least 2. Recommended; a long seed over the tailnet
   that takes more than a day still finds its snapshot.
6. **How `zero`'s read-only daemon reads everything**: as `mirror` with only
   `CAP_DAC_READ_SEARCH`, through one sudoers line and `setpriv` (recommended), or as root
   with the module read-only (simpler, one line fewer, but a bug in rsync's server would
   then run as root on the critical box).
