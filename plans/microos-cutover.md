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
| 1 | Bench test at home: boot `three` on its MicroOS card | 1 | `three` proven on its own hardware; the fleet untouched |
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
   and not generated. It sets users, ssh keys, hostname and packages, and it carries no
   secret.
2. **A carry-over step for what is not in git:** tunnel credentials
   (`/etc/cloudflared/<host>.json`), every deployment's `.env`, and **the ssh host keys**,
   so every client's pinned `known_hosts` entry still matches. Each goes at mode 600,
   never through git, and is deleted from the transfer medium after.
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

## What the simulation answers first

- **SELinux.** MicroOS enforces SELinux by default, and Docker bind mounts into `/media/*`
  may be refused until the paths are labelled. It would break every compose file at once.
- **bcache without `bcache-register`.** bcache-tools' udev rules register devices on
  systemd distributions. If that holds for disks that appear late, `zero`'s hardcoded-UUID
  script is not needed on MicroOS.
- **Docker's existing data.** `one`'s SSD and `zero`'s `sda2` hold `/var/lib/docker` on
  the containerd image store. If MicroOS's Docker cannot read it, images are pulled again;
  volumes such as `garmin-tokens` need a proven carry-over either way.
- **Automatic updates and reboots.** MicroOS applies updates daily and reboots in a
  maintenance window by default. Nothing on this fleet restarts without the owner's say,
  so the owner decides the window, per host, before `zero` goes onto MicroOS.
- **Packaging:** Docker and its compose plugin, `cloudflared`, `bcache-tools` and
  `smartmontools` for aarch64.

## Docs this changes

roadmap §3 (scheduled, with `one` and `three` first), `docs/host-setup.md` and
`docs/recovery.md` for systemd, every host README, and `README.md`'s host table.
