# MicroOS simulation

This directory holds the CI simulations behind
[`plans/microos-cutover.md`](../../plans/microos-cutover.md). They answer, before the
November 2026 visit, the questions the plan cannot settle from documentation. Nothing here
runs on the fleet or reaches it, and nothing here is a host's first-boot script.

## The probe

`.github/workflows/microos-sim.yml` runs `run-probe.sh` on a GitHub runner with KVM. The
script downloads Tumbleweed's current MicroOS image for x86_64 and checks it against the
published checksum. It boots the image with a Combustion config drive built from
`probe/combustion/`, and runs `probe/checks.sh` over ssh. It then reboots the VM once and
checks again. The report records which image it tested, because the image changes daily.

The probe answers:

- whether SELinux enforces, and whether Docker refuses a bind mount from an unlabelled
  btrfs at `/media`, as every compose file here makes them, and whether `:z` fixes it;
- whether the read-only root refuses writes to a bare `/media` mountpoint, which would
  make it the mount guard `chattr +i` is on Alpine;
- which Docker and compose plugin openSUSE ships, and whether they start;
- what reboot policy MicroOS ships, and whether a first-boot setting of `strategy=off`
  survives a reboot;
- whether bcache-tools brings a udev rule that registers devices by itself;
- which of the packages a host needs exist.

A second job asks the aarch64 package repositories the same package question, because
MicroOS on a Pi installs from them.

The run's ssh key is made fresh in the runner and dies with it. The job fails only when
the VM does not boot or answer ssh; every answer is in the job summary and in the
`microos-probe` artifact, with the VM's serial log.

## Late disks

`run-late-disks.sh` builds `zero`'s array in miniature on three simulated USB disks: one
bcache cache in front of two backing disks, and btrfs RAID1 on the two bcache devices,
mounted by an fstab entry with `nofail` and `context=`. A stand-in service needs the mount
through `RequiresMountsFor=`, as a deployment would. The script then boots the VM without
the disks, hot-plugs them a minute later through qemu's QMP socket (`qmp.py`), and reports
at each stage: whether udev registers the bcache devices by itself, whether systemd mounts
the array when it completes, what the stand-in service did, and whether the bare
mountpoint refused a write. It ends with a reboot with the disks present.

## What a green run does not show

The simulations run on x86_64 under KVM, not on a Pi; the USB disks are qemu's. It does
not exercise USB bridges, real disks, Cloudflare, or any host's own first-boot script.
Those come in later simulations or on the bench at the visit.

## Running it elsewhere

`run-probe.sh <workdir>` and `run-late-disks.sh <workdir>` run on any Linux machine with
KVM, `qemu-system-x86_64`, `qemu-img`, `mke2fs` and an ssh client. It writes only inside
`<workdir>`. Do not run it in the `infra` container: that container is on `zero`, has no
KVM, and would compete with Immich.
