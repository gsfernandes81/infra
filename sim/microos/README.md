# Leap 16.1 simulation

This directory holds the CI simulations behind
[`plans/microos-cutover.md`](../../plans/microos-cutover.md). They answer, before the
November 2026 visit, the questions the plan cannot settle from documentation. They run
openSUSE Leap 16.1 in its Immutable mode, the fleet's chosen OS. They were written for
MicroOS, which shares its tooling, and still run it with `SIM_OS=microos` set; the
directory keeps its first name. Nothing here
runs on the fleet or reaches it, and nothing here is a host's first-boot script.

## The probe

`.github/workflows/microos-sim.yml` runs `run-probe.sh` on a GitHub runner with KVM. The
script downloads Leap 16.1's Immutable VM image for x86_64 and checks it against the
published checksum. It boots the image with a Combustion config drive built from
`probe/combustion/`, and runs `probe/checks.sh` over ssh. It then reboots the VM once and
checks again. The report records which image it tested, because the image changes.

The probe answers:

- whether SELinux enforces, and whether Docker refuses a bind mount from an unlabelled
  btrfs at `/media`, as every compose file here makes them, and whether `:z` fixes it;
- whether the read-only root refuses writes to a bare `/media` mountpoint, which would
  make it the mount guard `chattr +i` is on Alpine;
- which Docker and compose plugin openSUSE ships, and whether they start;
- whether upstream's Compose binary, pinned and installed in `/usr/local`, is the one Docker
  runs, builds through openSUSE's buildx, and is still there after a new snapshot boots;
- what reboot policy the image ships, and whether a first-boot setting of `strategy=off`
  survives a reboot;
- whether bcache-tools brings a udev rule that registers devices by itself;
- which of the packages a host needs exist;
- what Leap adds of its own: whether its first-boot wizard (`jeos-firstboot`) would have
  run, whether firewalld is on, which boot path health-checker sees, what sshd allows,
  and how much memory the image leaves.

Every first-boot script here masks `jeos-firstboot`, which waits at a console nobody
watches and powers the box off if it fails. A successful Combustion run already keeps it
away, by removing the file it waits for; the probe shows whether that happened.

A second job asks Leap 16.1's aarch64 repositories the same package question, because
Leap on a Pi installs from them. The Pi image itself is inspected by
`.github/workflows/pi-image.yml`, and the aarch64 pins are checked by
`.github/workflows/leap-pins.yml` ([`leap/README.md`](../../leap/README.md) § How it is
tested).

The run's ssh key is made fresh in the runner and dies with it. The job fails only when
the VM does not boot or answer ssh; every answer is in the job summary and in the
`microos-probe` artifact, with the VM's serial log.

## Late disks

`run-late-disks.sh` builds `zero`'s array in miniature on three simulated USB disks: one
bcache cache in front of two backing disks, and btrfs RAID1 on the two bcache devices,
mounted by an fstab entry with `nofail` and `context=`. A stand-in service needs the mount
through `RequiresMountsFor=`, and a container under `restart: always` bind-mounts it, as a
deployment would. The VM then boots without the disks, and `qmp.py` plugs them in through
qemu's QMP socket at chosen moments: after boot has given up on them, 120 s after power-on
with a 180 s device timeout, and after boot again with the cache last. Each stage reports
when the disks were plugged, how long the mount took, what bcache, systemd and Docker did,
and whether the bare mountpoint refused a write.

CI runs it three times, one variant each, so the effect of each setting stays separate:
`plain` adds nothing, `wantedby` makes the stand-in service wanted by the mount unit, and
`udev` adds a rule that asks systemd for the mount when the array's btrfs is ready.

## Docker's store

`run-docker-store.sh` asks whether MicroOS's Docker can take over the `/var/lib/docker`
that Alpine's Docker leaves on `one`'s SSD and `zero`'s `sda2`.
`docker-store/make-store.sh` runs Alpine 3.24's own Docker package in a privileged
container on the runner and leaves a store on a btrfs image: the containerd image store,
as on the fleet, with a pulled image, a named volume holding data, a locally made image
and an exited container. The VM mounts the image as `/var/lib/docker` and reports what it
can still use, first as the store arrives and then after `restorecon` labels it.

## Data mounts and health-checker

`run-health-mounts.sh` asks what stock `health-checker`, with no plugin of ours, does
about the fleet's data mounts. Its `btrfs-subvolumes-mounted` plugin fails the boot when
an fstab entry with a `subvol` option has a failed mount unit, and it ignores `nofail`. A
failure on an update's first boot rolls the update back; on a snapshot that has booted
fine, health-checker reboots once and then enters emergency mode, which stops sshd.

