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

## What a green run does not show

The probe runs on x86_64 under KVM, not on a Pi. It does not exercise USB bridges, real
disks, Cloudflare, or any host's own first-boot script. Those come in later simulations or
on the bench at the visit.

## Running it elsewhere

`sim/microos/run-probe.sh <workdir>` runs on any Linux machine with KVM,
`qemu-system-x86_64`, `qemu-img`, `mke2fs` and an ssh client. It writes only inside
`<workdir>`. Do not run it in the `infra` container: that container is on `zero`, has no
KVM, and would compete with Immich.
