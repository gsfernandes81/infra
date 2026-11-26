# `zero` moves to Leap 16.1 Immutable

A design from 2026-11-20, approved by the owner on 2026-11-24. It moves
`zero` from Alpine to openSUSE Leap 16.1 in its Immutable mode, as `one` and `three` moved
at the November visit. When it is done its reasoning moves to
[`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

**Approved 2026-11-24; the move waits until the owner is back from Singapore.** The repo
work needs no box and is built on the branch `zero-leap` meanwhile (§ *The build*). The
bench boot and the day each wait for the owner's word. Calls marked *agent's call* are the
design's own and the owner can overturn any of them. Phase 12 in
`docs/management-plane.md`, ordered after 10 and 11.

## The owner's calls, 2026-11-20

1. **The day:** the owner is at `zero` with two things ready, a new SD card with Leap and
   a USB stick for Combustion. They boot `zero` from the new card, finish over ssh, and it
   is done.
2. **The way back** is the Alpine card, untouched. So the move writes nothing the Alpine
   system cannot read on its next boot.
3. **Go or no-go is decided when it is ready.** A no-go is acceptable, and nothing is
   rushed for a date.
4. **The gate is a Pi 4's proof, already given** by `one` and `three` (`decisions.md`).
5. **The dev hub moved to `one` first**, so the infra agent stays up through `zero`'s day
   and `zero`'s move covers Immich, Syncthing, pearl-wallet and the backup source only
   (`decisions.md` § *The dev hub runs on `one`*).
6. **Immich and Syncthing come back first;** the stack is otherwise the same as today,
   under Docker.
7. **No new guard for a late array.** Docker's restart loop brings Immich back once the
   array mounts, proven in the simulation. Quadlets, at phase 17, give each container a
   systemd unit, where `RequiresMountsFor=` does it directly.
8. **`zero` keeps its tailnet identity:** its Tailscale state is carried.
9. **Encryption protection stays off at the move,** with the key file carried on the stick
   and the stick wiped after the day. Phase 16 turns it on later.
10. **Syncthing is reachable on the LAN:** firewalld lets its ports through.
11. **A bench boot first,** of a minimal image the owner can ssh into and test.
12. **The newest build** of the Pi image (2026-11-25, in place of build 3.17, which
    openSUSE had withdrawn). The owner's rule: where there is a choice and no major
    downside, the newest version. Builds turn over within days, so there is no pin: the
    owner downloads the newest build to `two` before the bench and checks it against
    openSUSE's `.sha256`, and the bench and the day use that one download, since the bench
    is what proves it (*agent's reading*).
13. **snapper runs natively over D-Bus** (2026-11-24): `immich` joins Leap's
    `SNAPPER_CONFIGS` and Leap's own timers take the snapshots. Set aside: `--no-dbus`
    from an own timer, as `three` runs it, which has no case on `zero` (§ *snapper*).
    **The simulation found the case on 2026-11-26:** Leap's policy refuses `snapperd` a
    directory on the array's `container_file_t` mount, so the design's own fallback,
    `--no-dbus` from an own timer, is what is built. For the owner to confirm or overturn
    (§ *snapper*).
14. **One card instead of card plus stick, tried on the bench** (2026-11-24). If the bench
    proves it, the day uses one card; if not, the stick (§ *One card*).
15. **Root on the bench** (2026-11-25): the bench carries gavin's password hash and a sudo
    rule that asks for it, as on `one` (§ *The bench boot*).

## What `zero` has that `one` and `three` did not

Each of these is new to a Leap first boot, and each is the reason for a piece of work
below.

- **A Pi 5.** No Pi 5 has booted Leap on this fleet. Builds 3.17, 3.22 and 3.23 carry the
  Pi 5's device trees and a `[pi5]` section in `config.txt` (CI runs 44271041125,
  45458244546 and 45532879407). **The initrd has no driver for RP1, the chip the Pi 5's
  Ethernet sits behind:** it carries `macb`, the PHY, `clk_rp1` and `pinctrl_rp1`, but not
  `rp1_pci`, which they hang off (`sim/pi-image/inspect.sh`, runs 45458244546 and
  45532879407; the same in 3.17's initrd listing). It has no Wi-Fi either. So a Pi 5's
  first boot most likely has no network before switch-root, where Combustion runs. Since
  2026-11-25 that costs nothing: Combustion does only offline work on every Leap Pi, and
  the packages, the pins and the clone come from the play over ssh once the booted system,
  which has every driver, is up (`plans/pi-setup.md`). The bench boot shows the booted
  system reaching the LAN.
- **LUKS above bcache, opened at boot from a key file.** The encrypted member is the WD
  Red Plus, its bcache backing device, then LUKS2 `data-luks-4`, mapping `data-4`, then
  btrfs devid 4 (`hosts/zero/system/dmcrypt:13-15`). `three`'s LUKS is a passphrase,
  `noauto`, unlocked over ssh. Nothing on Leap had opened LUKS from a key file, or
  stacked it on bcache, until `zero`'s simulation did both on x86, at boot and late
  (§ *The simulation*). bcache-tools' udev rule assembling the devices was proven without
  LUKS first (`plans/microos-cutover.md` § late disks).
- **A tailnet identity that others depend on.** `three`'s pull reaches `zero` at
  `100.121.158.58` with `StrictHostKeyChecking yes`
  (`hosts/three/leap/system/backup-ssh-config`), and `three`'s restore key accepts only
  that address (`restore-authorized-keys:18`). `one` and `three` joined the tailnet fresh
  after their first boots. `zero` cannot.
- **The backup source.** The `backup` user, its forced `rsync --daemon` through `setpriv`,
  snapper's `immich` config and its hourly snapshots. All installed on Alpine on
  2026-11-20; on Leap so far only in `zero`'s simulation, which also found `snapperd`
  refused on the array (§ *snapper*).
- **gavin at uid 1001.** `one` and `three` are 1000. Syncthing runs as 1000 on `zero`, so
  `/media/syncthing` is owned by 1000, which on Alpine is an old account named `yes`. No
  account is made for 1000 on Leap (*agent's call*): Syncthing's container needs none,
  and Alpine reads the numbers as before.
- **Array disks on USB.** `make-stick`'s "not a USB disk" guard does not exclude them, and
  its fstab-UUID guard misses the bcache and LUKS member partitions, so on `zero` only the
  size cap and the typed confirmation stand between the stick and an array disk.

## What the paste from `zero` showed, 2026-11-20

- **Subvolume ids on the array:** 278 `media-syncthing`, 281 `immich`, with 282
  `data/thumbs`, 283 `data/encoded-video` and 284 `.snapshots` nested under it; 279 and
  280 are the old Immich subvolumes phase 11 deletes. On `sda2`: 256 `var-lib-docker`.
- **bcache:** `sda1` is the cache (`a3d7a86c…`), `sdb` (`589733f6…`) and `sdc`
  (`f5ec31d1…`) the backing disks. Today `bcache0` is the plain btrfs member and `bcache1`
  holds `data-luks-4`; nothing on Leap names either number.
- **Tailnet address** `100.121.158.58`, as `three` expects.
- **The Pi 5's EEPROM:** bootloader of 2025-05-08, `BOOT_ORDER=0xf41` (the SD card, then
  USB, then again), no `PSU_MAX_CURRENT`. Alpine's `config.txt` sets nothing Pi 5 specific
  and there is no `usercfg.txt`. So the Leap card needs no `extraconfig.txt` for USB
  power: the disks already run under these firmware settings. The card boots before the
  stick by the boot order.
- **Two things to look at before the day:**
  - `~gavin/infra/.claude/` is untracked in `zero`'s host checkout. That checkout was
    `infra-dev`'s `/workspace` until 2026-10-27, so it may hold session worktrees with
    commits that exist nowhere else. The fresh clone on Leap would leave them on the
    Alpine card only. Read `git -C ~/infra worktree list` and the branches in it, and
    account for each commit as CLAUDE.md asks of a diverged checkout, before the stick is
    made.
  - An anonymous volume, `294c1145…`, that no compose file names. Phase 10's measure step
    finds its owner before anything is removed.

## The carry-over

What crosses from Alpine to Leap on the stick, and what does not. The second column is
what `make-stick` carried before this work, the third what it carries for `zero` now
(§ *The build*, items 1 and 2).

| Item | Before | For `zero` |
|---|---|---|
| ssh host keys, password hashes, gavin's `authorized_keys` | carried (`leap/make-stick`) | unchanged; `three`'s `zero-known-hosts` keeps matching |
| `/etc/cloudflared/zero.json` | carried | unchanged |
| `deployments/immich/.env` | carried | the only `.env` `zero` has |
| `~gavin/.<dep>-secrets` | carried | none, once phase 10 has removed the dev secrets; `make-stick` refuses any it finds on `zero` |
| `/etc/keys/data.key` | **not carried** | carried at 0400 in a 0700 directory, checked by `check_carry`, installed before the first mount. Without it `data-4` stays shut and the array cannot mount |
| Tailscale state, `/var/lib/tailscale/tailscaled.state` | **not carried** | carried, so `zero` keeps its node and its address; the Alpine and Leap cards then share one node and must never both be up, which one Pi with one card slot already ensures |
| root's restore key, `/root/.ssh/restore` and its `known_hosts` line for `three` | **not carried** | carried; `three` pins its public half and the play that made it never replaces one |
| `pearl-wallet_wallet` | through `hosts/<host>/leap/volumes` | listed; it is backed up nowhere else, so the stick's tar is the only copy until the restore succeeds |
| `immich_model-cache` | | not carried; Immich downloads its models again (*agent's call*) |
| the ntfy URL in `/var/lib/backup-alert` | | not carried; `backup-age-check` is not in use (*agent's call*) |
| snapper's snapshots | | nothing to carry; they live on the array |
| the `~gavin/infra` checkout | cloned fresh from `main` | unchanged; `make-stick` lists any untracked file in it other than `.env`, so nothing is lost silently |

**Where the Tailscale state lands.** The first-boot script runs inside a
transactional-update shell that binds only `/root`, `/var/log` and a few `/var` paths, so
a write to `/var/lib/tailscale` would vanish as writes to `/home` did before
`mount_subvolumes`. `install_tailscale_state` mounts `/var`'s subvolume beside and writes
through it, and `zero`'s simulation checks the carried file is the one in
`/var/lib/tailscale` after the play's reboots.

## The files

Every Leap copy changes its header to `infra-os: leap`, `infra-init: systemd`. The new
directory is `hosts/zero/leap/`, laid out as `one`'s.

| Alpine file | Leap form |
|---|---|
| `fstab` | `leap/fstab.append`: the array's top level at `/mnt` (noauto, Alpine's `/mnt/ext`, which the read-only root has no directory for and the play makes only `/media` mountpoints), `/media/immich` (subvolid 281), `/media/syncthing` (278), swap on `sda3`, Docker's store on `sda2` by a new subvolid. Each line gains `x-systemd.device-timeout=180s`; the array lines gain `context=system_u:object_r:container_file_t:s0`, `/mnt` included, since they share one superblock, and the store's line too, as on `one` (*agent's call*). No `autodefrag`. Root, boot and tmpfs lines are the image's own |
| `bcache-register` | nothing: bcache-tools' udev rule. `bcache-tools` is in the one package list |
| `dmcrypt`, `dm-crypt.conf` | `system/crypttab`: `data-4 UUID=c00f99a6-… /etc/keys/data.key luks,nofail` with a device timeout, not `noauto` while protection is off; no `discard`. No modules-load file, once `pi-image.yml` shows the Pi image's kernel carries dm-crypt and Adiantum's modules (below) |
| `zram-swap` | `system/zram-generator.conf`, `one`'s verbatim (2G, zstd, priority 100) |
| `cloudflared`, `cloudflared-config.yml` | `one`'s `cloudflared.service`, pinned binary, `--no-autoupdate`; the config's body unchanged apart from stale comments |
| `sshd-infra.conf` | `one`'s, with `KbdInteractiveAuthentication no` |
| `tailscaled` | Tailscale's repo package (`one`'s `tailscale.repo`) and its unit, with the carried state |
| `snapper-config-immich` | unchanged apart from its header and its line about Alpine's scripts sourcing it |
| `snapper-sysconfig`, `snapper-immich` | `system/snapper-immich.service` and `.timer`, the hourly script as a unit with `--no-dbus`, enabled from `ansible/host_vars/zero.yml`; `immich` is in no `SNAPPER_CONFIGS` (§ *snapper*, what the simulation found). Both Alpine files stay on Alpine |
| `sudoers-backup`, `backup-authorized-keys` | `/bin/setpriv` becomes `/usr/bin/setpriv` in both, in the same commit, as `three`'s `sudoers-restore` and `restore-authorized-keys` have it; the sudoers file installs as `60-backup`, beside `three`'s `60-restore` |
| `rsyncd-backup.conf` | unchanged apart from its header |
| `backup-age-check` | stays on Alpine, not installed |
| `devpool` | deleted with phase 10's end |
| none | from `one`: `wired.nmconnection` at `192.168.86.100`, `rebootmgr.conf`, `transactional-update.conf`, `sudoers-gavin`, `docker-mounts.conf` |
| none | `combustion/script`, from `one`'s, offline: gavin and his group at 1001, the key file, the Tailscale state, the restore key |
| none | in `ansible/host_vars/zero.yml`, for the play: the `backup` user with a real shell (sshd runs the forced command through it) and its root-owned home; firewalld's `syncthing` service (22000 tcp and udp, 21027 udp), as `three` has it; `snapper-immich.timer` enabled. The play makes `/media/immich` and `/media/syncthing` as bare mountpoints from `fstab.append` |
| none | `volumes`: `pearl-wallet_wallet` |
| none | `MOVED`, committed on the day once the first boot answers, before the play, which refuses a host without one |

**snapper** (the owner's call 13). `three` uses `--no-dbus` because its snapshot follows a
pull, not a timeline, so Leap's timers have no part in it. `zero`'s snapshots are a plain
hourly timeline, which is what Leap's timers do. Three consequences, none a reason
against:

- **Cleanup is daily**, not hourly, so up to a day of extra hourly snapshots exists before
  it runs. That costs little on a filesystem where snapshots share blocks, and it widens
  the window `three`'s pull has before a snapshot goes (phase 11's `TIMELINE_LIMIT_HOURLY`
  watch).
- **No mount check.** With the array missing, `/media/immich` is a bare directory on the
  read-only root, so the timeline run for `immich` fails and writes nothing. Root's config
  is unaffected.
- **SELinux is the one unknown.** Over D-Bus, snapshots are made by `snapperd` in its own
  confined domain, on a mount labelled `container_file_t`. Nothing on this fleet has run
  that: `three`'s snapper runs from its own unit, outside `snapperd`. The simulation runs
  enforcing and checks for a snapshot and for no denial. If `snapperd` is refused, the
  owner is told, and the fallback is `--no-dbus` from an own timer.

**What the simulation found, 2026-11-26.** `snapperd` is refused: the audit log reads
`avc: denied { create } … comm="snapperd" scontext=…snapperd_t tcontext=…container_file_t
tclass=dir`, no snapshot is made, and `snapper-timeline.service` fails, which fails the
setup play's own check of failed units. So `zero` runs the fallback, as `three` does:
`snapper-immich.service`, `snapper --no-dbus` create and both cleanups, skipped by a
condition while `/media/immich` is not mounted, from `snapper-immich.timer` at the top of
each hour. `immich` is in no `SNAPPER_CONFIGS`, Leap's root config is left as the image
has it, and the first two consequences above no longer apply: the cleanup runs hourly, and
a missing array skips the hour. Allowing `snapperd` with a policy module of our own was
not taken, as new policy code to keep. The simulation checks the timer's snapshot, with no
denial (`sim/microos/host/checks-zero.sh`).

Nothing runs `snapper create-config`: `.snapshots` exists on the array as subvolume 284,
and its numbering continues.

**The recreate puzzle** (`server-deploy-compose.yml` planning to recreate Immich and
Syncthing on Alpine, under *Open items*) does not block the move: Leap starts with an
empty store, so the first deploy creates every container whatever the answer.

**Deployments.** Immich's binds and Syncthing's are on the array and take the mount's
`context=`, never `:z`, which would write labels into the data. pearl-wallet's two config
binds come from the checkout and need `,z`, as the tunnel sidecars did (`decisions.md`,
calibre-web's row). Immich's `/etc/localtime:ro` bind has no precedent; the simulation
shows whether SELinux allows it. pearl-wallet's image is built on the box, so it is built
again on the empty store.

**Docker's store.** Leap's Docker cannot adopt Alpine's store, so `zero` gets a new
subvolume on `sda2`, as `one` got `var-lib-docker-leap`. It is made under Alpine before
the day, its id read off and committed (`make-stick` refuses a `FILL-FROM-` placeholder),
and Alpine's `var-lib-docker` stays for the way back. `sda2` is 64 GiB; phase 10's removal
of the dev images leaves room for both.

## What `make-stick` and the first-boot script need

Done (§ *The build*, items 1 and 2); `leap/README.md` describes both as built.

- ~~**Carry** the key file, the Tailscale state and the restore key, each with a
  `check_carry` entry, and refuse when the key file is absent on a host whose `crypttab`
  names it.~~
- ~~**A disk guard for `zero`:** refuse any disk holding a bcache superblock, a LUKS
  header or a btrfs member, read with `blkid` on the whole disk and on each partition (the
  backing disks are unpartitioned), before the size cap.~~
- ~~**Refuse dev secrets** on a host with no `dev` link, and list untracked files in the
  checkout.~~
- ~~**`--bench`** (§ *The bench boot*) and **`--card <device>`** (§ *One card*).~~
- ~~**The first-boot script safe to re-run**, and `leap/README.md` and `firstboot.sh` no
  longer saying a failed run leaves the image unconfigured.~~
- ~~**When the config came from a partition on the boot disk,** the script grows root's
  filesystem to its partition.~~

## The plays

- ~~`server-update-leap.yml` pings `zero` as its tailnet peer, so `-e target=zero` pings
  itself. The peer becomes a host var, `three` for `zero`.~~
- ~~`server-create-restore-key.yml` reads `hosts/<host>/system/rsyncd-backup.conf`
  directly and calls `/usr/local/bin/tailscale`. Both follow `MOVED` and the package's
  path.~~
- `server-setup-leap.yml` sets `zero` up on the day, as it sets up `one` and `three`. It
  refuses a host outside the inventory's `leap` group and one without
  `hosts/<host>/leap/MOVED`, so `zero` joins the group in the commit that adds its
  `MOVED`, on the day, before the play runs.
- `server-install-packages.yml` stays Alpine-only and refuses `zero` once it has moved,
  through `_alpine-only.yml`; it is already filed under *Open items*.
- The tunnel plays and `server-install-tailscale.yml` refuse `zero` through
  `_alpine-only.yml` once `MOVED` exists.

## A late or missing array

No guard is added (the owner's call 7). On a boot where the array mounts late, Immich's
server and its database start against the bare mountpoints, which sit on the read-only
root, so every write fails and Docker restarts them under `restart: always`. Docker sets
up a container's bind mounts at each start, so the first restart after the array mounts
sees it, and Immich comes back without a hand. Syncthing does the same. pearl-wallet does
not use the array and runs throughout. `zero`'s simulation shows it with a stand-in: a
container under `restart: always` that exits without a file on the array, `zero` booted
with the SSD alone, and both hard disks plugged in after Docker has started, inside the
180 s device timeout. bcache, `data-4` and both mounts came up by themselves, and the
container came back on the array. Immich's own containers start only on the day, so the
proof is for a container that fails without the array. A disk later than the timeout is
not tested. Phase 16's gate is this proof: with protection on, every boot is a late array
until the owner unlocks it.

## One card

The owner's call 14. Combustion reads any filesystem labelled `combustion`, and a
partition on the SD card itself counts, so the stick's contents can go on the card. The
visit kept the stick because this was untried (2026-11-04).

- **Layout.** The image is a 512 MB `EFI` partition then `ROOT`, with root last, and
  `kiwi-repart` grows root to fill the card at first boot (CI run 44271041125). A
  partition after root would block that. So `make-stick --card <device>`, run on a card
  just flashed with the image, grows root's partition entry to all but the last
  256 MB and makes an ext4 `combustion` partition there with the same payload a stick
  gets. It refuses a card that does not read exactly as the image (two partitions, root
  last, nothing after it) and never erases it.
- **Root's filesystem** stays at the image's 3.8 GB until the first-boot script grows it
  with `btrfs filesystem resize max` through a writable subvolume, before the play's
  package snapshot needs the room.
- **The partition goes after the day's checks.** Unlike a stick it cannot be pulled out,
  and a boot caught by the relabel trap (§ *Traps already known*) would re-run Combustion
  from it. A handover block deletes it and hands its space to root. The first-boot
  script is safe to re-run, which this route requires.
- **Secrets.** Everything the partition carries also lands on the root filesystem, so it
  is a second copy, there until it is deleted.
- **The bench card proves it**, with `make-stick --bench --card`: Combustion ran, root
  fills the card, the partition went cleanly. Nobody has tested whether `kiwi-repart`
  leaves a card laid out this way alone. If it refuses instead, its initrd hook fails
  before Combustion and the box never answers ssh. The tell is the card itself: no
  `firstboot:` line at all in the raw search (`leap/README.md`) means the initrd stopped
  before the script, not the script.

## The bench boot

A spare SD card with the newest build, as downloaded to `two`, and a minimal Combustion
config, booted on `zero` with the Alpine card out, to prove the Pi 5 boots the image and
reaches the LAN before the day.

- **The config:** `leap/make-stick --bench --card` (§ *One card*) writes only a script
  that installs gavin's `authorized_keys` and password hash, a sudo rule that asks for
  that password, enables sshd and gives the wired port `192.168.86.100` (call 15). It
  carries no host key, root password, tunnel credential, key file or Tailscale state.
- **The disks are unplugged** (*agent's call*). The image would not touch them, since
  nothing names them in its fstab and `bcache-tools`, whose udev rule registers bcache
  devices, is not in it. Unplugging removes the question. USB power with the disks is
  already proven under the same firmware.
- **The owner reaches it** from the LAN with a throwaway host key:
  `ssh -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no gavin@192.168.86.100` from
  Windows, `/dev/null` in place of `NUL` elsewhere. Then a read-only check block: the
  kernel, the RP1 Ethernet link and whether `rp1_pci` loaded, `modinfo bcache dm_crypt
  adiantum`, `lsusb`, `dmesg` warnings, health-checker's state, and on one card
  `lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/mmcblk0` with `journalctl -b | grep -i repart`.
  `dmesg`, health-checker's state and deleting the partition need `sudo`.
- **After it:** power off, the Alpine card back in. The spare card is erased whole and
  flashed again for the day, since Combustion runs on a first boot only, and a new image
  leaves the card's last 256 MB, with gavin's hash in it, as they were. `zero`'s services
  are down for the length of the bench boot.

## The simulation

Built: `sim/microos/run-host.sh zero` sets `zero` up as the routine does, as it does
`one` and `three`: its real first-boot script, offline, then `server-setup-leap.yml` from
the runner. `zero` has not moved, so the run clones the commit under test and commits on
top of it `hosts/zero/leap/MOVED` and its stand-ins (the store's id, and `three`'s pull
key and address in `backup-authorized-keys`), as the owner commits `MOVED` before the
play on the day. New: `sim/microos/host/zero.sh`, `checks-zero.sh` and `zero-disks/`, and
`zero` in `microos-sim.yml`'s matrix. Green in CI run 45875926818.

**The disks** are a partitioned SSD (p1 a bcache cache, p2 btrfs with Alpine's store and
the new one at the stand-in id, p3 swap), two backing disks attached to p1's cache set,
LUKS2 `data-luks-4` with Adiantum on one of them, opened by a stand-in key file, and btrfs
RAID1 over the other bcache device and `data-4`, with `zero`'s UUIDs and subvolumes made
so their ids come out at 278 and 281. They are built in a separate first VM boot, inside
the guest, as `run-late-disks.sh` builds its array, then attached to a fresh VM for the
first boot. That keeps `make-bcache` and `cryptsetup` off the runner (*agent's call*).

**The checks, built:** both bcache devices attached and writethrough; `data-4` open with
no passphrase asked; btrfs RAID1 with two devices; each mount by subvolid with
`context=`; Docker on the new store; swap on the SSD; gavin at 1001; the key file, the
Tailscale state and the restore key in place, the Tailscale state told from a new one by a
key of the run's that `tailscaled` keeps; no secrets directory; the `backup` user, and
`three`'s pull from the runner listing the `snapshots` module through the forced command;
the hourly snapshot with SELinux enforcing and no denial (§ *snapper* for what the first
run found); no `security.selinux` item anywhere in the array's trees, read off the device,
so the Alpine card reads the array as it left it; `pearl-wallet`'s volume restored; the
deploy play's plan for Immich and Syncthing; and a late array (§ *A late or missing
array*). The play is run again as for every host: nothing changes, it restarts by its rule
and reports extras.

**Not built:**

- **The failures:** a boot with the key file missing, and one with a backing disk missing,
  to record what the box does.
- **The second run with the `combustion` partition on the boot disk** (§ *One card*). The
  bench boot is the first run of that route.
- **Immich's `/etc/localtime:ro` bind under SELinux**, and `pearl-wallet`'s `,z` binds:
  only a real `up` shows them, and the simulation plans in `--check`. `pearl-wallet` is
  not planned at all, since its image is built on the box and its preflight hook refuses
  a volume with no wallet.

**What it cannot prove:** the Pi 5 boots the image, RP1 Ethernet, USB power with 2.5"
disks, the Sabrent bridges, aarch64 images, and the real array's ids. A bench boot and a
paste from the box cover those.

## Before the day

1. **Phase 10's removal**, so no dev secret reaches the stick and the store has room.
2. **`zero`'s host checkout accounted for:** the worktrees and commits under
   `~gavin/infra/.claude/` (above).
3. **The new store subvolume** made on `sda2` under Alpine, its id committed.
4. ~~**The repo work**: `hosts/zero/leap/`, `make-stick`, the first-boot script, the
   plays.~~ Done (§ *The build*); `MOVED` and the inventory's `leap` group wait for the
   day.
5. ~~**The simulation**, passing in CI.~~ Done, run 45875926818.
6. **`pi-image.yml` checks the Pi 5 and the array's modules**: the `bcm2712` device tree,
   the `[pi5]` section, the RP1 Ethernet driver in the initramfs, and `bcache`,
   `dm-crypt`, `adiantum`, `nhpoly1305` and the `xchacha` modules in the kernel, for the
   build `zero` will boot. Today they are proven only on the x86_64 image the simulation
   boots.
7. **The newest build downloaded to `two` and checked** (call 12), against openSUSE's
   `.sha256`, as `plans/visit-runbook.md` § The Pi image says. It is the file the bench
   and the day both use.
8. **The bench boot** (above), on one card.

## The day

The routine every Leap Pi now takes (`plans/pi-setup.md` § The routine), with `zero`'s
carry-over.

1. On Alpine, after `three`'s last pull has finished: stop Immich, Syncthing and
   pearl-wallet (`server-stop-deployments.yml`), then `make-stick` on `zero`: with
   `--card` onto the new card if the bench proved one card, onto a stick otherwise.
2. Power off. Every disk attached, so the play's reboots open the array. The new card in,
   and the stick if there is one, power on.
3. The first boot runs, offline. The owner reads `zero`'s DHCP address from the router or
   the console and reaches it through `one`, checking the carried host key against the
   pinned one: `ssh -J one -o HostKeyAlias=zero gavin@<address>`.
4. On the control node, one commit, pushed: `hosts/zero/leap/MOVED`, and `zero` in the
   inventory's `leap` group. The play refuses `zero` without both.
5. The play, from the control node: `ansible-playbook playbooks/server-setup-leap.yml -e
   target=zero -K -e ansible_host=<address> -e 'ansible_ssh_common_args=-J one -o
   HostKeyAlias=zero'`. It asks before each of its two reboots. After the second, `zero`
   answers at `192.168.86.100` with the array open, and the play proves the tunnel and the
   tailnet answer at the old address.
6. Checks: the array mounted with both devices, `data-4` open, gavin at 1001, the ssh host
   key unchanged.
7. Restore pearl-wallet's volume (`leap/README.md` § *After the first boot: the named
   volumes*). Deploy Immich and Syncthing, then pearl-wallet.