The VM carries one data disk with a btrfs subvolume, mounted three ways as the fleet's
fstabs do: `subvol=`, `subvolid=`, and neither. Each entry has `nofail` and the 180 s device
timeout the hosts will carry. The run reports, as ANSWER lines:

- which of the three entries the plugin's own `findmnt` selects;
- what a boot without the disk does on a good snapshot, and on an update's first boot;
- what a mount that fails at once (a subvolume that does not exist) does on a good
  snapshot, with the screens if the box stops answering.

Each answer carries its evidence: when health-checker gave its verdict, each mount's state
and result, and what the plugin says after the device timeout. A late disk's mount ends
inactive, not failed, and the verdict comes seconds into the boot, so a missing disk can
pass for a reason that says nothing about a disk that arrives and then fails to mount.

It reports and does not judge: the job fails only when the VM does not boot or answer ssh
before the stages begin. The report prints `health-checker`'s version and which of its two boot paths the image takes (legacy
GRUB or BLS), since they decide differently.

Not tested: a mount failing at once on an update's first boot, and a disk that arrives
during boot, inside the device timeout, which is the fleet's usual case.

## A host's first boot

`run-host.sh <workdir> <host>` boots the host's real first-boot script
(`hosts/<host>/leap/combustion/script`, [`leap/README.md`](../../leap/README.md)) from a
stick laid out as `leap/make-stick` lays it out. The carry-over is made up for the run: a
fresh ssh host key, password hashes for a password only the run knows, the run's key as
gavin's, stand-in tunnel credentials, `.env` files and volumes. `host/<host>.sh` gives a
stand-in for each `FILL-FROM-` placeholder still in the host's files, and makes the host's
disks: for `one`, a btrfs SSD with one's filesystem UUID and its subvolumes in the order
that gives the fstab's ids, and a swap disk with its UUID, both on USB; for `three`, a
blank drive. The VM sits on the host's own subnet, so its static address answers. A host
with no tunnel config yet is new, and its stick is `make-stick --new`'s: no tunnel
credentials, `.env`, secrets or volumes.

The run then checks, each as PASS or FAIL, and any FAIL fails the job:

- from outside: the host key is the carried one, sshd offers public keys only, root is
  refused over ssh even with a valid key in its `authorized_keys`, by `PermitRootLogin` as
  sshd's own log says, and root logs in on the serial console with its password;
- on the box (`host/checks.sh`, with `host/checks-<host>.sh` appended): the static address, SELinux, gavin's uid, shell and sudo,
  root's password, sshd's settings, every data mount by `subvolid=`, swap, the read-only
  bare `/media`, on `one` Docker on its new store on the SSD with a fresh pull and a read
  through the `context=` mount, upstream's Compose, the pinned `cloudflared` and its ingress,
  `tailscaled` from Tailscale's repository, the update timer, the reboot strategy, the
  checkout, and the carry-over's files and modes;
- the deploy play: `server-deploy-compose.yml --check` for each of the host's deployments,
  from the runner as the control node, logged in as gavin with his sudo password, after the
  box's checkout is put on the commit under test. Each must plan, and no log may hold the
  password. The stand-in `.env` files carry every name each `compose.yaml` requires. Only
  `--check`: a real `up` needs each cloudflared sidecar's tunnel to connect, which a
  stand-in cannot. Each deployment's images are pulled on the box first, so the plan
  reaches Compose's dry run; a built image, or one that will not pull on this x86 VM,
  stops that deployment's plan before it, and the report says which. The plans cover
  what a deployment's `compose.yaml` and `.env` names say, not what an `env_file:` holds:
  torrents' stand-in has none of gluetun's VPN settings, which only `up` reads. The box's
  checkout is put on exactly the commit under test, a pull request's merge commit
  included, and in CI a stage that cannot run fails;
- on `three`, after that first look: the array locked as every boot leaves it, with nothing
  waiting at a passphrase prompt and Docker skipped by its condition, and the fan's unit
  running while it waits for an I2C bus the VM does not have, later finding the array's
  drive by its LUKS label; then the visit's next
  steps, as `host/three.sh` gives them. A stand-in tunnel goes in as
  `server-create-host-tunnel.yml` and `install-system-file` would leave it, and
  `cloudflared` starts. `make-backup`, the copy under test, formats the blank drive and
  refuses it a second time. The README's unlock command runs over `ssh -tt`, and
  `host/unlock.py` answers sudo's prompt and systemd's passphrase prompt as the owner
  would. `host/three-unlocked.sh` then checks the array is LUKS2 with Adiantum, mounted
  with the container context, `nosuid` and `nodev`, labelled `backup`, holding
  `make-backup`'s layout and nothing else at its top, that
  the mount started Docker and the pull and scrub timers, that a container reads and
  writes it, and a scrub. After the reboot, the array is locked again, and on the new box
  `server-unlock-arrays.yml` brings it back (below; the migrated box uses the README's
  command again);
