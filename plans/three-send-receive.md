# `zero`'s backup to `three` by btrfs send/receive

A proposal of 2026-11-19, for the owner to approve before anything is built. It replaces
the rsync push in [`three.md`](three.md) § Backups. `mirror-backup` and
`mirror-backup-age-check` were removed from `zero` on 2026-11-18 to wait for it, so `zero`
has no off-site copy until the first send below. Draft PR #22 (`three-array-play`, the
array as a play) is parked until this layout is settled. When the owner approves it and it
is built, its reasoning moves to [`docs/decisions.md`](../docs/decisions.md), the rsync
rows there are marked superseded, and this file is deleted.

## Why

rsync copies a live tree file by file. Immich's library and its Postgres directory then
reach `three` at different moments, which Immich's backup docs warn leaves the database
and the files out of step, and the live Postgres directory cannot be copied at all, so the
rsync design carried the nightly dump instead. Snapshots on `three` after an rsync push
give history, but the edge cases sit at the join: staged half-files (`.~tmp~`), a
snapshot timer that must skip a running push, owners kept in an xattr because the receiver
is not root. In the owner's words, rsync after snapshots "balks at the last 100 metres".

A read-only snapshot on `zero` is one instant. `btrfs send` carries it whole, and each
night's send after the first carries only what changed since the last one.

## What is decided

The owner's calls, with the reasons given.

- **Send/receive, not rsync.** Snapshots and copy-on-write end to end, and Postgres and
  the library consistent with each other.
- **On `zero`, `immich-data` and `immich-db` merge into one subvolume, `immich`,** with
  directories `data` and `db`. btrfs snapshots one subvolume at a time, so two subvolumes
  are never captured at the same instant; one is. Immich's `.env` points at the new paths,
  with no bind mounts: a path change is one reviewed `.env` edit, a bind mount is a
  boot-path fstab line. The move uses `cp -a --reflink=always` on the same filesystem,
  which takes seconds and no extra space, with Immich stopped. The old subvolumes are kept
  until the move is verified, then deleted.
- **What stays out becomes a nested subvolume**, which a snapshot of its parent leaves out:
  Immich's `thumbs` and `encoded-video`, which Immich regenerates, and Syncthing's
  `config`, which holds `zero`'s device key and must not go abroad.
- **Receive on `three` runs as root, confined.** `btrfs receive` creates subvolumes and
  sets owners, which only root can do. The key keeps `restrict` and
  `from="100.121.158.58"`, `zero`'s tailnet address, with a forced command that runs one
  reviewed script through sudo. The script runs `btrfs receive --chroot` into `incoming`
  and nothing else. A half-received subvolume left by an interrupted stream (writable, no
  received UUID) is deleted before the next receive.
- **Send stream protocol 1, the default**, because `zero` runs Alpine and `three` Leap, on
  different kernels and btrfs-progs. Re-checked when `zero` moves to Leap.
- **The parent rule:** the newest snapshot that reached `three` survives on both sides
  until the next send succeeds. `zero` keeps its last one or two per subvolume and prunes
  only after a success. `three` keeps about 90 days and never prunes its newest. The 90
  days stay open to adjustment.
- **What goes:** the rsync daemon config, the rsync parts of `mirror-backup`, and `three`'s
  own snapshot timer; the received snapshots are the history. `mirror-backup-age-check`
  stays, reading the new success marker. The tracked rsync files leave the repo when the
  new path lands.
- **The first full send** goes over the LAN if it is ready before `three` flies to
  Singapore on 21 November 2026, but not rushed for it; otherwise over the tailnet later,
  rate-limited. Building it solid comes before the date.
- **Slice 4 becomes a one-time real check** (below), repeated only after a change to the
  backup path.
- **Work on `zero` is accepted**, with Immich and Syncthing stopped for the move.

## The layout on `zero`, and the move

| On the array (top level) | What | In the subvolume's snapshot |
|---|---|---|
| `immich`, mounted at `/media/immich` | new subvolume | |
| `immich/data/` | `UPLOAD_LOCATION`: `library`, `upload`, `backups`, `profile` | yes |
| `immich/data/thumbs/`, `immich/data/encoded-video/` | nested subvolumes | no: empty directories |
| `immich/db/` | `DB_DATA_LOCATION`, mode 700, Postgres's uid | yes |
| `media-syncthing` (278), at `/media/syncthing` | unchanged | |
| `media-syncthing/config/` | nested subvolume | no: an empty directory |
| `snapshots/immich/`, `snapshots/syncthing/` | `zero`'s read-only snapshots | (open question 1) |

