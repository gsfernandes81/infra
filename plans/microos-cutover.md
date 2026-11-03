# MicroOS at the November 2026 visit

A proposal from 2026-11-02, revised 2026-11-03. It moves `one` and `three` to a new OS at
the visit and carries out [`three.md`](three.md); `zero` stays on Alpine. The OS is
openSUSE Leap 16.1 in its Immutable mode, decided 2026-11-03 (`decisions.md`), with `two`
on Alpine. This file still says MicroOS where the simulations ran MicroOS. When the visit has done
it, the reasoning moves to [`docs/decisions.md`](../docs/decisions.md) and this file is
deleted.

## The constraint

The owner is at the cluster for one visit. It starts between 12 and 16 November and ends
on 21 November, and it leaves about 10 hours in slices between other duties. Everything
that does not need hands is done before the visit or over ssh after it.

**Every slice ends with the fleet working.** A duty can interrupt between any two slices.

**Every OS change goes onto a new SD card.** The Alpine card stays untouched, so putting
it back undoes the change in a minute.

**MicroOS runs Docker at first**, the owner's call of 2026-11-02 (`decisions.md`). The OS
is the only change that needs the owner in person; podman (Phase 7) follows over ssh.

## The slices

Names follow the SD cards (`three.md`): the 8 GB board becomes `one`, and the 1 GB board
that is `one` today becomes `three`.

| # | Slice | Hours | Ends with |
|---|---|---|---|
| 1 | Bench test: boot the 8 GB board on `one`'s new card before it joins the stack | 1 | the new OS proven on that board; the fleet untouched |
| 2 | `zero`'s disk swap, borrowing `one`'s Sabrent ([`three.md`](three.md)) | 2 | `zero` on the new disk, still on Alpine |
| 3 | `one` moves to the 8 GB board, with its Sabrent, SSD and new card; its apps up under Docker | 1.5 | `one` serving from the new board |
| 4 | The 1 GB board into the Argon as `three`, on its new card, with the first WD Red under LUKS; `zero` and `three` on the tailnet; the first backup | 2 | seeding over the LAN, unattended |
| 5 | A restore from one of `three`'s snapshots; Syncthing on `three` if its memory allows | 1 | the backup proven |
| | spare | 2.5 | |

Slice 3's rollback is the old board with the Alpine card, so slice 4 waits until slice 3
has run for a day. The disk swap and `one`'s move never share a day.

**`zero` stays on Alpine this visit**, the owner's call of 2026-11-03. The disk swap is
its only change. It moves to the new OS only once that OS has been proven on a Pi 5,
because it is the box whose failure costs most, and slice 1 proves a Pi 4.

After the visit, over ssh: the dev hub moves to `one`, at a quiet time and not in a slice,
because the infra container moves with it. Podman comes later still. `three` ships to
Singapore at a date the owner picks.

## Before the visit

1. **One first-boot script per host,** at `hosts/<host>/microos/combustion/script`.
   MicroOS runs it once, at first boot. It is reviewed like any boot-path file and not
   generated, and carries no secret. It:
   - sets users, `gavin`'s sudo drop-in, ssh keys (none for root), hostname, the root
     password from the carry-over, and packages;
   - makes the host's `/media/*` mountpoints and appends its fstab fragment;
   - installs Cloudflare's `cloudflared` binary at a version and SHA-256 the script
     pins, with its unit, and Tailscale from its repo;
   - disables `transactional-update.timer` and sets the two reboot files, because nothing
     on this fleet restarts without the owner's say.

A simulation boots each script before the visit, and checks among other things that an ssh
login as root is refused with a valid key in place.
2. **A carry-over step for what is not in git:** tunnel credentials
   (`/etc/cloudflared/<host>.json`), every deployment's `.env`, the dev containers'
   secrets directories on `zero`, `gavin`'s password hash and `authorized_keys`, root's
   password hash, and **the ssh host keys**, so every client's pinned `known_hosts` entry
   still matches. They travel on the Combustion USB stick itself. On the old Alpine
   system, the owner copies them into a `carry/` directory on the stick at mode 600, as
   root. The first-boot script installs them from there. The stick then holds live
   secrets: the owner keeps it with the other secret-bearing media and erases it with
   `blkdiscard` after the host is proven, not with a file delete, which flash keeps. One
   stick serves one host at a time.
3. **`three`'s tunnel and ssh alias, created over the phone before the visit.** Its
   hostname is `three.<dns_zone>`, derived as every alias is.