- on `three`, after the reboot, the unlock play, from the runner as the control node, in a
  terminal, with `host/play-prompts.py` typing at its prompts (`sim_unlock_play` in
  `host/three.sh`). Its inventory adds `three-b`, the same VM under another name listing a
  second volume made for the run, `simextra`, on a loop device with its own crypttab and
  fstab lines, and `sim-gone`, which nothing answers. `--check` asks nothing and leaves the
  array locked. The first run asks once for each locked volume, across both hosts, gets the
  array's passphrase and a wrong one for `simextra`: the array is mounted `nosuid` and
  `nodev` with `systemd-cryptsetup@backup.service` active, `simextra` is reported wrong and
  left locked with its unit neither active nor failed and nothing waiting, `sim-gone` is
  reported unreachable, and the play ends failed. The second, with the array open and Enter
  alone for `simextra`, asks only for `simextra`, reports the array already open and
  `simextra` left locked by you, and passes. Then the README's lock command, read out of
  the README, prints `locked` and stops Docker, and a third run unlocks both. No run's
  output may hold a passphrase or the sudo password. `simextra` is removed after, and
  crypttab and fstab put back;
- on `three`, zero's backup, pulled from the runner standing in for `zero`
  (`sim_backup` in `host/three.sh`, with `host/three-backup.sh` on the box), below.
- on `three`, in the second job (`SIM_VARIANT=migrate`), in place of `make-backup` and the
  pull: the rename of the array made on 2026-11-18 (`hosts/three/leap/README.md` § The
  rename). The box is first set back to that day's: the files of the tree before the pull
  (`old_commit` in `host/three.sh`, fetched by its sha) in place of the new ones, the old
  fstab line, the old users, and a snapshot swapping `/media/backup` for `/media/mirror`,
  then a reboot. The old `make-mirror` formats the drive, the old command unlocks it, the old
  timer's service and a hand snapshot leave two read-only snapshots of the empty `incoming`,
  and the old `syncthing-three` runs on it and is given data. Then each of the README's fish
  blocks runs as written, through fish as gavin, with a sudoers drop-in standing in for his
  password until the rename ends, and `host/three-migrate.sh` reads what each left: rename 3
  refusing with a file in `incoming` and again once `immich` exists, deleting nothing either
  time; the layout; both labels; the header backup at 600; the fstab line whole, its
  SELinux label as the policy wants, and rename 7 refusing a second run; the units, the old
  ones gone and their copies kept with their modes; the users; the fan finding the drive by
  `backup-luks`; the new snapshot with `/media/backup`; the boot into it; the unlock under
  the new names; Syncthing's subvolume with the same UUID and every path, size and content
  it had; Syncthing recreated on `/media/backup/syncthing`, healthy; the clean-up; and the
  pull's setup, step 2, with the run's stand-ins for `zero`'s values. Then the same checks a
  new array gets. Not run: rename 14 and 16 are the phone's (the unlock is typed by
  `host/unlock.py`, the command checked word for word against the README's; the deploy
  play's `up` is stood in for by `docker compose up -d`, the play being checked in
  `--check` by the deploy stage), and the pull itself, which the first job proves.
- in rescue mode (`host/rescue.sh`), entered with `systemctl isolate`: gavin logs in, and
  sshd, the network, `cloudflared`, `tailscaled` and logins are up while Docker is down;
- after a reboot, proved by a new boot id, the box checks again on its static address;
- the update play, `server-update-leap.yml`, run for real: both pinned binaries are first
  swapped for stand-ins, so the run shows each moved to its pin with the stand-in kept as
  the previous (`host/update-checks.sh`); the box rebooted; a login shows the update
  recipes; and, on `three`, the play ends with the unlock command. `-e ways_in_check=false`
  skips the two checks a simulation cannot pass, the tunnel's ready connections and the
  tailnet, and the report says so.

When gavin cannot log in, the run logs in as root on the serial console
(`serial-login.py`), or uses the initramfs's emergency shell if the boot stopped there,
and prints what the box knows about why.

The stand-in tunnel credentials cannot connect, so the run shows `cloudflared` installed,
enabled and retrying, not serving.

