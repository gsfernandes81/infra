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
Leap on a Pi installs from them.

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
that gives the fstab's ids, and a swap disk with its UUID, both on USB. The VM sits on
one's own subnet, so its static address answers.

The run then checks, each as PASS or FAIL, and any FAIL fails the job:

- from outside: the host key is the carried one, sshd offers public keys only, root is
  refused over ssh even with a valid key in its `authorized_keys`, by `PermitRootLogin` as
  sshd's own log says, and root logs in on the serial console with its password;
- on the box (`host/checks.sh`): the static address, SELinux, gavin's uid, shell and sudo,
  root's password, sshd's settings, every data mount by `subvolid=`, swap, the read-only
  bare `/media`, Docker on its new store on the SSD with a fresh pull and a read through
  the `context=` mount, upstream's Compose, the pinned `cloudflared` and its ingress,
  `tailscaled` from Tailscale's repository, the update timer, the reboot strategy, the
  checkout, and the carry-over's files and modes;
- the deploy play: `server-deploy-compose.yml --check` for each of the host's deployments,
  from the runner as the control node, logged in as gavin with his sudo password, after the
  box's checkout is put on the commit under test. Each must plan, and no log may hold the
  password. The stand-in `.env` files carry every name each `compose.yaml` requires. Only
  `--check`: a real `up` needs each cloudflared sidecar's tunnel to connect, which a
  stand-in cannot. Each deployment's images are pulled on the box first, so the plan
  reaches Compose's dry run; a built image, or one that will not pull on this x86 VM,
  stops that deployment's plan before it, and the report says which;
- in rescue mode (`host/rescue.sh`), entered with `systemctl isolate`: gavin logs in, and
  sshd, the network, `cloudflared`, `tailscaled` and logins are up while Docker is down;
- after a reboot, proved by a new boot id, the box checks again on its static address.

When gavin cannot log in, the run logs in as root on the serial console
(`serial-login.py`), or uses the initramfs's emergency shell if the boot stopped there,
and prints what the box knows about why.

The stand-in tunnel credentials cannot connect, so the run shows `cloudflared` installed,
enabled and retrying, not serving.

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
`ansible-playbook` with `ansible/requirements.yml`'s collections for its deploy stage. Each writes only
inside its work directory. Do not run them in the `infra` container: that container is on
`zero`, has no KVM, and would compete with Immich.