4. **Ansible for MicroOS.** Packages go through `transactional-update` and take effect at
   a reboot. One play per OS runs the owner's update on one host: it updates, reboots, and
   reports done only once the box answers over each of its ways in
   ([`decisions.md`](../docs/decisions.md) § *Updates are by hand on every host*). systemd
   units replace the OpenRC pieces: `cloudflared`, `zram-swap`, `devpool` (a systemd
   slice), and the fstab entries with `nofail` and `RequiresMountsFor=`.
5. **A CI simulation on GitHub Actions.** The repo is public, so the runners are free. An
   x86_64 MicroOS VM under KVM tests the logic, because none of it depends on the CPU, and
   one aarch64 run checks that every package exists for the Pi. The VM boots from the
   first-boot script, runs the plays, brings up each deployment under Docker with dummy
   secrets, and reboots through `transactional-update`. Disks hot-added after boot test
   `nofail`, `RequiresMountsFor=` and the mount guards against late USB disks. bcache
   under btrfs RAID1 on virtual disks tests `zero`'s assembly.
6. **The backup's pieces, as tracked files:** `three`'s `backup` user and its one
   `authorized_keys` line, the snapshot timer that skips a running rsync, the LUKS unlock
   command, and `zero`'s cron job and backup-age check ([`three.md`](three.md)). The
   simulation checks that the key cannot open a shell, read a file, or write outside
   `incoming`, and that a run against a locked volume fails cleanly and the next succeeds.
7. **A runbook for the visit**, one section per slice, each with its checks and its
   rollback.

## What the simulation has answered

**On Leap 16.1, 2026-11-03.** Every job reran on Leap 16.1's own Immutable VM image
(Build 3.13) and answered as below for MicroOS, except where a point says otherwise:
health-checker's rollback, its mount plugin and the strand, late disks, SELinux, the
read-only root, the reboot files and the packages. What only Leap showed:

