# MicroOS at the November 2026 visit

A proposal from 2026-11-02. It moves `three` and `one` to openSUSE MicroOS at the visit,
and `zero` too if time allows. It also carries out [`three.md`](three.md). When the visit
has done it, the reasoning moves to [`docs/decisions.md`](../docs/decisions.md) and this
file is deleted.

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

| # | Slice | Hours | Ends with |
|---|---|---|---|
| 1 | Bench test: boot `three` on its MicroOS card before it joins the stack | 1 | `three` proven on its own hardware; the fleet untouched |
| 2 | `zero`'s disk swap, borrowing `one`'s Sabrent ([`three.md`](three.md)) | 2 | `zero` on the new disk, still on Alpine |
| 3 | `one`'s Sabrent and SSD to `three`; `one`'s apps up on `three` | 1.5 | the apps on `three` under Docker |
| 4 | `one`'s board into the Argon, on its MicroOS card; Syncthing paired | 1.5 | seeding over the LAN, unattended |
| 5 | `zero` on MicroOS, only if every gate holds | 3 | `zero` on MicroOS, or back on its Alpine card |
| | spare | 1 | |

Slice 5 runs only if slices 1 to 4 are done, at least 4 hours remain, at least one full
day remains before departure, and slice 2 has run for a day. The disk swap and the OS
change never share a day.

After the visit, over ssh: the dev hub moves to `three`, at a quiet time and not in a
slice, because the infra container moves with it. Podman comes later still.

## Before the visit

1. **One first-boot script per host.** MicroOS runs a Combustion script on its first boot.
   Each host's is a literal file under `hosts/<host>/`, reviewed like any boot-path file
   and not generated. It sets users, ssh keys, hostname and packages, makes the host's
   `/media/*` mountpoints, and carries no secret. It also turns automatic reboots off on
   every host with the two files the simulation proved, because nothing on this fleet
   restarts without the owner's say. The owner sets each host's policy later, over ssh.
2. **A carry-over step for what is not in git:** tunnel credentials
   (`/etc/cloudflared/<host>.json`), every deployment's `.env`, the dev containers'
   secrets directories on `zero`, `gavin`'s password hash and `authorized_keys`, and **the
   ssh host keys**, so every client's pinned `known_hosts` entry still matches. They
   travel on the Combustion USB stick itself. On the old Alpine system, the owner copies
   them into a `carry/` directory on the stick at mode 600, as root. The first-boot script
   installs them from there. The stick then holds live secrets: the owner keeps it with
   the other secret-bearing media and erases it with `blkdiscard` after the host is
   proven, not with a file delete, which flash keeps. One stick serves one host at a time.
3. **`three`'s tunnel and ssh alias, created over the phone before the visit.** Its
   hostname is `three.<dns_zone>`, derived as every alias is.
4. **Ansible for MicroOS.** Packages go through `transactional-update` and take effect at
   a reboot. systemd units replace the OpenRC pieces: `cloudflared`, `zram-swap`,
   `devpool` (a systemd slice), and the fstab entries with `nofail` and
   `RequiresMountsFor=`.
5. **A CI simulation on GitHub Actions.** The repo is public, so the runners are free. An
   x86_64 MicroOS VM under KVM tests the logic, because none of it depends on the CPU, and
   one aarch64 run checks that every package exists for the Pi. The VM boots from the
   first-boot script, runs the plays, brings up each deployment under Docker with dummy
   secrets, and reboots through `transactional-update`. Disks hot-added after boot test
   `nofail`, `RequiresMountsFor=` and the mount guards against late USB disks. bcache
   under btrfs RAID1 on virtual disks tests `zero`'s assembly.
6. **A runbook for the visit**, one section per slice, each with its checks and its
   rollback.

## What the simulation has answered

The simulations (`sim/microos/`, on the `microos-sim` branch until reviewed) ran on
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
  power cut included. **The owner decides per host** whether the daily update stays on
  with that meaning, or its timer is disabled so nothing changes until the owner runs it.
- **Every package exists for aarch64:** docker, docker-compose, cloudflared, bcache-tools,
  smartmontools, btrfsprogs, zram-generator and syncthing.
- **bcache needs no script.** The late-disks simulation built `zero`'s layout in miniature
  on three simulated USB disks: one bcache cache, two backing disks, btrfs RAID1 across
  the two bcache devices. Plugged in after boot, the disks were registered and attached by
  bcache-tools' own udev rule, and btrfs assembled the array. `bcache-register` and its
  hardcoded UUIDs are not carried to MicroOS.
- **Late disks: the result is not settled.** With the disks present at boot, or plugged in
  20 seconds after power-on, the array mounted at boot and a `RequiresMountsFor=` service
  ran without hands. 20 seconds is inside systemd's default 90 s device timeout, so the
  180 s `x-systemd.device-timeout=` that run also set was not what made it work. Plugged
  in after boot, the array at first stayed unmounted unless a udev rule added the mount to
  the array's `SYSTEMD_WANTS`. But once the stand-in service was also `WantedBy=` the
  mount unit, the array mounted by itself in the same late stage with no rule and no
  longer timeout, in two runs. Why that change matters is not understood, so the next runs
  separate the two cases before any fstab or udev setting is chosen.

- **Docker's store carries over in place.** Alpine 3.24's own Docker (29.9.2) made a store
  on btrfs with the containerd image store, as on the fleet: a pulled image, a locally
  made one, a named volume with data, and an exited container. MicroOS's Docker (29.7.2,
  containerd 2.4.2) took it over mounted as `/var/lib/docker` and listed all of it, but
  new containers failed with `exec ... permission denied` until one `restorecon -R
  /var/lib/docker`. After that the volume's data and the local image both read back. So
  `one`'s apps, `garmin-mcp`'s local build, and `zero`'s dev and pearl-wallet volumes can
  stay where they are. The relabel writes SELinux labels into the store. That Alpine's
  Docker then ignores them, so a rollback is unaffected, is expected and not yet tested.

- **A late array brings back only the containers that fail without it.** A container under
  Docker's own `restart: always`, as the fleet's stacks run, crash-looped while the bare
  mountpoint was empty and read-only, and its next restart after the mount came up on the
  array, because Docker binds a volume afresh at every start. That container exits when
  its file is missing. A service that starts cleanly on an empty directory, as Syncthing,
  Immich's server and qBittorrent may, keeps running against the bare mountpoint and never
  sees the array, because a later mount does not reach into a running container. Those
  stacks need a restart once their array mounts; how is open.
- **sudo asks for root's password.** MicroOS ships `Defaults targetpw` with `ALL ALL=(ALL)
  ALL`, and no `wheel` group. Each first-boot script adds a drop-in with both
  `Defaults:gavin !targetpw` and `gavin ALL=(ALL) ALL`, so `gavin` types his own password
  as on Alpine. That needs his password hash in the carry-over.
- **The owner's tools exist:** fish, htop, nano, curl, jq and git.

Still open: the late-disk result above, how a tolerant stack restarts once its array
mounts, the compose shapes the fleet's stacks use (a project network, a published port, a
shared network namespace; the first try failed on the test itself), and disks plugged
cache-last.


## Docs this changes

roadmap §3 (scheduled, with `one` and `three` first), `docs/host-setup.md` and
`docs/recovery.md` for systemd, every host README, and `README.md`'s host table.
