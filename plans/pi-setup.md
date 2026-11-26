# Setting up a Leap Pi: stock image, small Combustion, one play

Approved by the owner on 2026-11-25, and being built on `zero-leap`. The reasoning is in
`docs/decisions.md` § *Every Leap Pi: the stock image, an offline Combustion, one play*.
This file goes once the work is done.

## Why

The owner has not been able to review the code that sets up the Pis, and wants that
problem smaller. Today a Leap Pi is built by about 1,200 lines of shell
(`leap/firstboot.sh`, `leap/make-stick`, each host's `combustion/script`) run once inside
the initrd, plus plays and pasted handover blocks after it. The owner wants:

- **Less code, easier to review**, for the part that sets up a Pi. The Cloudflare, client
  and dev-container plays are out of scope.
- **Declarative over procedural**: what a Pi has is a list in git, not a sequence of
  commands.
- **Resilience**: recovering a Pi, or adding one, is the same short routine every time,
  and does not depend on the day's network inside the initrd.
- **Less responsibility**: nothing we have to build, pin or keep in step that openSUSE
  already does.

## The routine, when a card dies or a Pi is added

The routine is the same for both; a dead card's host comes back with a new identity
(below).

1. Write openSUSE's stock Leap 16.1 Immutable Pi image to a card: the newest build at
   download, checked against openSUSE's `.sha256`. No image of ours, and no pin of the
   image. The file stays on `two`, so a bench boot and the day it proves use the same
   download (`plans/zero-leap.md`, call 12).
2. Make the host's Combustion config with `leap/make-stick`, on a stick or on the card.
3. Boot the Pi. Combustion sets its identity and puts the carried secrets in place. It
   needs no network.
4. Run one play from the control node. It installs the package list, the tracked files and
   the rest, and reboots the Pi twice, asking before each: once into the packages, once
   for the rest (item 7 below says why).
5. Only if the host's disks are new: make the filesystems by hand, once the play's first
   reboot has brought `cryptsetup` and `bcache-tools`, then run the play again. Disks that
   already hold the array need nothing: the play's second reboot mounts them.
6. For a new host, or one back from a dead card: its tunnel
   (`server-create-host-tunnel.yml`) and its tailnet join, as today. A host
   moved from a working old system carries both.

The owner is at the box, with a laptop or the phone, and can reach the Pi from `one` or
`two`.

## When a card dies: a new identity

The owner's call, 2026-11-25. A dead card takes the host's identity with it, and the host
comes back with a new one rather than from a stored copy. `docs/decisions.md` § *Secrets
wait* is why that costs nothing: the only secrets that cannot be regenerated are the two
LUKS passphrases, both in Proton Pass, and `pearl-wallet`'s seed, on paper. The rest comes
from its provider, from a play, or from root on the box.

- **The config** is made as for a new host (`make-stick --new`): a new ssh host key, whose
  fingerprint is printed for the first `ssh`, and no tunnel credentials, Tailscale state
  or key file. `--new` refuses a host that has a tunnel or a volumes list today, so it
  learns to make a config for such a host, carrying nothing of the old system.
- **On the day, after the play:**
  - clients re-pin the new host key;
  - a new tunnel, from `server-create-host-tunnel.yml`;
  - a new tailnet join, with the old node removed in the admin console and its address
    given to the new one, so `three`'s pull still finds `zero` where it pins it;
  - each deployment's secrets back from where `decisions.md` says each comes from;
  - on `zero`, the array opened with the passphrase and a new key file added to its
    keyslot (`hosts/zero/system/README.md`).
- **What survives the card** on `zero` and `one`: the data on the disks, the Docker store
  on the SSD with its named volumes, and the array.
- **A planned move from a working old system**, as `zero`'s move is, still carries the
  identity (`plans/zero-leap.md`, call 8). The carry-over stays in `make-stick` for that.

## What Combustion does, and only this

Combustion runs the host's script inside the initrd at first boot. It does only what needs
no network, so the Pi 5's missing `rp1_pci` in the initrd (`plans/zero-leap.md` § *What
`zero` has*) stops mattering. No `# combustion: network` line.

- The hostname, root's password hash, `gavin` with his password hash, uid and gid, and his
  `authorized_keys`, with bash as his shell until the play installs fish and makes it his
  (sshd refuses a user whose shell does not exist); sshd enabled, with `sshd-infra.conf` and `sudoers-gavin`, so the play
  starts in the fleet's usual sudo, `-K` with gavin's own password (stock Leap's sudo asks
  for root's password, and a play that changed that partway through would fail its own
  later steps).
