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

1. **One first-boot script per host,** at `hosts/<host>/microos/combustion/script`.
   MicroOS runs it once, at first boot. It is reviewed like any boot-path file and not
   generated, and carries no secret. It:
   - sets users, `gavin`'s sudo drop-in, ssh keys (none for root), hostname, the root
     password from the carry-over, and packages;
   - makes the host's `/media/*` mountpoints and appends its fstab fragment;
   - installs the `cloudflared` unit and the guarded health-check plugin in
     `/usr/libexec/health-checker/`;
   - gives the kept units their emergency drop-ins;
   - disables `transactional-update.timer` and sets the two reboot files, because nothing
     on this fleet restarts without the owner's say.

   A simulation boots each script before the visit, and checks among other things that an
   ssh login as root is refused with a valid key in place.
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
  already passed left the box up. Forced into emergency mode, it still answered ssh, with
  the kept units active ([`decisions.md`](../docs/decisions.md) § *Emergency mode on a
  MicroOS host keeps a way in*).
- **openSUSE's `cloudflared` package ships no systemd unit,** prints an empty version, and
  cannot update itself (`read-only file system`), which is the safe failure. Each host's
  unit is its own tracked file, and its config sets `no-autoupdate: true`. `cloudflared
  tunnel ingress validate` works offline and fails a bad rule, so the plugin can use it.
- **health-checker could not clear its GRUB flag** in this image (`grub2-editenv: cannot
  open /boot/grub2/grubenv: Read-only file system`). GRUB uses that flag to fall back
  after a boot that never reached userspace, a kernel panic for one, so that fallback may
  not work. The Pi boots differently; slice 1's bench test checks it there.
- **With root locked, emergency mode does not hold.** `sulogin` fails, emergency mode goes
  inactive and part of the boot resumes (30 services against 38). With the root password
  the owner chose, `sulogin` should wait at the console and emergency mode should hold;
  the first-boot simulation, which sets one, checks that.

Still open: the second way in for the Singapore box (Tailscale is packaged; the owner
chooses), and the GRUB fallback on a Pi.

## Decided, 2026-11-02

The owner settled the open calls on 2026-11-02.

1. **No automatic updates.** `transactional-update.timer` is disabled on every MicroOS
   host; the owner runs updates and the reboot over ssh
   ([`decisions.md`](../docs/decisions.md) § *MicroOS hosts take openSUSE's cloudflared*).
2. **openSUSE's `cloudflared`,** guarded by a `health-checker` plugin that rolls a bad
   update back, as that section says. The simulation proves the rollback path before any
   host relies on it.
3. **Syncthing on `one` runs under compose,** as on `zero`. Every service stays in a
   container.
4. **Each host's first-boot files** live at `hosts/<host>/microos/combustion/script`,
   beside an fstab fragment the script appends to the image's own `/etc/fstab`, since
   MicroOS writes its root entries at install.
5. **`three`'s tunnel** comes from a new play for a host that has none. The simulation
   tests it against a stand-in for Cloudflare's API, so no account is needed, and Fable
   reviews it adversarially.

## Docs this changes

roadmap §3 (scheduled, with `one` and `three` first), `docs/host-setup.md` and
`docs/recovery.md` for systemd, every host README, and `README.md`'s host table.