8. Run `three`'s pull by hand and read its result.
9. On one card: delete the `combustion` partition and grow root into its space. Slice 4's
   checks run again later.

**The way back,** at any step: power off, the Alpine card in, power on, and from step 4 on
revert that commit, so the tools read `zero`'s Alpine copies again. Alpine's Docker store
is untouched, the array carries no labels from Leap, and Immich's database is the same
version on both. Any snapshot snapper took on Leap stays readable to Alpine's snapper,
which continues the numbering.

## Traps already known

- A first boot with a data disk missing goes to emergency mode despite `nofail`
  (`leap/README.md` § *What the November visit's first boots taught*): the relabel units
  Combustion's boot makes, one per fstab entry. Under the routine that boot's fstab has no
  data entry, since the play appends them, so the trap has nothing to wait for there.
  Whether a boot the play reboots into relabels as well is not shown, so every disk stays
  attached on the day.
- A data mount names its subvolume by `subvolid=`, never `subvol=`, or health-checker can
  strand the box (`plans/microos-cutover.md`). `zero`'s Alpine store line uses `subvol=`;
  its Leap line names the new subvolume by id.
- Every array entry needs `context=system_u:object_r:container_file_t:s0`; home-dir binds
  need `:z` (`decisions.md`, calibre-web's row).
- ~~The first-boot script is not safe to re-run, and the docs overstate its rollback.~~
  Fixed by § *The build*, item 2.

## Open questions for the owner

The build found three, 2026-11-24. The pin and root on the bench are calls 12 and 15.

1. ~~**The Pi 5's first-boot network** (§ *What `zero` has*). The agent's recommendation:
   split `zero`'s first boot. Combustion does only what needs no network (users, keys,
   the carried files, fstab), and a one-shot unit in the booted system installs the
   packages, clones the repo and reboots once. Also a report to openSUSE. Set aside for
   now: rebuilding the card's initrd by hand; a USB Ethernet adapter whose driver the
   initrd carries.~~ Answered 2026-11-25 for every Leap Pi: Combustion needs no network,
   and the play does the rest from the control node (`plans/pi-setup.md`,
   `decisions.md` § *Every Leap Pi*).

## The build

On the branch `zero-leap`, one commit per task, each by a sub-agent and reviewed; then a
whole-branch Fable review, its findings applied in their own commit, and a merge to
`main` on the owner's word. Since 2026-11-25 the branch also carries the routine every
Leap Pi now takes (`plans/pi-setup.md`): openSUSE's image, an offline Combustion config,
then `server-setup-leap.yml`. `zero`'s part is built in that shape.

1. ~~**`leap/make-stick`:** the carry-over above, the disk guard, refusing dev secrets,
   listing untracked files, `--bench`, `--card`; `leap/README.md` to match.~~
2. ~~**`leap/firstboot.sh`:** `check_carry` entries and installers for the new items, the
   Tailscale state staged to survive the transactional-update shell, every step safe to
   re-run, root grown when the config came from the card, and the rollback claim
   corrected in it and in `leap/README.md`. `one`'s and `three`'s simulations still
   pass.~~
3. ~~**`hosts/zero/leap/`:** `combustion/script`, `fstab.append` with the store's id as a
   `FILL-FROM-` placeholder until the subvolume exists, `system/` as § *The files* lists,
   `volumes`; pearl-wallet's config binds gain `,z`.~~ Done 2026-11-26, with an offline
   `combustion/script`, the play's vars in `ansible/host_vars/zero.yml`, and
   `snapper-immich.service` and `.timer` for the snapshots (§ *snapper*). `zero` stays
   out of the inventory's `leap` group until its `MOVED`.
4. ~~**The plays:** `server-update-leap.yml`'s `tailnet_peer` a host var, `three` for
   `zero`; `server-create-restore-key.yml` reading through `MOVED` with the package's
   `tailscale` path.~~
5. ~~**The image:** the newest build; `pi-image.yml` and
   `sim/pi-image/inspect.sh` checking the Pi 5, the array's modules and that
   `bcache-tools` is absent; `leap-pins.yml` reconciled with the visit runbook.~~
6. ~~**The simulation:** `host/zero.sh`, `checks-zero.sh`, the disk-building boot, `zero`
   in `microos-sim.yml`'s matrix, the checks in § *The simulation*.~~ Done 2026-11-26,
   run 45875926818.
7. **The simulation's second run with the `combustion` partition on the boot disk**
   (§ *One card*), and the failure boots (§ *The simulation*, not built). Open; the bench
   boot covers the card route meanwhile.
8. **Docs:** `hosts/zero/system/README.md`'s stale lines and a way-back note, the phase
   12 row.

**What the owner does**, each on the owner's word and nothing before it:

- **Before the day:** the items in § *Before the day* still open: phase 10's removal,
  the host checkout accounted for, the store subvolume made under Alpine and its id
  committed in place of `FILL-FROM-ZERO-STORE-SUBVOLID`, the newest build on `two`.
- **The bench boot** (§ *The bench boot*): `make-stick --bench --card` on the spare card,
  `zero` booted from it with the Alpine card and the disks out, the read-only check block,
  then power off and the Alpine card back.
- **The day** (§ *The day*): the stick or card, the offline first boot, the commit of
  `MOVED` and the `leap` group, the play from the control node, then the restores and
  deploys.