- The old host's ssh host keys, so every client's pinned key still matches.
- The carried secrets: the array's key file, the Tailscale state, root's restore key, the
  tunnel credentials. Each deployment's `.env` and secrets directory and each volume's tar
  are staged for the play to put in place once the checkout exists. Each `.env` is at
  `/root/carry/env/<dep>.env` and each secrets directory at
  `/root/carry/home/.<dep>-secrets/`, under a root-only (0700) `/root/carry`. The volume
  tars stay at `/root/volumes/<name>.tar`, as today.
- The wired port on DHCP, as the image ships it. The static address comes from the play.
- What the transactional-update shell needs to write into the right places: mounting the
  subvolumes, growing root on the one-card route, labelling what it wrote.
- The image's own package list, written to `/etc/infra/image-packages` before anything
  else is installed: one package name per line, sorted, from
  `rpm -qa --qf '%{NAME}\n'`. It is the baseline the play's extras report reads (below).

`leap/firstboot.sh` keeps these steps and loses the rest: the clock, the packages, the
pinned downloads, the units, the motd and the clone move to the play.

## Reaching the Pi on the day

Neither way in exists yet on a fresh Pi: cloudflared and Tailscale's packages come from
the play. So the play reaches the Pi over the LAN, through `one` or `two`:

- The owner reads the Pi's DHCP address from its console or the router.
- `ssh -J one -o HostKeyAlias=<host> gavin@<address>` checks the carried host key against
  the pinned entry, so nothing is accepted on trust.
- The play runs the same way, with the address and the jump given on the command line. The
  inventory and `~/.ssh/config` stay as they are.

## The play

One play, `ansible/playbooks/server-setup-leap.yml`, for every Leap host, safe to run
again. It runs as `ansible-playbook playbooks/server-setup-leap.yml -e target=<host> -K`,
for the hosts in a new inventory group `leap`: `one` and `three`, and `zero` when it
moves. The same run rebuilds a Pi, sets up a new one, and puts back anything that
drifted. Plain Ansible: tasks in order, no roles, no
custom modules, no layers of includes.