- **Docker cannot take over Alpine's store; it starts on an empty one.** After
  `restorecon`, every new container died at its first exec (exit 139), even from an image
  pulled fresh, and the audit log said why: the store's layers carry
  `container_var_lib_t`, which Leap's policy does not let a container read. MicroOS's
  policy labelled the same store correctly. A store Leap's Docker makes itself works, as
  the probe's compose stack did. So each host's Docker on Leap gets a new, empty store:
  on `one` a new subvolume beside `var-lib-docker`, which stays as it is for the Alpine
  card. Images are pulled or rebuilt. Named volumes, which live in the store
  (`garmin-tokens` on `one`, and the dev hub's when it moves), go across as tar files.
- **The first-boot wizard does not run.** `jeos-firstboot` waits for a file that a
  successful Combustion run deletes; the scripts mask it as well, because it powers the
  box off when it fails.
- **firewalld is on**, allowing ssh and DHCPv6. Ports published on `127.0.0.1` and
  outbound tunnels are unaffected; Tailscale under it is a bench check.
- **sshd allows passwords by default** (`passwordauthentication yes`); the hosts'
  `sshd-infra.conf` turns that off, and the first-boot simulation is to prove it.
- **Docker 29.4 and Compose 2.33.1**, older than MicroOS's 29.7 and 5.6. The fleet's
  compose files want a `docker compose config` check under 2.33 before the visit.
- **About 650 MB in use** with Docker running, which matters on `three`'s 1 GB.

**On MicroOS, 2026-11-02:**

The simulations (`sim/microos/`, run by `.github/workflows/microos-sim.yml`) ran on
2026-11-02 against MicroOS 20261030, kernel 7.3, Docker 29.7.2 and Compose 5.6.1. They run
on x86_64 under KVM, with qemu's USB disks and small loop-mounted filesystems. None of it
shows how a Pi, a Sabrent or Argon bridge, or a full-size array behaves; slice 1's bench
test and the visit's own checks do that.

- **SELinux refuses the compose files as they are.** It enforces, and openSUSE's Docker
  runs with SELinux on. A container could not read a file on a freshly made, unlabelled
  btrfs, which is what the fleet's Alpine-made data looks like. **The fix is one mount
  option:** `context=system_u:object_r:container_file_t:s0` on each `/media/*` entry in
  fstab. With it the container read and wrote, and the same disk mounted without it showed
  nothing had been written to it, so an Alpine rollback finds the disks as they were. The
  compose files keep their mounts. `:z` in the compose files and `chcon` both work too,
  but both write labels into the data disks, and `:z` relabels at every container
  creation. `semanage` is not installed.
- **The read-only root is the mount guard.** With nothing mounted on `/media/simtest`, a
  root `touch` and a container's write both failed with `Read-only file system`. A
  mountpoint exists only if a snapshot made it, so each host's first-boot script makes its
  `/media/*` directories. `chattr +i` is not needed on MicroOS.
- **Automatic reboots are off with two files.** `/etc/rebootmgr/rebootmgr.conf` with
  `strategy=off` held across a reboot; `/etc/rebootmgr.conf` is ignored. And
  `/etc/transactional-update.conf` with `REBOOT_METHOD=none` stops the daily update
  rebooting: run in the VM, it built a new snapshot, logged *Reboots are disabled*, and
  the VM stayed up. Both files were set together, so the run shows them sufficient
  together, not each alone. The update then takes effect at the next boot of any kind, a
  power cut included, which is why the owner chose to disable the timer instead.
- **Every package exists for aarch64:** docker, docker-compose, cloudflared, bcache-tools,
  smartmontools, btrfsprogs, zram-generator and syncthing.
- **bcache needs no script.** The late-disks simulation built `zero`'s layout in miniature
  on three simulated USB disks: one bcache cache, two backing disks, btrfs RAID1 across
  the two bcache devices. Plugged in after boot, the disks were registered and attached by
  bcache-tools' own udev rule, and btrfs assembled the array. `bcache-register` and its
  hardcoded UUIDs are not carried to MicroOS.
- **Late disks: a udev rule mounts the array, and a unit wanted by the mount restarts what
  needs it.** The late-disks job ran three variants side by side on 2026-11-02, each
  booting without the disks and plugging them in at set moments. The table below has the
  results. The 120 s plug is past systemd's default 90 s device timeout and inside the 180
  seconds set by `x-systemd.device-timeout=`, so the longer timeout is what let a slow
  array mount at boot. bcache assembled whichever disk came first. Why a unit wanted by
  the mount also makes the mount start is not understood, so the hosts use both: the udev
  rule for the mount, whose mechanism is documented, and a unit wanted by the mount that
  restarts the stacks on that array.

| Variant | Plugged after boot | After boot, cache last | At 120 s, 180 s timeout |
|---|---|---|---|
| nothing added | stays unmounted | stays unmounted | mounted at boot, service ran |
| service also `WantedBy=` the mount | mounted in 2 s, service ran | the same | the same |
| udev rule adds the mount to `SYSTEMD_WANTS` | mounted in 2 s, service not started | the same | the same |

- **A late array brings back only the containers that fail without it.** A container under
  Docker's own `restart: always`, as the fleet's stacks run, crash-looped while the bare
  mountpoint was empty and read-only, and its next restart after the mount came up on the
  array, in every variant, because Docker binds a volume afresh at every start. That
  container exits when its file is missing. A service that starts cleanly on an empty
  directory, as Syncthing, Immich's server and qBittorrent may, keeps running against the
  bare mountpoint and never sees the array, because a later mount does not reach into a
  running container. The restart unit above is for those.
- **sudo asks for root's password.** MicroOS ships `Defaults targetpw` with `ALL ALL=(ALL)
  ALL`, and no `wheel` group. Each first-boot script adds a drop-in with both
  `Defaults:gavin !targetpw` and `gavin ALL=(ALL) ALL`, so `gavin` types his own password
  as on Alpine. That needs his password hash in the carry-over.
- **The owner's tools exist:** fish, htop, nano, curl, jq and git.

- **The fleet's compose shapes work.** A stack with a project network, a port published on
  `127.0.0.1` and a service sharing another's network namespace, as qBittorrent shares
  gluetun's, came up: the port answered from the host, a service reached another by name,
  and the namespace-sharing one reached it on `127.0.0.1`.

- **A bad update rolls itself back, and a good box is never stranded.** The rollback
  simulation broke a stand-in for `cloudflared` inside an update: the box booted the new
  snapshot once, the plugin failed, and health-checker returned it to the previous one. A
  good update stayed. With the plugin's guard, a check failing on a snapshot that had
  already passed left the box up. Every stage asserts its outcome. Keeping a way in
  through emergency mode was also proven, and dropped (`decisions.md` § *Emergency mode on
  a MicroOS host keeps a way in*).
- **openSUSE's `cloudflared` package ships no systemd unit,** prints an empty version, and
  cannot update itself (`read-only file system`), which is the safe failure. Each host's
  unit is its own tracked file, and its config sets `no-autoupdate: true`. `cloudflared
  tunnel ingress validate` works offline and fails a bad rule, so the plugin can use it.
- **health-checker could not clear its GRUB flag** in this image (`grub2-editenv: cannot
  open /boot/grub2/grubenv: Read-only file system`). GRUB uses that flag to fall back
  after a boot that never reached userspace, a kernel panic for one, so that fallback may
  not work. The Pi boots differently; slice 1's bench test checks it there.
- **A data mount that fails outright strands a box, through stock health-checker alone.**
  The health-mounts simulation (2026-11-03) added an fstab entry with `nofail` and a
  `subvol=` that did not exist, on a snapshot that had booted fine. The mount failed at
  5.6 s, health-checker's own `btrfs-subvolumes-mounted` plugin failed at 6.6 s and
  rebooted the box, and the second boot went to the emergency shell, which stops sshd.
  `nofail` does not help. The plugin selects only entries carrying `subvol=`: one with
  `subvolid=` alone, or with no subvolume option, was never looked at. A disk that is
  missing or late never trips it either, because its mount ends inactive, not failed, and
  health-checker had already passed at about 7 s. So on an openSUSE host a data mount
  names its subvolume by `subvolid=`, as `zero`'s fstab already does; `one`'s calibre and
  Docker entries use `subvol=` and change at the move. This leans on how the plugin's
  `findmnt` matches today, so the simulation stays in CI to catch a change.
- **With root locked, the console is dead in emergency mode.** `sulogin` refuses a locked
  root, which is why each host gets a root password (`decisions.md`).

Still open:

- **The GRUB fallback on a Pi**, which slice 1 checks.
- **Locking the Pi's boot firmware** on an openSUSE host (`zypper addlock u-boot-rpiarm64
  'raspberrypi-firmware*'`). U-Boot and the firmware live on the FAT boot partition,
  outside every snapshot, so a rollback cannot undo them, and updates to them broke Pi 4
  boot four times between 2020 and 2025. Locked, they change only when the owner unlocks
  them deliberately.

## Decided, 2026-11-02

The owner settled the open calls on 2026-11-02.

1. **No automatic updates.** `transactional-update.timer` is disabled on every MicroOS
   host; the owner runs updates and the reboot over ssh
   ([`decisions.md`](../docs/decisions.md) § *MicroOS hosts take openSUSE's cloudflared*).
2. **openSUSE's `cloudflared`.** The `health-checker` plugin that was to roll a bad update
   back was dropped on 2026-11-03. Research found no other documented mechanism on
   openSUSE; Fedora IoT's greenboot is that OS's own, so it is part of the OS choice.
3. **Syncthing on `one` runs under compose,** as on `zero`. Every service stays in a
   container.
4. **Each host's first-boot files** live at `hosts/<host>/microos/combustion/script`,
   beside an fstab fragment the script appends to the image's own `/etc/fstab`, since
   MicroOS writes its root entries at install.
5. **`three`'s tunnel** comes from a new play for a host that has none. The simulation
   tests it against a stand-in for Cloudflare's API, so no account is needed, and Fable
   reviews it adversarially.

## Decided, 2026-11-03

1. **Names follow the SD cards**, and `zero` stays on Alpine this visit (*The slices*).
2. **Updates are by hand on every host, as a habit** (`decisions.md`).
3. **`three`'s backup is rsync pushed from `zero`, with snapshots on `three`, and its
   array is LUKS, unlocked by hand** (`decisions.md`, [`three.md`](three.md)).
4. **`three` also runs Syncthing for access from Asia**, deferred if its memory proves
   short ([`three.md`](three.md)).
5. **Leap 16.1 in its Immutable mode on `zero`, `one` and `three`; Alpine on `two`, and
   as the fallback** (`decisions.md`).
6. **Two ways into every box: Cloudflare's own `cloudflared` binary and Tailscale from
   its own repo**, neither through a container runtime; Tailscale is the phone's
   emergency way in (`decisions.md`).

## Docs this changes

roadmap §3 (scheduled, with `one` and `three` first, `zero` after a Pi 5 is proven),
`docs/host-setup.md` and `docs/recovery.md` for systemd, every host README, and
`README.md`'s host table.