### `three`'s pull, from a stand-in for `zero`

The runner plays `zero` after the move: a 2 GB btrfs on a loop file with the subvolume
`immich` mounted on its own, holding `data/` (with `thumbs` and `encoded-video` as nested
subvolumes, a symlink, a file owned by 1000:1000 at 640) and `db/`, where a Postgres
container keeps writing, and `.snapshots`, a subvolume, root's, 750. `zero` itself is an
Alpine container of `zero`'s release (the digest in `sim/alpine/host/Dockerfile`),
privileged, on the runner's network, with that mount at `/media/immich`. It is set up as
`hosts/zero/system/README.md` § The backup has the owner set up `zero`: snapper 0.13.1 from
edge/testing (x86_64 here; `alpine-sim.yml` checks the README's aarch64 SHA-256), util-linux's
`setpriv`, Alpine's sudo and rsync, the `backup` user made with BusyBox's `adduser`, and
`zero`'s tracked files at their headers' paths, sudoers through `visudo`. Its sshd answers on
the runner's port 22, which the VM reaches at qemu's host address, the address `three`'s
tracked ssh config is given in place of `zero`'s; the run's stand-ins replace `zero`'s host
key, its restore key and the two `from=` addresses. Its snapshots are the tracked hourly
script's, run by hand. `three` makes its pull key as its README says, and its public half
goes into the stand-in's key line.

Each numbered point is the design's (`plans/three-backup-pull.md`), with how it is shown:

1. **A full pull.** `backup-pull.service`, started as the timer would, under the README's
   runtime drop-in that lifts the rate limit. `tree-hash.sh` hashes every path, owner,
   mode, size and content of `zero`'s snapshot on the runner, and of `three`'s snapshot of
   its copy read back through `--fake-super`; the two must match. `thumbs` and
   `encoded-video` must be empty directories, `current/.snapshots` must hold only
   `three`'s own numbered snapshots, a file's owner must sit in `user.rsync.%stat` while
   the file on disk is the backup user's, and the symlink must lead nowhere: rsync keeps it
   as a plain file whose xattr records a link (or, from an rsync that stores links, a link
   to `/rsyncd-munged/a.jpg`).
2. **Snapshots only after a good pull.** After each pull the count of `three`'s snapshots
   must rise by one, described `pulled <N>`, and `last-pulled` name `<N>`; a pull with
   nothing new must end `nothing new` with no snapshot (the snapshot unit skipped by its
   condition). Then a pull of a 24 MB file at 256 KiB/s is cut by killing `zero`'s daemon
   once the file has begun to arrive: the service must fail, with no new snapshot,
   `last-pulled` unchanged and `state/pulled` gone. The next pull must succeed.
3. **A second pull copies only changes.** A file added and one deleted on `zero`: the new
   one must arrive, the deleted one leave `current/` and stay in `three`'s first snapshot,
   and an unchanged 8 MB file keep its inode and ctime, so it was not written again.
4. **Least privilege.** As the backup user, with its own key and config: a command, sftp,
   an upload, a `--delete` into the module, a path climbing out with `..`, another module
   and a port forward must each get nothing. On the stand-in, `sudo -l -U backup` must allow
   exactly the forced command and refuse another config, another user and a shell; and
   mid-transfer, the daemon's `/proc/<pid>/status` must read zero's backup user's uid and
   `0x4` (`CAP_DAC_READ_SEARCH`) as its permitted, effective and ambient sets.
5. **A locked array skips the pull.** After the README's lock, a start of the pull must be
   skipped by its condition, not failed, with the timer stopped; the unlock must start the
   timer, calendared `01:00:00 UTC`, and the next pull succeed.
6. **Cleanup keeps the newest.** On each side every snapshot is dated a day apart at noon,
   the newest yesterday, and the limits lowered: `zero` hourly 1 and daily 2, `three` daily
   2 with no weekly or monthly. Then `zero`'s hourly script and `three`'s snapshot unit,
   each of which takes a snapshot and cleans up, must leave exactly two: the one taken now
   and yesterday's.
7. **`--delete` never touches `three`'s `.snapshots`.** `zero`'s snapshot holds an empty
   `.snapshots`, which `--delete` would mirror over `three`'s. A dry run as root without
   the filters must show rsync deleting inside it (the calibration; the backup user cannot
   enter it), and every pull must keep every earlier snapshot.
8. **Exit 24 is a failure.** A btrfs snapshot never loses a file, not even when snapper
   deletes it mid-pull (an earlier run did, and the pull finished whole), so a plain
   directory stands in for the newest snapshot: a slow pull of a 24 MB file in its last
   directory, and once it has begun, the three files after it are removed. The service
   must fail with status 24, with no snapshot and `last-pulled` unchanged.
9. **The restore module.** From the stand-in, as root with the restore key, a checksum dry
   run of `three`'s snapshot against `zero`'s through the module must print nothing:
   contents, owners, modes, times and the symlink's real target. A real restore must write
   1000:1000 640 and Postgres's 70:70 700, and the symlink pointing at `a.jpg`; during it,
   the restore daemon on `three` must hold only `0x4`. The key must run no command, an upload
   be refused as read only, and nothing outside the module be read. The module, `immich`,
   must list `current`, `state` and `last-pulled` alone, and a path through `..` must not
   reach `three`'s Syncthing beside it on the array; `sudo -l -U restore` must allow exactly
   its command.
10. **A database restore.** A reflink copy of `db` from `three`'s newest snapshot, in a
    throwaway Postgres on `three`, must log an automatic recovery, accept connections, and
    return all 100 rows written before the snapshots began; the snapshot stays read-only.

The rate limit is lifted for every pull but the two cut ones, which set 256 KiB/s by a
second runtime drop-in.

## Traps the simulation found, each handled in the code

Kept here for whoever changes a first boot or the harness next.

- Combustion copies only the stick's `combustion/` directory and runs the script from the
  copy; the stick is unmounted by then.
- The script runs inside `transactional-update shell`, which binds `/root` and some of
  `/var`, not `/home` or `/usr/local`: `leap/firstboot.sh` mounts them and labels what it
  wrote (`setfiles`), since SELinux's policy is not loaded yet.
- The `--prepare` stage runs in the initramfs, with no `install`; it puts the host's network
  profile in place so the first boot already has the static address.
- systemd applies presets on a first boot, so a `disable` is undone: mask instead.
- Leap's sshd uses PAM: `KbdInteractiveAuthentication no` as well as `PasswordAuthentication
  no`. Leap ships its own `tailscale`: Tailscale's repo has priority 90 and is added before
  any package installs.
- The SSD's subvolumes share one superblock, so every mount of it carries the same
  `context=`, Docker's store included; mixed options are refused at random.
- `gavin`'s login shell is fish: anything the harness sends over ssh goes to `bash -s` on
  stdin. The harness runs under `set -euo pipefail`; a bare `rc=$?` after a failing command,
  or a `grep` with no match inside `$(…)` or a pipeline, ends the run silently.
- The repo's Ansible callback hides skipped tasks entirely; read the play's own sentences.
- openSUSE's `import-pubring-from-rpmdb.service` (microos-tools, bsc#1245786, fixed upstream,
  not yet in Leap 16.1) sometimes fails on a first boot that brings a new rpm key, after
  importing every key: it is harmless, delays `multi-user.target` about 90 s, and the sim
  reports it as KNOWN.

## Working with CI

`.github/workflows/microos-sim.yml` runs on a push touching `sim/microos/`, `leap/`,
`hosts/*/leap/` or what the deploy play reads. The `host` job takes about 30 minutes; its
report is the job summary and the `leap-host-<host>` artifact. Runs queue per branch and the
hub's token cannot cancel one, so iterate on a branch and merge when green. When the guest
cannot be reached, the harness logs in as root on the serial console and prints why. Use
`claude-sessions keepalive` while waiting. A Fable review comes before every merge.

## What a green run does not show

The simulations run on x86_64 under KVM, not on a Pi; the USB disks are qemu's. It does
not exercise USB bridges, real disks, Cloudflare, or any host's own first-boot script.
Those come in later simulations or on the bench at the visit.

## Running it elsewhere

`run-probe.sh`, `run-late-disks.sh` (with a variant), `run-docker-store.sh`,
`run-health-mounts.sh` and `run-host.sh` (with a host), each given a work directory, run
on any Linux machine with KVM, `qemu-system-x86_64`, `qemu-img`, `mke2fs` and an ssh
client. `run-docker-store.sh` also needs Docker, btrfs-progs and sudo for one loop mount,
and `run-host.sh` needs btrfs-progs, openssl and sudo for one loop mount, and
`ansible-playbook` with `ansible/requirements.yml`'s collections for its deploy stage; for `three`,
Docker, a loop device and two mounts under sudo, and the runner's port 22, whose own sshd it
stops if one holds it. Each writes only
inside its work directory. Do not run them in the `infra` container: that container is on
`zero`, has no KVM, and would compete with Immich.