Syncthing's compose file names `/media/syncthing` directly and does not change. The array's
top level is reached through the existing `noauto` fstab entry `/mnt/ext`. Subvolume names
are from [`docs/fleet-inventory.md`](../docs/fleet-inventory.md); step 1 confirms them.

The move, as a proposal; the runbook gets the final blocks. Every step after `ssh zero`.

**Before:**

- A database dump off the array, by hand, as
  [`docs/recovery.md`](../docs/recovery.md) § Immich's database says.
- The asset count from Immich's web UI (Administration, Server stats), written down.
- `cp --version` reads GNU coreutils. The move needs GNU `cp` for `--reflink=always` and
  for `-a`'s ACLs and xattrs (fstab mounts with `acl`). If it reads BusyBox, `sudo apk add
  coreutils` first.
- A quiet hour. Phones queue uploads and Syncthing changes while both are stopped.

**Steps:**

1. **Read the subvolumes.** `sudo mount /mnt/ext; and sudo btrfs subvolume list /mnt/ext`
   lists `media-syncthing` 278, `media-immich-db` 279, `media-immich-data` 280.
2. **Stop both.** `sudo docker compose stop` in `~/infra/hosts/zero/immich`, then in
   `~/infra/hosts/zero/syncthing`. `sudo docker ps` lists none of their containers.
3. **Make `immich`.** `sudo btrfs subvolume create /mnt/ext/immich`, then
   `sudo cp -a --reflink=always /mnt/ext/media-immich-db /mnt/ext/immich/db`, which makes
   `db` with the old root's owner and mode. Then `sudo mkdir /mnt/ext/immich/data`, `sudo
   btrfs subvolume create` for `/mnt/ext/immich/data/thumbs` and
   `/mnt/ext/immich/data/encoded-video`, and `sudo cp -a --reflink=always
   /mnt/ext/media-immich-data/. /mnt/ext/immich/data/`, which fills the two nested
   subvolumes and gives `data` the old root's owner and mode. `--reflink=always` fails
   rather than fall back to a full copy.
4. **Syncthing's config.** `sudo mv /mnt/ext/media-syncthing/config
   /mnt/ext/media-syncthing/config.old`, `sudo btrfs subvolume create
   /mnt/ext/media-syncthing/config`, and `sudo cp -a --reflink=always
   /mnt/ext/media-syncthing/config.old/. /mnt/ext/media-syncthing/config/`.
5. **Prove the copies.** Each of these prints nothing:
   `sudo rsync -aHAXn -i --delete /mnt/ext/media-immich-data/ /mnt/ext/immich/data/`,
   the same for `media-immich-db/` against `immich/db/`, and for `config.old/` against
   `config/`. A dry run compares names, sizes, times, owners, modes, ACLs and xattrs, and
   writes nothing. Never with `-x`, which would skip the nested subvolumes as other
   filesystems. Then `sudo btrfs subvolume list /mnt/ext` shows the four new subvolumes;
   send `immich`'s id to the infra agent.
6. **The new mountpoint, guarded.** `sudo mkdir /media/immich; and sudo chattr +i
   /media/immich`, then `sudo touch /media/immich/x` must fail with "Operation not
   permitted".
7. **fstab.** The infra agent commits `hosts/zero/system/fstab` with one `/media/immich`
   line, `subvolid=<id>` and the old lines' options, in place of the two Immich lines. On
   `zero`: `git pull`, `sudo bin/install-system-file fstab` (the dry run must show only
   that), then with `--commit --allow-content-change`. Then `sudo umount /media/immich-data
   /media/immich-db; and sudo mount /media/immich`.
8. **`.env`.** In `~/infra/hosts/zero/immich/.env`: `UPLOAD_LOCATION=/media/immich/data`
   and `DB_DATA_LOCATION=/media/immich/db`. The infra agent changes `.env.example` to match.
9. **Start.** Immich's bind mounts change, so its containers are recreated, by the redeploy
   play from the phone: `server-deploy-compose.yml -e deployment=immich -e
   immich_dump=false -K` (the dump was taken before; the hook cannot dump a stopped
   database). Syncthing's compose file is unchanged, so `sudo docker compose start` in its
   deployment. `sudo umount /mnt/ext`.

**Checks:** `sudo docker inspect immich_server immich_postgres` lists `/media/immich/data`
and `/media/immich/db` as mount sources. `sudo docker logs immich_postgres` shows an
existing cluster starting ("database system was shut down at"), never `initdb`. The web
UI's asset count matches the one written down. Syncthing's GUI shows the same device ID and
its folders up to date. `sudo bin/check-mount-guards` reads ok for `/media/immich`.

**Way back**, while nothing new has been uploaded: stop Immich, put the old `.env` lines
back, revert the fstab commit and install it, mount the two old subvolumes, and redeploy
with `immich_dump=false`. The move only read the old subvolumes. Uploads made after the
switch exist only in the new one; copy them across with rsync before going back. For
Syncthing, stop it and swap the names `config` and `config.old` back.

**Later**, after the first send and Slice 4: measure, then `sudo btrfs subvolume delete`
`media-immich-data` and `media-immich-db`, `sudo rm -rf` `config.old`, and `chattr -i` and
`rmdir` the two old bare mountpoints. Being reflinked, they free only what has changed
since.

## The send side on `zero`

`hosts/zero/system/mirror-backup`, rewritten at the same path and hour. An outline:

1. Acts only in the 04 hour, or on `now`; `full` allows a full send. One run at a time
   (`flock`); its output in `/var/lib/mirror-backup/last.log`, as now.
2. Mounts the array's top level at `/mnt/ext` if it is not mounted, and unmounts it after
   if it did.
3. For each of `immich` and `media-syncthing`, named `syncthing` in its snapshots and to
   `three`:
   1. Takes a read-only snapshot, `snapshots/<name>/<stamp>`.
   2. Its parent is the snapshot named in `last-sent-<name>`, if it is still on `zero`.
      With no parent and no `full`, it refuses and moves on: a full send over the tailnet
      is about 120 GB, and no run starts one unasked.
   3. Pipes `btrfs send [-p <parent>] <snapshot>` through ssh to `backup@three`, passing
      the name as the ssh command, optionally rate-limited (open question 7).
   4. Reads `three`'s last line, `received <stamp> <received UUID>`, and compares the UUID
      with the snapshot's own (`btrfs subvolume show`). Only a match counts.
   5. On a match, writes `last-sent-<name>`, then deletes that subvolume's older
      snapshots beyond what open question 1 keeps. On anything else, deletes the new
      snapshot and keeps the parent.
4. Writes `last-success` only when both subvolumes matched.

The snapshot is taken with Immich running. Postgres recovers from it as from a power cut,
because its data and its write-ahead log are in the same instant; Slice 4 proves that once
on the real data. The ssh options are today's: the pinned `known_hosts`, `BatchMode`, a
connect timeout, and `ServerAliveInterval` in place of rsync's `--timeout`, so a dead path
ends the run.

If a stream arrives but its reply is lost, `three` holds a snapshot that `zero` deleted.
The next run sends from the older parent, which `three` still holds unless 90 days have
passed; `mirror-backup-age-check` reports long before that.

## The receive side on `three`

**The key line** (`hosts/three/leap/system/backup-authorized-keys`) keeps
`restrict,from="100.121.158.58"` and zero's key; its forced command hands the requested
name to `sudo -n /usr/local/sbin/mirror-receive`. **A new sudoers file** lets the `backup`
user run, as root and without a password, `mirror-receive immich` and `mirror-receive
syncthing`, and nothing else. The `backup` user stays as the login and owns nothing on the
array; `incoming` becomes root's.

**`mirror-receive`**, a new tracked script in `/usr/local/sbin`:

1. Refuses unless `/media/mirror` is a mountpoint. Against a locked `three`, `zero`'s run
   fails and the next one retries, as now.
2. Refuses a name not on its list, which sudoers already checked.
3. One receive at a time (`flock`).
4. Deletes every subvolume in `incoming/<name>/` that is writable or has no received
   UUID: what an interrupted stream leaves.
5. Runs `btrfs receive --chroot -e /media/mirror/incoming/<name>` on its stdin.
   `--chroot` confines every path in the stream to that directory.
6. Checks the new subvolume is read-only with a received UUID, and prints `received <stamp>
   <received UUID>`.
7. Prunes that subvolume's snapshots created more than 90 days ago, never the newest. The
   age is the subvolume's creation time on `three`'s clock, never its name or a count, so
   a compromised `zero` cannot push history out by sending many snapshots or misnamed ones.

A compromised `zero` can send new snapshots, junk included, and fill the array; a full
array refuses sends and the age check reports it. It cannot change or delete a received
snapshot, read anything back, or run anything else.

A received snapshot is never made writable (`btrfs property set ... ro false`): that clears
its received UUID and ends the chain of incremental sends. A restore works from a reflink
copy or a writable snapshot of it.

## The first send

1. The move on `zero`, then the receive side installed on `three`, then `sudo sh -c
   'setsid nohup /etc/periodic/hourly/mirror-backup now full </dev/null >/dev/null 2>&1 &'`
   on `zero`, detached as the runbook's slice 3 starts the push today.
2. While `three` is in the UK it goes over the tailnet addresses, since the key accepts only
   `zero`'s, and Tailscale carries it directly over the LAN. About 93 G for Immich and 28 G
   for Syncthing on 2026-11-02; hours.
3. A stream cannot resume. Cut off, it leaves a half-received subvolume that the next
   receive deletes, and that subvolume's send starts over. Each subvolume is its own
   stream, so a cut costs one.
4. If it is not done before 21 November: once `three` is unlocked in Singapore, over the
   tailnet, rate-limited.

## What is removed

In the commit that lands the new path:

- On `three`: `rsync-backup.conf`; `mirror-snapshot` with its service and timer; the
  timer's name in `mirror-mount.conf`; the lines of `combustion/script` that install them;
  the `snapshots` directory (`make-mirror`, or PR #22).
- On `zero`: the rsync push inside `mirror-backup`. rsync stays installed; the move's checks
  and restores use it.
- In the simulation: the rsync stages of `sim/microos/host/three.sh` and `three-backup.sh`,
  and the snapshot timer in `checks-three.sh`.
- In the docs: `three.md` § Backups, `hosts/three/leap/README.md` § Snapshots and scrubs
  and § The backup, `hosts/zero/system/README.md`'s two rows, and `decisions.md`'s rsync
  sections of 2026-11-03 and 2026-11-04 marked superseded. The paths `/media/immich-data`
  and `/media/immich-db` change in `CLAUDE.md` § Shell traps, `docs/recovery.md`,
  `.env.example`, `.gitignore`'s comment, the Immich deploy hook's comment and
  `bin/check-mount-guards`' comments. `docs/fleet-inventory.md` regenerates.

## How the simulation proves it

The `host` job's `three` run keeps a runner in `zero`'s place, now with a small btrfs on a
loop file laid out as `zero`'s will be: `immich` with `data` (`thumbs` nested) and `db`
holding a small Postgres that is writing during the snapshot, and `media-syncthing` with
`config` nested. The runner's kernel and btrfs-progs differ from the Leap VM's, as `zero`'s
do from `three`'s, so protocol 1 is tested across a real gap. It checks:

1. **A full send:** the received subvolume is read-only, with the runner's snapshot UUID as
   its received UUID; `thumbs` and `config` arrive as empty directories; a hash of every
   path, owner, mode and size matches on both sides.
2. **An incremental:** a file added and one deleted arrive, and the stream is small.
3. **Confinement:** the key runs no other command, a name off the list is refused, nothing
   is read back, and a locked array refuses cleanly and the next run succeeds.
4. **An interrupted send:** the pipe killed halfway; the next run deletes the half-received
   subvolume and succeeds, and the runner kept its parent and wrote no success.
5. **Pruning:** with retention set to 0 days, the newest survives and the others go.
6. **No full send unasked:** with `last-sent` missing and no `full`, the script refuses.
7. **A restore:** a reflink copy of the received `db` starts in a throwaway Postgres
   container on `three`, recovers, and answers with the rows written before the snapshot.

## Slice 4, revised

Once: at the visit if the first send is done by then, otherwise after it. It replaces step
1 of `visit-runbook.md`'s slice 4; steps 2 and 3 stand.

1. **The library.** On `three`, `sudo cp -a --reflink=always
   /media/mirror/incoming/immich/<stamp>/data/library /media/mirror/restore/library`. On
   both sides, the same snapshot, `zero`'s under `/mnt/ext/snapshots/immich/<stamp>/`:
   `sudo find <path>/data/library -printf '%P %U:%G %m %s\n' | sort | sha256sum`. The two
   hashes match exactly, since both read the same instant.
2. **The database.** `sudo cp -a --reflink=always .../<stamp>/db /media/mirror/restore/db`,
   then a throwaway container of the Postgres image and digest in
   `deployments/immich/compose.yaml` on that directory, with no ports. Its log reads an
   automatic recovery, then "ready to accept connections", and a count of Immich's assets
   matches `zero`'s but for uploads since the stamp. Then remove the container and `sudo rm
   -rf /media/mirror/restore`.
3. **A restore of Immich itself** recreates `thumbs` and `encoded-video` with an empty
   `.immich` file in each before its first start: Immich checks for that marker in each of
   its folders. The simulation or this slice confirms it, and `docs/recovery.md` records it.

Repeated only after a change to the backup path, such as `zero` moving to Leap.

## Open questions

Each for the owner, with the infra agent's recommendation.

1. **Snapshot names, place and schedule on `zero`.** Recommended: `snapshots/<name>/` at
   the array's top level, named for the UTC time, `2026-11-20T0400Z`, the same name
   received on `three`; nightly at 04:00 as now. The 02:00 dump no longer matters for
   consistency, but 04:00 keeps a half-written dump out of the snapshot. Keep the last
   sent; a week of nightly snapshots on `zero` would make a deleted album a local restore,
   once question 2 says it is cheap.
2. **`zero`'s free space for snapshots.** Free now: `sudo btrfs filesystem usage -T
   /media/syncthing`. After a week of snapshots, what each one alone holds, which is what
   deleting it frees: `sudo btrfs filesystem du -s /mnt/ext/snapshots/immich/*`, the
   *Exclusive* column. Recommended: measure before settling question 1.
3. **Mount guards for `/media/immich`.** Recommended: `chattr +i` before the first mount
   (the move, step 6). `check-mount-guards` finds mounts in fstab, so it covers the new line
   with no change but its comments. The old bare mountpoints keep the flag until their
   subvolumes are deleted. `/media/immich/db` is mode 700 and Postgres's, so a test as
   gavin reads it as missing (`CLAUDE.md` § Shell traps): every check in the scripts and the
   runbook runs as root or with `sudo test -d`.
4. **The layout on `three`.** Recommended: `incoming/<name>/<stamp>`, with `incoming`
   root's and mode 700, and no `snapshots`. PR #22's play then makes that layout; the array
   made on 2026-11-18 is adjusted by hand first (`incoming` chowned to root, anything an
   rsync push left in it deleted, `snapshots` removed), so the play's "nothing changed" run
   holds. `three`'s README restore steps become a reflink copy out of a snapshot, with no
   `--fake-super`: root received the real owners.
5. **Syncthing on `three` (`syncthing-three`).** Recommended: it keeps its own subvolume,
   as `make-mirror` made it, outside `incoming`, never received into. With `three`'s timer
   gone it has no snapshots of its own; `zero`'s share arrives in `incoming` regardless.
6. **The restore path back to `zero`.** Recommended: a few files come from a snapshot on
   `zero` when one covers them (question 1). A whole restore is a `btrfs send` from `three`
   into `zero`'s `btrfs receive`, with a key made for the restore and removed after, so
   the exception to *no box holds a key to another* stays one-way in normal running. While
   `three` is in the UK, carrying its drive is the alternative. After a whole restore, the
   next send to `three` is a full one, unless the simulation shows an incremental from the
   restored snapshot works. The procedure goes into `docs/recovery.md`.
7. **Rate-limiting a tailnet send.** Recommended: `pv -q -L <rate>` in the pipe, with the
   rate a variable in `mirror-backup`, empty on the LAN, and `pv` added to the Alpine
   hosts' packages. The rate is the owner's, from `zero`'s upload speed. A full stream
   cannot resume, so a seed that keeps being cut off over the tailnet is a reason to wait
   for a LAN seed rather than retry.
8. **How `mirror-backup-age-check` learns success.** Recommended: unchanged,
   `/var/lib/mirror-backup/last-success`, written only when both subvolumes matched. Its
   message already points at `last.log`. Only its comments change.
9. **How the simulation proves it.** Recommended: the seven checks above. The Postgres
   restore in check 7 costs CI minutes; if it proves too slow, Slice 4's real check covers
   it, and the simulation keeps the rest.
