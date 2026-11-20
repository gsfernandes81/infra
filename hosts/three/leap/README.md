# three on Leap

`three` is the off-site backup in the Argon EON ([`plans/three.md`](../../../plans/three.md)).
It is a new host: the 1 GB Pi 4 that runs `one` today, on a new SD card. This directory is
its first boot, in `one`'s shape ([`leap/README.md`](../../../leap/README.md)), plus what only
`three` has: the backup array behind a passphrase.

| Path | What it is |
|---|---|
| `combustion/script` | The first-boot script. |
| `system/` | Every file the first boot installs, each at the path its `infra-` header names. |
| `fstab.append` | The array's entry, `noauto`. |
| `make-backup` | Formats the backup drive, once, on a new drive. |

## Before the stick

Two files carry zero's values, committed on 2026-11-20 from the play below; before that
they held placeholders, and `make-stick` refuses a stick while they are there: `system/restore-authorized-keys`, zero's restore key, and `system/zero-known-hosts`,
zero's ssh host key, which the pull pins. Both are printed by one play, once zero is on the
tailnet (`server-install-tailscale.yml`). From the phone:

```fish
# on the phone: make zero's restore key if it has none, and print it, zero's address and zero's host key for three's files
cd ~/infra/ansible; and ansible-playbook playbooks/server-create-restore-key.yml -e target=zero -K
```

It makes `/root/.ssh/restore` only if no key is there. The infra agent commits the key and
zero's host key in place of the placeholders, checking each against the fingerprint the play
prints, and the stick can be built. Zero's tailnet address is already in both files. A
rebuilt three also makes a new pull key (§ The backup), so zero's key line changes after
its first boot.

## The stick

`three` has no old system to carry anything from, so its stick is built with `--new` on
`zero` or `two`. Never on the old `one`'s Alpine card while Leap `one` runs: both would
claim `one`'s address and tunnel.

```fish
# on zero or two: build three's first-boot stick; put the stick's device in place of /dev/sdX
cd ~/infra; and git pull
sudo leap/make-stick --new three /dev/sdX
```

It makes `three`'s ssh host key on the stick and prints its fingerprint: check it at the
first `ssh three`. It asks for `three`'s root password, which the console needs. It takes
gavin's password hash and keys from the box it runs on, so `three`'s sudo password is that
box's. It carries no tunnel credentials, `.env` or
volume, because `three` has none yet.

## After the first boot: the tunnel

The first boot leaves `cloudflared` installed and enabled, and skipped until its config
exists. On the LAN, from the phone:

1. The infra agent adds `three` to `ansible/inventory`'s `[fleet]` and `[containerized]`
   groups, which it joins only once it answers, since every fleet-wide play would
   otherwise stop on it.
2. `server-create-host-tunnel.yml -e target=three -K` writes `/etc/cloudflared/three.json`
   and prints the tunnel id.
3. The infra agent commits `system/cloudflared-config.yml` with that id, in the shape of
   every host's: `ssh-three` to port 22, and `syncthing-three` to `http://127.0.0.1:8384`,
   Syncthing's GUI, which nothing else reaches (sshd's `PermitOpen` allows port 22 only).
   The `syncthing-three` rule carries `originRequest: {httpHostHeader: localhost}`: a
   Syncthing GUI bound to `127.0.0.1` refuses a request whose `Host` is not a local name,
   with "Host check error", and through the tunnel the `Host` is `syncthing-three`'s. `zero`'s
   and `torrents`' GUIs listen on every address, where Syncthing makes no such check.
4. On `three`, in `~/infra`: `git pull`, then
   `sudo bin/install-system-file cloudflared-config.yml --commit --allow-content-change --new`,
   then `sudo systemctl start cloudflared`. The tools read `leap/system/` because
   `leap/MOVED` says `three` runs Leap. From the phone,
   `server-install-system-files.yml -l three -e only=cloudflared-config.yml -K` does the
   same install.
5. `server-create-fleet-ssh-access.yml -e host=three` gates `ssh-three` behind Access,
   admitting each client's fleet token, as it does every box's ssh hostname. It reads the
   routing from `leap/system/`, by the same `leap/MOVED`, and refuses unless this client's
   ssh config already sends `three` through `~/.config/fleet/access-ssh`, which the fleet
   ssh block does once the infra agent has added `three` to it.
6. Once Syncthing is deployed (`plans/visit-runbook.md`, slice 4), from the phone:
   `server-create-browser-login.yml -e host=three -e subdomain=syncthing-three` puts the
   GUI behind an Access login and then gives it its DNS record. The fleet ssh play leaves
   `syncthing-three` alone, since a browser needs a login, not a service token, and the
   tunnel play makes `ssh-three`'s record only.

   It makes an Access application, `syncthing-three`, admitting the addresses in
   `~/.config/cloudflare/access-emails` on the phone by the account's login methods, as
   `calibre-web`'s login does; only once it has read that back does it write the CNAME to
   `three`'s tunnel, so the GUI is never open. It refuses a hostname that is not an http
   rule in the tracked config above, and a `tunnel:` that `ssh-three`'s record does not
   point at. It then proves from the phone that the hostname redirects an unauthenticated
   request to the Access login, and deletes the record again if the hostname answers
   anything else. It needs no `-K`, since it touches only Cloudflare. Until it has run,
   the GUI cannot be reached from outside; after, it is `https://syncthing-three.gsrpi.uk/`.
   A "Host check error" after the login means step 3's `httpHostHeader` is missing.

## The array

The first drive is a WD Red Plus that reports itself as `WDC WD40EFZZ-68CPAN0` (sold as the
WD49EFZZ), serial `WD-WXB2D76N8PYJ`. The owner checked the serial with WD, and smartctl read
it on 2026-11-18 at 0 power-on hours, with no reallocated or pending sectors and error
recovery at 7 seconds.