1. **Packages.** One list for every Leap Pi, `leap_packages` in
   `ansible/group_vars/leap.yml`, with no per-host extras (the owner's call, 2026-11-25).
   It is the common list in `leap/firstboot.sh` (`common_packages`) plus what `three` and
   `zero` add: `cryptsetup`, `wpa_supplicant`, `bcm43xx-firmware`, `snapper` and
   `bcache-tools`. The play reads what is installed, installs only what is missing, in one
   `transactional-update pkg install`, after Tailscale's repository and the existing
   package locks. The standard package module cannot write the read-only
   root, so this is a command, guarded by the comparison. The package locks are
   `leap_package_locks` in the same file.
   - **Why one list.** Every Pi is set up the same way, and no host is left with a package
     its neighbours lack, so nobody expects a tool a host does not have.
   - **The one cost found.** `bcache-tools` ships a udev rule that registers a bcache disk
     on any host it is plugged into. Wiping an old member of `zero`'s array "on another
     machine" (`docs/decisions.md` § *`zero`'s encrypted member*, the row "The old member
     is wiped on another machine, never `zero`") now means a machine without
     `bcache-tools`, `two` or the laptop, or unregistering the device first.
   - **Installing is not enabling.** The play enables services per host from host vars.
     Common units are `leap_units_enabled` and `leap_units_masked` in the same file; a
     host's own are `leap_extra_units_enabled`.
2. **Extras are reported, never removed.** A package someone installed that is neither on
   the list nor in `/etc/infra/image-packages` is printed. The report is zypper's own
   record of user-installed packages, less the list and the baseline, so dependencies and
   the image's hundreds of packages stay out of it. The builder calibrates it on `one` and
   `three`, where no baseline was recorded, and it must stay short enough to read.
   Removing a package is the owner's call, by hand, so a typo in the list cannot take
   something live away.
3. **The pinned binaries**, cloudflared and Compose, from `leap/pins`, as today (below).
4. **The checkout** cloned to `/home/gavin/infra`, then the staged `.env` files and
   secrets directories put in place, with today's ownership rules, and `/root/carry`
   removed.
5. **The tracked `/etc` files**, through the existing `server-install-system-files.yml`
   path and `bin/install-system-file`, unchanged. The play also owns what is not a tracked
   file: the host's `fstab.append` lines and the bare `/media/*` mountpoints, which need
   the read-only root and so go in with the package snapshot.
6. **The rest, each a few plain tasks:** the users and groups a host needs (`backup` on
   `zero`, `devstack`), enabled and masked units, firewalld's services, snapper's config
   list, the motd. Only where a host differs, its host vars carry them:
   `leap_system_users` (a list of name, shell, comment and home), `leap_groups` (name,
   gid and members), `leap_firewalld_services`, `leap_snapper_configs` and
   `leap_extra_units_enabled`.
7. **Two reboots on a fresh Pi, and none or one on a running host**, each only if
   something changed that needs it. A transactional-update install is usable only after
   a reboot, and the stock image likely has no python3 or git, so the play installs the
   packages first, over plain ssh, and reboots into them before anything else. The static
   address and the array's fstab and crypttab entries then take effect at the second
   boot. (Corrected 2026-11-25 while building the play; the design said one reboot.)
   **It asks first, every time**, showing what is running, as `server-update-leap.yml`
   does. Health-checker rolls back a boot that fails.
   - **The restart rule** (the owner's call, 2026-11-25). The play restarts a service
     whose tracked file it changed, except `sshd`, `NetworkManager`, `cloudflared`,
     `tailscaled` and `docker`, which take effect at the reboot it asks about. The
     exceptions guard the connection the play runs over (CLAUDE.md § *Changing the thing
     you are connected through*) and every container, which `docker` restarts. A bad
     config is guarded more specifically already, by `bin/install-system-file`'s
     validators and rollback, which stays as it is and still never restarts anything.
8. **The ways in the host has, proved after the reboot**, as `server-update-leap.yml`
   proves them today. A new host without a tunnel or a tailnet join yet is told so, not
   failed.

Package changes on a running host go through the same play, batched, since each install
costs a reboot.

## Unchanged, and why

- **Updates stay by hand.** `transactional-update.timer` stays masked and
  `server-update-leap.yml` stays the update, so a failure happens while the owner is
  watching (`decisions.md` § *Rescue mode keeps a way in*, the owner's call).
- **cloudflared and Compose stay pinned upstream binaries.** Their reasons were checked on
  2026-11-25 and still hold: Leap 16.1 still ships cloudflared 2026.9.1 and Compose
  2.33.1, the versions the decisions were made against (`decisions.md` § *Every box has
  two ways in*, § *Leap hosts carry upstream's Compose*). Compose's own exit is already
  written: the update play reports Leap's version, and the binary goes when Leap reaches
  the floor.
- **The carry-over**, the disk guards and `--card` in `make-stick`, and the bench boot.
- **`bin/install-system-file`** and the tracked `/etc` files with their headers.

## What goes

- **The network half of the first boot**: `set_clock`, `install_packages`,
  `install_binaries`, `enable_units`, `install_motd`, `clone_infra` and the per-host
  installs of tracked files, from `leap/firstboot.sh` and each `combustion/script`.
- **The Pi 5 initrd problem** and every workaround considered for it.
- **The image pin**: `pi_image_url` and `pi_image_sha256` in `leap/pins`, the runbook
  check in `leap-pins.yml`, and the pinned leg of `pi-image.yml`. Its `current` leg stays
  as a report on openSUSE's newest build. The card steps in `plans/visit-runbook.md` take
  the newest build and check it against openSUSE's file.
- **The build items in `plans/zero-leap.md`** for `hosts/zero/leap/combustion/script`'s
  packages and the simulation's first-boot checks, which this replaces.

The builder measures the lines removed and added; the owner wants a net loss in what sets
up a Pi.

## The order

1. The play, built and run in the simulation against a stock x86 image booted with a
   Combustion config made the new way.
2. `one` and `three`, which already run Leap: the play in `--check`, then for real, on the
   owner's word. Nothing to install shows the list holds what they run; the extras report,
   read once by the owner and then empty, shows the list holds everything they need.
3. `zero`'s move, the new way (`plans/zero-leap.md`, with its build section rewritten).

## The simulation

CI boots openSUSE's x86 image with the host's new Combustion config, then runs the real
play against the VM from the runner, as the control node would. It checks what today's
checks check after the first boot, plus: a second run changes nothing and does not reboot;
an extra package is reported and left; a missing one is installed. The Pi image itself is
inspected by `pi-image.yml`'s `current` leg, report only. For `zero`, the bench boot is
the check that can stop a bad build: it boots the very file the day uses, and its check
block reads the kernel modules the array needs.

## Left to the builder

- How the play finds what is installed (`rpm -q` against the list, or package facts).
- Whether the static address is a tracked NetworkManager profile, as on `one` today, or a
  task.

## Traps already known

- **The play must not change the address it is connected through** mid-run. The static
  profile is written, and takes effect at the reboot (CLAUDE.md § *Changing the thing you
  are connected through*).
- **The transactional-update shell binds less than it seems**: `/home`, `/var` and `/root`
  writes from Combustion need the subvolume mounts `firstboot.sh` already does.
- **A first boot that stops** before Combustion commits runs again; every step stays safe
  to re-run.
- **SELinux labels** for anything Combustion writes outside the relabelled paths, as
  `label_subvolumes` does.