The drive is formatted once, after the first boot, with the drive in the Argon's middle bay
and nothing on it. After `ssh three`:

```fish
# find the new drive: the WD Red, about 3.6T, with no partitions
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN
# format it; it asks for the device name, then the passphrase twice, and leaves it locked
sudo ~/infra/hosts/three/leap/make-backup /dev/sdX
```

`make-backup` refuses a drive with partitions or any signature on it, so it never formats a
drive in use. It writes LUKS2 with Adiantum, labelled `backup-luks`, which
`/etc/crypttab` names. Inside is a btrfs, labelled `backup`, holding `syncthing` and `immich`:

| On the array | What | Whose |
|---|---|---|
| `immich/` | a directory, the restore module's whole reach | root's, 755 |
| `immich/current/` | subvolume: the copy of zero's newest snapshot that `backup-pull` keeps up to date | the backup user's, 700 |
| `immich/current/.snapshots/<N>/snapshot` | snapper's read-only snapshots of `current/`, one per good pull | root's; `.snapshots` 754, which lets the pull's rsync read its (absent) xattr while it decides what `--delete` removes, and enter nothing |
| `immich/state/` | `pulled`: what the last good pull copied | the backup user's, 700 |
| `immich/last-pulled` | what the last snapshot holds | root's |
| `syncthing/` | subvolume: Syncthing's data and identity | gavin's |

The array made on 2026-11-18 was made by `make-backup`'s first version, `make-mirror`, under
the names "mirror" had until 2026-11-20 (`mirror-luks`, `/media/mirror`), and holds the push's
layout: `incoming` and `snapshots` beside `syncthing`. § The rename, below, renames and
reshapes it in place.

The names say "backup" because "mirror" reads as RAID (the owner, 2026-11-19). The LUKS label
is `backup-luks`, the crypttab name and the device `/dev/mapper/backup`, the btrfs label
`backup`, and the mount `/media/backup`, `media-backup.mount`.

### Unlocking, after every boot

Every boot leaves the array locked, and nothing waits for it. From the phone, the play,
which asks for gavin's password (`-K`) and then for the passphrase of each volume still
locked, three's array among them:

```fish
# unlock every listed volume that is locked; Enter alone at a passphrase prompt leaves that one locked
cd ~/infra/ansible; and ansible-playbook playbooks/server-unlock-arrays.yml -l three -K
```

It reads the array first and asks nothing when it is already open. It ends with one line
per volume, `three backup: unlocked, and mounted at /media/backup` when it worked; a wrong
passphrase reads `failed: wrong passphrase; still locked`, and the play can be run again.
The passphrase reaches the box only on stdin, and systemd takes it through the same unit
as the command below, so everything after the unlock, the lock included, is the same
whichever unlocked it. The list of volumes is `ansible/host_vars/three.yml`.

Or by hand, where sudo asks for gavin's password and then systemd for the passphrase:

```fish
# unlock three's array; sudo asks for gavin's password, then systemd for the passphrase
ssh -t three 'sudo systemctl start systemd-cryptsetup@backup.service; and sudo systemctl start media-backup.mount'
```

Two starts, so the mount's 5-minute wait for the device begins only once the passphrase is
in, however long finding it takes. The mount starts Docker, which brings Syncthing up
under its restart policy, and the pull and scrub timers. Until then, Docker is skipped
by its condition, and `docker` answers that it cannot connect. A hand `mount /media/backup`
starts none of them: only `systemctl start` does. For a few seconds while Docker first
starts, a new ssh connection can be refused; the simulation saw one attempt fail between
two that answered. Try again. The cause is not yet known (`docs/management-plane.md`,
phase 9). A pull against a locked `three` is skipped by
its condition, and the timer, `Persistent=`, pulls once the array is unlocked.

To lock it again without a reboot (Docker, a running pull and a running scrub stop with
the mount). The passphrase is not cached, so the next unlock asks for it again:

```fish
# lock three's array: Docker first, then the mount, then the LUKS volume; it prints
# "locked" only once the volume is really closed
ssh -t three 'sudo systemctl stop docker.service media-backup.mount systemd-cryptsetup@backup.service; and test ! -e /dev/mapper/backup; and echo locked'
```

### Snapshots, scrubs

Snapshots are the backup's, below. The scrub runs monthly; a month missed while the box was
off or locked scrubs once the array is unlocked. `sudo btrfs scrub status /media/backup` shows
the last result.

## The backup

`three` pulls `zero`'s backup ([`docs/decisions.md`](../../../docs/decisions.md)
§ *`zero`'s backup is pulled by rsync from snapshots*).
`zero` takes an hourly read-only snapper snapshot of its Immich, the library and Postgres in
one subvolume. Daily at 01:00 UTC, `backup-pull.timer` starts `backup-pull.service`, which
runs `/usr/local/bin/backup-pull` as the backup user: it lists `zero`'s snapshots, picks the
newest finished one, and, if it is not the one pulled last, copies it with rsync into
`/media/backup/immich/current`, at 32 Mbit/s. Only a success starts
`backup-snapshot.service`, which takes a read-only snapper snapshot of `current/`, prunes to
14 daily, 8 weekly and 12 monthly, and writes `last-pulled`. A pull cut off, or one whose
files vanish (rsync's exit 24, which a frozen snapshot cannot cause), takes no snapshot; the
next day's pull finishes the copy.

The backup user owns `current/` and nothing else, never logs in, and runs the pull in a
sandbox that can write only `current/` and `state/`. It reaches `zero` with its own key,
`/home/backup/.ssh/zero-pull`, through `system/backup-ssh-config`, which names zero's tailnet
address and accepts only the host key in `system/zero-known-hosts`; both are root's. On
`zero` that key runs nothing but a read-only rsync daemon. zero's owners and modes are kept
in an xattr (`--fake-super`). With it, rsync keeps each symlink as a plain file holding its
target, its type in the xattr, so `three` holds no symlink of `zero`'s at all, and the target
is munged besides (`/rsyncd-munged/...`); the restore module turns both back.

The timezone is UTC: 01:00 in a UK winter, 02:00 in a UK summer, 09:00 in Singapore.

### The rename, owner-run, on the array made on 2026-11-18

**Done on 2026-11-20**, block by block as below, with rename 16b in place of the play:
`three` boots snapshot 3, the array unlocks as `backup` at `/media/backup`, and
`syncthing-three` came back healthy with the subvolume, entry count and certificate rename 2
recorded. Kept as the record, and as the procedure for any box still on the old names.

Once, on the live array, before the pull's setup below. It renames the array from "mirror"
to "backup" and reshapes it to the layout above, in place: the passphrase, the LUKS volume
and the btrfs inside stay as they are. A new drive needs none of it: `make-backup` makes the
new names and layout, and a rebuilt `three`'s first boot installs the new files.

**What is at risk.** The array holds Syncthing's data and identity, in the subvolume
`syncthing`, and nothing else of value: no pull has run, so `three` holds no copy of
`zero`'s Immich yet, and the push's `incoming` and `snapshots` never received anything. No
step below names `syncthing` in a command that writes; only its mount path changes, from
`/media/mirror/syncthing` to `/media/backup/syncthing`. Rename 2 records its subvolume's
UUID, its number of entries and Syncthing's certificate, and rename 15 compares all three.
The only writes to the array are rename 3's reshape, which refuses unless the old places are
empty, rename 4's btrfs label and rename 6's LUKS label, after a header backup.

**Before:** the rename merged into `main`, the owner beside `three`, the array unlocked
(§ Unlocking, with the old names: `systemd-cryptsetup@mirror.service`, then
`media-mirror.mount`). Each block is pasted after `ssh three`, in fish, except rename 14 and
rename 16, which are run on the phone. Each says what good output looks like; anything
else, stop and read the way back at the end.

1. **Read the state**, changing nothing:

   ```fish
   # rename 1, on three: read the state before the rename, changing nothing
   cd ~/infra; and git pull --ff-only; and test -e hosts/three/leap/make-backup; and echo "the checkout has the rename"
   findmnt -no SOURCE,TARGET,OPTIONS /media/mirror; sudo btrfs filesystem label /media/mirror
   sudo btrfs subvolume list /media/mirror
   sudo blkid -L mirror-luks; readlink -e /dev/disk/by-label/mirror-luks
   findmnt -no SOURCE /; sudo btrfs subvolume get-default /
   systemctl is-system-running; systemctl --failed --no-legend
   sudo docker ps -a --format '{{.Names}} {{.Status}} {{.Mounts}}'
   ```

   Good output: `the checkout has the rename`; `/dev/mapper/mirror /media/mirror` with
   `noatime` and no `nosuid` (the line rename 7 replaces); the label `mirror`; the subvolume
   list holds `incoming`, `syncthing` and one `snapshots/<date>` per day the old timer ran,
   and nothing else; `blkid` and `readlink` name the same `/dev/sdX`, which shows the
   by-label link rename 6 reads is working; `findmnt /` ends `/@/.snapshots/<N>/snapshot]`
   and `get-default` names the same `<N>` (rename 11 changes the second, and rename 13 reads
   both again). If they name different numbers, stop: a snapshot is pending, and rename 11,
   which builds on the running system, would drop it. Whatever `is-system-running` and `--failed` say, rename 13 compares with it;
   and `syncthing` up, on `/media/mirror/syncthing`. Anything else in the subvolume list, or
   an `immich` already there, stop.
2. **Stop what uses the array**, and record Syncthing's subvolume:

   ```fish
   # rename 2, on three: stop Syncthing (docker compose start is the way back) and the old timers, then record the syncthing subvolume's UUID, its number of entries and Syncthing's certificate
   cd ~/infra/deployments/syncthing-three; and sudo docker compose stop; and sudo docker compose ps -a
   sudo systemctl stop mirror-snapshot.timer mirror-scrub.timer mirror-snapshot.service mirror-scrub.service
   begin; sudo btrfs subvolume show /media/mirror/syncthing | awk '$1 == "UUID:" { print $2 }'; sudo find /media/mirror/syncthing | wc -l; sudo sha256sum /media/mirror/syncthing/config/cert.pem | cut -d' ' -f1; end > ~/rename-syncthing.txt; cat ~/rename-syncthing.txt
   ```

   `compose ps -a` shows `syncthing` `Exited`. The file holds three lines: a UUID, a number
   and a hash. A line missing, or an error from `sha256sum`, means rename 15 has nothing to
   compare with: find where Syncthing keeps its certificate (`sudo ls
   /media/mirror/syncthing`) before going on. `syncthing-three`'s restart policy is
   `unless-stopped`, so Docker leaves a container stopped this way stopped through the
   reboot.
3. **The reshape**, while the array is still mounted at `/media/mirror`. It refuses unless
   `immich` is not there yet, `incoming` is an empty subvolume, and every entry of
   `snapshots` is a subvolume holding nothing, as the old timer's read-only snapshots of an
   empty `incoming` are; then it deletes them and makes `immich`, as `make-backup` does:

   ```fish
   # rename 3, on three: delete the push's empty incoming and its empty snapshots, then make immich, current, its .snapshots and state; it refuses, changing nothing, unless all of them are empty and immich is not there
   sudo sh -euc '
   m=/media/mirror
   mountpoint -q $m
   [ ! -e $m/immich ] || { echo "rename 3: $m/immich exists already; nothing changed"; exit 1; }
   btrfs subvolume show $m/incoming > /dev/null
   [ -d $m/snapshots ] || { echo "rename 3: no $m/snapshots; nothing changed"; exit 1; }
   [ -z "$(find $m/incoming -mindepth 1 | head -n 1)" ] || { echo "rename 3: $m/incoming is not empty; nothing changed"; exit 1; }
   [ -z "$(find $m/snapshots -mindepth 2 | head -n 1)" ] || { echo "rename 3: a snapshot in $m/snapshots is not empty; nothing changed"; exit 1; }
   [ -z "$(find $m/snapshots -mindepth 1 -maxdepth 1 -name ".*" | head -n 1)" ] || { echo "rename 3: a dot entry in $m/snapshots, which the loop below would miss; nothing changed"; exit 1; }
   for s in $m/snapshots/*; do [ ! -e "$s" ] || btrfs subvolume show "$s" > /dev/null; done
   for s in $m/snapshots/*; do [ ! -e "$s" ] || btrfs subvolume delete "$s"; done
   rmdir $m/snapshots
   btrfs subvolume delete $m/incoming
   install -d -m 755 $m/immich
   btrfs subvolume create $m/immich/current
   chown backup:backup $m/immich/current
   chmod 700 $m/immich/current
   btrfs subvolume create $m/immich/current/.snapshots
   chmod 754 $m/immich/current/.snapshots
   install -d -o backup -g backup -m 700 $m/immich/state
   btrfs subvolume list $m
   ls -la $m $m/immich
   '
   ```

   Good output: a `Delete subvolume` line for each snapshot and for `incoming`, two `Create
   subvolume` lines, then a subvolume list of `syncthing`, `immich/current` and
   `immich/current/.snapshots` alone; `immich` root's at `drwxr-xr-x`, `current` backup's at
   `drwx------`, `state` backup's at `drwx------`. A `rename 3:` line means it stopped before
   any change, and says why.
4. **The btrfs label**, from `mirror` to `backup`. Nothing reads it; it is renamed so no
   name on the array says "mirror":

   ```fish
   # rename 4, on three: relabel the btrfs inside the array from mirror to backup, then read the label back
   sudo btrfs filesystem label /media/mirror backup; and sudo btrfs filesystem label /media/mirror
   ```

   It prints `backup`.
5. **Lock the array**, under its old names, so its LUKS label can change and it can open
   under its new one:

   ```fish
   # rename 5, on three: lock the array under its old names; it prints locked only once the LUKS volume is closed
   sudo systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service; and test ! -e /dev/mapper/mirror; and echo locked
   ```

   It prints `locked`. If it does not, `sudo fuser -vm /media/mirror` names what holds it.
6. **The LUKS label**, from `mirror-luks` to `backup-luks`, after a backup of the header.
   The label is in the LUKS2 header's metadata, which cryptsetup keeps two copies of; the
   key slots and the data are not touched. The backup and the passphrase together open the
   array, as the drive itself does, so it stays in root's home at mode 600 and goes at
   rename 18:

   ```fish
   # rename 6, on three: back up the LUKS header into root's home, then relabel mirror-luks to backup-luks, and read the label back from the disk and from udev
   set dev (sudo blkid -L mirror-luks); test -b "$dev"; and echo "the array is $dev"
   test -b "$dev"; and sudo test ! -e /root/backup-luks-header.img; and sudo cryptsetup luksHeaderBackup $dev --header-backup-file /root/backup-luks-header.img; and sudo chmod 600 /root/backup-luks-header.img; and sudo ls -l /root/backup-luks-header.img
   test -b "$dev"; and sudo test -s /root/backup-luks-header.img; and sudo cryptsetup config --label backup-luks $dev; and sudo udevadm trigger --settle --action=change $dev; and sudo cryptsetup luksDump $dev | grep -E '^(Version|Label):'; and readlink -e /dev/disk/by-label/backup-luks; and test ! -e /dev/disk/by-label/mirror-luks; and echo "relabelled"
   ```

   Good output: `the array is /dev/sdX`, the device rename 1 named; the header file root's,
   `-rw-------`, about 16 MB; `Version: 2`, `Label: backup-luks`, the same `/dev/sdX`, and
   `relabelled`. The first line printing nothing means `blkid` found no `mirror-luks`, and
   nothing after it runs. Run a second time, the second line prints nothing, since the header
   backup is there already, and the third relabels with that first backup in place.
7. **fstab**: the array's line replaced whole by `fstab.append`'s, never one option edited,
   since the live line lacks `nosuid,nodev`, which the new line carries:

   ```fish
   # rename 7, on three: copy fstab into root's home, then replace the /media/mirror line with fstab.append's line; it refuses, changing nothing, unless there is exactly one /media/mirror line and no /media/backup line
   sudo sh -euc '
   new=/home/gavin/infra/hosts/three/leap/fstab.append
   [ "$(wc -l < $new)" = 1 ] || { echo "rename 7: $new is not one line; nothing changed"; exit 1; }
   [ "$(grep -c "^[^#]*[[:space:]]/media/mirror[[:space:]]" /etc/fstab)" = 1 ] || { echo "rename 7: not exactly one /media/mirror line in /etc/fstab; nothing changed"; exit 1; }
   ! grep -q "^[^#]*[[:space:]]/media/backup[[:space:]]" /etc/fstab || { echo "rename 7: a /media/backup line is there already; nothing changed"; exit 1; }
   install -m 600 /etc/fstab /root/fstab.before-rename
   grep -v "^[^#]*[[:space:]]/media/mirror[[:space:]]" /etc/fstab > /etc/fstab.rename
   cat $new >> /etc/fstab.rename
   chmod 644 /etc/fstab.rename
   mv /etc/fstab.rename /etc/fstab
   restorecon /etc/fstab
   diff /root/fstab.before-rename /etc/fstab || true
   '
   ```

   The diff shows one line gone, `/dev/mapper/mirror /media/mirror ...noatime 0 0`, and one
   added, `/dev/mapper/backup /media/backup ...noatime,nosuid,nodev 0 0`, still `noauto`,
   which keeps a boot from waiting for the array and an SELinux relabel from mounting it
   (`docs/management-plane.md`, phase 9).
8. **crypttab and the array's units**, each with a dry run first:

   ```fish
   # rename 8, on three: install crypttab and the renamed mount, Docker and scrub units; each dry run shows its diff or a new file, then --commit writes it
   sudo install -d -m 755 /etc/systemd/system/media-backup.mount.d
   cd ~/infra
   for f in crypttab backup-mount.conf docker-backup.conf backup-scrub.service backup-scrub.timer
       bin/install-system-file $f --new --allow-content-change; and sudo bin/install-system-file $f --new --commit --allow-content-change; or break
   end
   ```

   `crypttab`'s diff changes its comments and its one line, to
   `backup LABEL=backup-luks none luks,noauto,password-cache=no`; the four others are new
   files. Each ends `post-install checks: ok`. The dry run passes `--allow-content-change`
   too: without it, it refuses `crypttab`'s change, and the loop stops before the write.
   Rename 9 refuses to run until all five are in place.
9. **The old files out**, the push's leftovers with them, then the users as the pull wants
   them and systemd reloaded. The old files hold no secret, so they are copied with their
   modes into one directory of root's, outside every directory they came from:

   ```fish
   # rename 9, on three: copy the old units and the push's leftovers into root's home, remove them, give backup no shell, make the restore user, reload systemd, and read what systemd now has
   sudo sh -euc '
   grep -qE "^backup[[:space:]]+LABEL=backup-luks[[:space:]]" /etc/crypttab || { echo "rename 9: crypttab does not name backup yet, so rename 8 has not finished; nothing changed"; exit 1; }
   for f in media-backup.mount.d/infra-wants.conf docker.service.d/infra-backup.conf backup-scrub.service backup-scrub.timer; do
   	[ -e /etc/systemd/system/$f ] || { echo "rename 9: no /etc/systemd/system/$f, so rename 8 has not finished; nothing changed"; exit 1; }
   done
   b=/root/rename-2026-11-20
   install -d -m 700 $b
   systemctl disable mirror-snapshot.timer mirror-scrub.timer 2> /dev/null || true
   for f in /etc/systemd/system/docker.service.d/infra-mirror.conf /etc/systemd/system/media-mirror.mount.d/infra-wants.conf /etc/systemd/system/mirror-scrub.service /etc/systemd/system/mirror-scrub.timer /etc/systemd/system/mirror-snapshot.service /etc/systemd/system/mirror-snapshot.timer /usr/local/sbin/mirror-snapshot /etc/rsync-backup.conf /home/backup/.ssh/authorized_keys; do
   	if [ -e "$f" ]; then cp -a --parents "$f" $b/; rm "$f"; echo "removed $f"; else echo "absent  $f"; fi
   done
   [ ! -d /etc/systemd/system/media-mirror.mount.d ] || rmdir /etc/systemd/system/media-mirror.mount.d
   usermod -s /usr/sbin/nologin backup
   id restore > /dev/null 2>&1 || useradd --system --user-group --no-create-home --home-dir /home/restore --shell /bin/bash --comment "zero\'s read-only restores" restore
   install -d -m 755 /home/restore /home/restore/.ssh
   systemctl daemon-reload
   '
   systemctl show -p What -p Where -p Options media-backup.mount; systemctl show -p Wants --value media-backup.mount
   systemctl show -p DropInPaths --value docker.service; systemctl list-unit-files --no-legend 'mirror-*' 'backup-scrub*'
   getent passwd backup restore
   ```

   Good output: a `removed` line for each file the box has (an `absent` one is a file this
   box never had); `What=/dev/mapper/backup`, `Where=/media/backup`, and options with
   `nosuid,nodev`; the mount wants `docker.service backup-pull.timer backup-scrub.timer`
   (the pull's timer arrives with the pull's setup); Docker's drop-ins name
   `infra-backup.conf` and not `infra-mirror.conf`; the unit files are the two
   `backup-scrub` ones, and no `mirror-` one; `backup` ends `/usr/sbin/nologin`, and
   `restore` ends `/home/restore:/bin/bash`.
10. **The fan**, which finds the drive by its LUKS label: since rename 6 it finds none, and
    follows the CPU alone:

    ```fish
    # rename 10, on three: install the fan script that finds the drive by backup-luks, restart its unit (the stop sets the fan to full, the start picks the level again), and read what it found
    cd ~/infra; and bin/install-system-file argon-fan --allow-content-change; and sudo bin/install-system-file argon-fan --commit --allow-content-change; and sudo systemctl restart argon-fan.service
    journalctl -b -u argon-fan.service --since -2min --no-pager | grep -E 'drive found|no /dev/disk'
    ```

    The diff shows `DRIVE_LABEL` moving to `backup-luks`. The journal reads `drive found at
    /dev/sdX, by its LUKS label`, the device of rename 6; if it prints nothing, run the
    `journalctl` line again in half a minute.
11. **`/media/backup`**, on the read-only root, by a new snapshot, which also removes the
    empty `/media/mirror`. Last, after every change to `/etc` above: the new snapshot takes
    `/etc` as it is when it is made.

    ```fish
    # rename 11, on three: only if renames 7 to 9 are all in place, a new snapshot with /media/backup made and the empty /media/mirror removed; then read that it is the default and holds the right /media
    grep -qE '^backup[[:space:]]' /etc/crypttab; and grep -q '[[:space:]]/media/backup[[:space:]]' /etc/fstab; and test -e /etc/systemd/system/media-backup.mount.d/infra-wants.conf; and test ! -e /etc/systemd/system/mirror-scrub.timer; and sudo transactional-update --non-interactive run sh -c 'mkdir /media/backup && rmdir /media/mirror'
    findmnt -no SOURCE /; sudo btrfs subvolume get-default /
    set snap (sudo btrfs subvolume get-default / | sed -n 's|.* path @||p'); and sudo ls $snap/media
    ```

    `transactional-update` ends `New default snapshot is #<N+1>`; `get-default` now names
    that `<N+1>` while `findmnt /` still names rename 1's `<N>`; the new snapshot's `/media`
    holds `backup` alone. A failed run makes no snapshot and changes nothing. No
    `transactional-update` output at all means one of the four checks before it failed:
    crypttab, fstab, the mount's drop-in or the old scrub timer is not as renames 7 to 9
    leave them.
12. **The reboot**, into the new snapshot. The session ends:

    ```fish
    # rename 12, on three: reboot into the new snapshot
    sudo systemctl reboot
    ```

    If `ssh three` does not answer within ten minutes, the console shows why; an SELinux
    relabel of the new snapshot, if one runs, adds a few minutes and a second reboot.

13. **Read the boot**, after `ssh three` again:

    ```fish
    # rename 13, on three: read that the boot is the new snapshot, with /media/backup, and the array locked under its new name
    findmnt -no SOURCE /; sudo btrfs subvolume get-default /
    ls -d /media/*
    systemctl show -p ActiveState --value systemd-cryptsetup@backup.service media-backup.mount
    systemctl is-system-running; systemctl --failed --no-legend
    ```

    Good output: `findmnt /` and `get-default` both name `<N+1>`; `/media/backup` alone;
    `inactive` twice; the same `is-system-running` and failed units as rename 1 (`starting`
    in the first minute or so after the boot: read it again).

    `findmnt /` naming `<N>` again means health-checker rolled the boot back. The box is then
    up on `<N>`, whose root has `/media/mirror` and no `/media/backup`, while its `/etc` has
    every change of renames 7 to 9: the array opens as `backup` and mounts under neither
    name. Nothing on the array is lost. Stop there, and send the infra agent `journalctl -b
    -1 --no-pager | tail -n 100`. Once that is read, there are two ways forward, each ending
    in a reboot: `sudo transactional-update rollback <N+1>` if the failed boot was
    transient, or `sudo transactional-update --non-interactive run mkdir /media/backup`,
    which gives `<N>`'s root the new mount point.
14. **The unlock**, under the new names, from the phone: the command in § Unlocking.

    ```fish
    # rename 14, on the phone: unlock three's array under its new names; sudo asks for gavin's password, then systemd for the passphrase
    ssh -t three 'sudo systemctl start systemd-cryptsetup@backup.service; and sudo systemctl start media-backup.mount'
    ```

15. **Read the array**, and compare Syncthing's subvolume with rename 2's record:

    ```fish
    # rename 15, on three: read the array under its new names, and compare the syncthing subvolume with rename 2's record; it changes nothing
    findmnt -no SOURCE,OPTIONS /media/backup; sudo cryptsetup status backup | head -n 3; sudo btrfs filesystem label /media/backup
    sudo btrfs subvolume list /media/backup; sudo ls -la /media/backup /media/backup/immich
    begin; sudo btrfs subvolume show /media/backup/syncthing | awk '$1 == "UUID:" { print $2 }'; sudo find /media/backup/syncthing | wc -l; sudo sha256sum /media/backup/syncthing/config/cert.pem | cut -d' ' -f1; end > ~/rename-syncthing-after.txt
    diff ~/rename-syncthing.txt ~/rename-syncthing-after.txt; and echo "syncthing: the same subvolume, the same number of entries, the same certificate"
    systemctl is-active docker.service backup-scrub.timer
    ```

    Good output: `/dev/mapper/backup` with `nosuid,nodev` and the container context; `type:
    LUKS2`; the label `backup`; the subvolume list and the listing as rename 3 left them;
    `syncthing: the same subvolume, the same number of entries, the same certificate`; and
    `active` or `activating` for Docker, which is still starting a few seconds after the
    mount, then `active` for the timer. A diff line instead of that sentence: stop, and send it to the infra
    agent; nothing has started Syncthing.
16. **The redeploy**, from the phone, which recreates the container on the new path:

    ```fish
    # rename 16, on the phone: redeploy syncthing-three, which recreates its container on /media/backup/syncthing
    cd ~/infra/ansible; and ansible-playbook playbooks/server-deploy-compose.yml -e deployment=syncthing-three -K
    ```

    The play refuses if `three`'s Compose is older than 5.5.0, or if `three`'s checkout
    names a different commit from the phone's after its own `git pull`. If it refuses, the
    same recreate on `three` itself, after `ssh three`:

    ```fish
    # rename 16b, on three, only if the play refused: recreate syncthing-three on /media/backup/syncthing
    cd ~/infra/deployments/syncthing-three; and sudo docker compose up -d
    ```

17. **Read Syncthing**:

    ```fish
    # rename 17, on three: read the container's mount and health; healthy takes a minute or two
    sudo docker inspect syncthing --format '{{range .Mounts}}{{.Source}} {{end}}{{.State.Health.Status}}'
    ```

    It prints `/media/backup/syncthing healthy` (`starting` in the first minute). The GUI,
    `https://syncthing-three.gsrpi.uk/`, shows the device ID it had, and its devices
    reconnect.
18. **Clean up**, once Syncthing is healthy:

    ```fish
    # rename 18, on three: delete the LUKS header backup, which opens the array with the passphrase, and the copies of the old files and of fstab
    sudo rm /root/backup-luks-header.img; and sudo rm -r /root/rename-2026-11-20 /root/fstab.before-rename; and rm ~/rename-syncthing.txt ~/rename-syncthing-after.txt
    ```

    The backups `install-system-file` made, under `/root/.infra-backups/three/`, stay: they
    hold the old `crypttab` and `argon-fan`, and no secret.

**Way back, at each step.** None of these steps moves or rewrites Syncthing's data, so the
way back is about names, and never about data:

- rename 2: `sudo docker compose start` in `~/infra/deployments/syncthing-three`, and `sudo
  systemctl start mirror-snapshot.timer mirror-scrub.timer`.
- rename 3: nothing held data. The old layout, if wanted: `sudo btrfs subvolume delete
  /media/mirror/immich/current/.snapshots /media/mirror/immich/current; and sudo rm -r
  /media/mirror/immich`; nothing reads `incoming` or `snapshots` any more.
- rename 4: `sudo btrfs filesystem label /media/mirror mirror`.
- rename 5: the old unlock, `sudo systemctl start systemd-cryptsetup@mirror.service; and sudo
  systemctl start media-mirror.mount`, while the LUKS label is still `mirror-luks`.
- rename 6: `sudo cryptsetup config --label mirror-luks /dev/sdX`; if the header itself were
  damaged, `sudo cryptsetup luksHeaderRestore /dev/sdX --header-backup-file
  /root/backup-luks-header.img`, which writes back the header as it was before this step.
- rename 7: `sudo install -m 644 /root/fstab.before-rename /etc/fstab; and sudo restorecon
  /etc/fstab`.
- rename 8: `crypttab` from the backup `install-system-file` printed (`backed up ... ->`),
  and the four new files removed with `sudo rm`.
- rename 9: `sudo cp -a --no-preserve=context /root/rename-2026-11-20/. /; and sudo
  restorecon -R /etc/systemd/system /usr/local/sbin /home/backup`, which puts every removed
  file back with its mode, and its SELinux label from the policy rather than from root's
  home; `sudo usermod -s /bin/bash backup; and sudo userdel restore`; then `sudo
  systemctl daemon-reload`.
- rename 10: `argon-fan` from the backup `install-system-file` printed, then `sudo systemctl
  restart argon-fan.service`.
- rename 11: `sudo transactional-update rollback`, which makes the running snapshot the
  default again, so the reboot boots it; `get-default` then names `findmnt /`'s `<N>`.
  Before the reboot this is the whole way back, with the steps above in reverse order: the
  running system has every change to `/etc`, and its root has `/media/mirror` and no
  `/media/backup`.
- After rename 12, the old names would need all of that again, another snapshot and another
  reboot. Nothing calls for it: the data is where it was, under new names. A boot rolled
  back to `<N>` is not this: rename 13 says what state that leaves and the two ways forward.

### The pull's setup, once the rename is done

A rebuilt `three` does steps 1 and 2 at its first boot, and `make-backup` makes the layout on
a new drive; step 1's key is then made again, and `zero`'s key line changes with it.

1. **The pull key**, made here and never carried. **Made 2026-11-19**, fingerprint
   `SHA256:9rZpPX2SVlOOQfM1T81VzH6sOdk+0AvyLIaXm8B5juM`, and committed into `zero`'s key line:

   ```fish
   # pull setup 1, on three: make the backup user's key to zero, then print its public half and fingerprint for zero's key line
   sudo ssh-keygen -t ed25519 -N '' -C 'three backup-pull' -f /home/backup/.ssh/zero-pull; and sudo chown backup:backup /home/backup/.ssh/zero-pull /home/backup/.ssh/zero-pull.pub
   cat /home/backup/.ssh/zero-pull.pub; ssh-keygen -lf /home/backup/.ssh/zero-pull.pub
   ```

   Send the infra agent the public key and its fingerprint: it commits the key into
   `hosts/zero/system/backup-authorized-keys`, which `zero` then installs
   (`hosts/zero/system/README.md` § The backup).
2. **The files**, each with a dry run first, once the infra agent has committed zero's two
   values (§ Before the stick). After rename 13 there is no snapshot waiting for a reboot,
   so these changes to `/etc` stay:

   ```fish
   # pull setup 2, on three: install the pull, its units, snapper's config, the restore module and both users' ssh files; then label them and reload systemd
   cd ~/infra; and git pull --ff-only
   for f in backup-pull backup-pull.service backup-pull.timer backup-snapshot.service snapper-config-received-immich backup-ssh-config zero-known-hosts sudoers-restore rsyncd-restore.conf restore-authorized-keys
       bin/install-system-file $f --new --allow-content-change; and sudo bin/install-system-file $f --new --commit --allow-content-change; or break
   end
   sudo restorecon -Rv /home/backup /home/restore /usr/local/bin/backup-pull; and sudo systemctl daemon-reload; and sudo systemctl start backup-pull.timer
   ```

   Each is a new file. From the phone, `server-install-system-files.yml -l three -K` does the
   same installs.
3. **The first pull**, once `zero` has its first snapshot (`hosts/zero/system/README.md`
   § The backup). In the UK, over the LAN, with no rate limit, by a runtime drop-in that
   the next boot forgets:

   ```fish
   # pull setup 3, on three: lift the rate limit until the next boot, and start the first pull without waiting for it
   sudo mkdir -p /run/systemd/system/backup-pull.service.d; and printf '[Service]\nEnvironment=BACKUP_PULL_BWLIMIT=0\n' | sudo tee /run/systemd/system/backup-pull.service.d/lan.conf; and sudo systemctl daemon-reload; and sudo systemctl start --no-block backup-pull.service
   ```

   ```fish
   # pull setup 3, on three: follow the pull and its snapshot, then list three's snapshots
   journalctl -fu backup-pull -u backup-snapshot
   sudo snapper --no-dbus -c received-immich list
   ```

   The journal ends `pulled snapshot <N> of <time>`, rsync's statistics, and
   `snapshot taken of the pull of zero snapshot <N>`; the list shows one snapshot,
   `pulled <N>`. About 93 GB on 2026-11-02, so hours. If the session drops, the pull goes on.
   Before the box ships, remove the drop-in:
   `sudo rm /run/systemd/system/backup-pull.service.d/lan.conf; and sudo systemctl daemon-reload`.

**Checks:** each morning `journalctl -u backup-pull -u backup-snapshot --since yesterday`
reads a pull and a snapshot, or `nothing new`; `systemctl list-timers backup-pull.timer`
names the next 01:00 UTC. Nothing alerts when pulls stop; that waits on a fleet-wide dead
man's switch (`docs/management-plane.md`, phase table).

**Way back:** nothing on `zero` depends on `three`. Stop the timer and leave the array.

### Restore

A restore onto `zero` runs from `zero`, with its restore key
(`hosts/zero/system/README.md` § A restore), through the module `immich`. On `three` itself,
into a directory outside `immich`, with the owners and modes `zero` had, the pull's xattr
read back:

```fish
# on three: list three's snapshots, then restore Immich's library from snapshot N into /media/backup/restore; --fake-super reads the kept owners, -M--super writes them
sudo snapper --no-dbus -c received-immich list
sudo rsync -aHA --numeric-ids --fake-super -M--super --mkpath /media/backup/immich/current/.snapshots/N/snapshot/data/library/ /media/backup/restore/library/
```

Put a number from the list in place of `N`; its description, `pulled <M>`, names zero's
snapshot. No `-X`: as root on three, rsync would try to make each copy's SELinux label match
the source's, and SELinux refuses it; the owners and modes come from the kept xattr
without it. A database to look into is a reflink copy of that snapshot's `db`, which costs no
space, started in a throwaway Postgres container, whose entrypoint gives the files back to
its own user (§ Slice 4 in [`plans/visit-runbook.md`](../../../plans/visit-runbook.md)).
Never `btrfs property set ... ro false` on a snapshot: copy it.

## The fan

The Argon EON's fan has a controller on the Pi's own I2C bus, bus 1 at `0x1a`, which takes
one byte. On this EON only the bottom of its range changes the speed: 0 stops the fan, 1 to
5 are five audibly different speeds, and everything from about 6 up sounds the same as 100.
With nothing writing to it, the fan runs at full speed. Leap's image leaves that bus off, so
three files work together:

- `system/extraconfig.txt` turns the bus on, with `dtparam=i2c_arm=on`, on the FAT boot
  partition at `/boot/efi`. openSUSE's `config.txt` there ends with `include
  extraconfig.txt`; an update of the firmware package rewrites `config.txt` and leaves this
  file alone. The firmware reads it only at power-on, so it takes a reboot.
- `system/i2c-dev.conf` loads `i2c-dev`, which makes `/dev/i2c-1`.
- `system/argon-fan`, run by `system/argon-fan.service`, steps the fan through seven
  levels, 0, 1, 2, 3, 4, 5 and 100: silent with the CPU below 45 °C and the drive below
  45 °C, 5 by a CPU of 60 °C or a drive of 49 °C, and 100 at 65 °C or 50 °C. It steps up as
  soon as either temperature asks for more, and down only once both are a few degrees below
  the level's entry point. It reads the CPU every 30 seconds.
- It reads the drive with `smartctl` about every 3 minutes while the drive is reading or
  writing, and not at all while it is idle: the CPU's idle temperature then stands in for
  the room, and one read is taken if the CPU rises 3 °C above where it was at the last
  reading. A SMART read on an idle drive that still spins would reset its standby timer,
  should one ever be set; a WD Red ships with none, so it does not spin down today.
  `smartctl` never wakes a drive that has spun down. An idle drive keeps its last reading
  for as long as it stays idle. It finds the drive by the array's label, `backup-luks`;
  with the drive unplugged, it follows the CPU alone.
- A temperature it cannot read sets the fan to 100: the CPU's, a failed drive read, or a
  drive working for 6 minutes with no good read. So does a stop. Without the bus, it logs
  that and tries again every 30 seconds.

To change a level or a threshold, edit the numbers at the top of `system/argon-fan` and
commit. Then,
from the phone, and on `three`:

```fish
# on the phone: install the changed fan script on three; the first run shows it, the second installs it
cd ~/infra/ansible; and ansible-playbook playbooks/server-install-system-files.yml -l three -e only=argon-fan --check -K
ansible-playbook playbooks/server-install-system-files.yml -l three -e only=argon-fan -K
```

```fish
# on three: restart the fan's unit; the stop sets 100, the start picks the level again
sudo systemctl restart argon-fan.service
```

To check it:

```fish
# the fan's unit, then its log: each change of level with both temperatures and the reason,
# and the drive's readings when they move by 2 °C or more
systemctl status argon-fan.service
journalctl -b -u argon-fan.service
```

If the unit misbehaves, stop it, which sets 100, and set the fan by hand: 0 is off, 1 to 5
the quiet speeds, 100 full.

```fish
# stop the fan's unit, then write one byte to the controller, 3 here: 0 off, 1 to 5 quiet, 100 full
sudo systemctl stop argon-fan.service
sudo python3 -c 'import fcntl, os; f = os.open("/dev/i2c-1", os.O_RDWR); fcntl.ioctl(f, 0x0703, 0x1a); os.write(f, bytes([3]))'
```

## Before three ships

In the UK, `three` uses the static `.103`, which would also connect in Singapore and leave
no route out. So the last thing before the shipping power-off, after `ssh three`:

```fish
# Singapore: the static UK profile stops connecting, so the DHCP one takes over next boot
sudo nmcli connection modify wired connection.autoconnect no
# Wi-Fi only if Singapore has no Ethernet for it. The password is asked for and reaches the
# root-only profile on stdin, never on a command line, which sudo would log to the journal
read -s -P 'Wi-Fi password: ' psk; and printf '[connection]\nid=wifi\ntype=wifi\n\n[wifi]\nssid=%s\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' 'THE-SSID' $psk | sudo sh -c 'umask 077; cat > /etc/NetworkManager/system-connections/wifi.nmconnection'; and sudo nmcli connection reload; set -e psk
sudo systemctl poweroff
```

Put Singapore's network name in place of `THE-SSID`. The Wi-Fi lines are untested until
then, because the simulation has no radio.
The tracked `wired.nmconnection` then describes `three` as it was in the UK. Back in the UK,
`sudo nmcli connection modify wired connection.autoconnect yes` undoes the flip.
