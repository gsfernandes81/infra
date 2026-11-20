# `zero` moves to Leap 16.1 Immutable

A design from 2026-11-20, for the owner to review before anything is built. It moves
`zero` from Alpine to openSUSE Leap 16.1 in its Immutable mode, as `one` and `three` moved
at the November visit. When it is done its reasoning moves to
[`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

**For the owner's approval.** Nothing here is decided beyond the owner's calls below.
Calls marked *agent's call* are the design's own and the owner can overturn any of them.
Phase 12 in `docs/management-plane.md`, ordered after 10 and 11.

## The owner's calls, 2026-11-20

1. **The day:** the owner is at `zero` with two things ready, a new SD card with Leap and
   a USB stick for Combustion. They boot `zero` from the new card, finish over ssh, and
   it is done.
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
12. **Build 3.17** of the Pi image.

## What `zero` has that `one` and `three` did not

Each of these is new to a Leap first boot, and each is the reason for a piece of work
below.

- **A Pi 5.** No Pi 5 has booted Leap on this fleet. The pinned image carries
  `bcm2712-rpi-5-b.dtb` and a `[pi5]` section in `config.txt` (CI run 43361792126), but
  nothing has checked that its kernel and initramfs drive the Pi 5's Ethernet, which sits
  behind the RP1 chip. The first boot needs a wired LAN, since the initramfs has no Wi-Fi
  (`leap/README.md`). The simulation is an x86_64 VM and cannot answer this.
- **LUKS above bcache, opened at boot from a key file.** The encrypted member is the WD
  Red Plus, its bcache backing device, then LUKS2 `data-luks-4`, mapping `data-4`, then
  btrfs devid 4 (`hosts/zero/system/dmcrypt:13-15`). `three`'s LUKS is a passphrase,
  `noauto`, unlocked over ssh. Nothing on Leap has opened LUKS from a key file, and
  nothing has stacked it on bcache. bcache-tools' udev rule assembling the devices is
  proven without LUKS (`plans/microos-cutover.md` § late disks).
- **A tailnet identity that others depend on.** `three`'s pull reaches `zero` at
  `100.121.158.58` with `StrictHostKeyChecking yes`
  (`hosts/three/leap/system/backup-ssh-config`), and `three`'s restore key accepts only
  that address (`restore-authorized-keys:18`). `one` and `three` joined the tailnet fresh
  after their first boots. `zero` cannot.
- **The backup source.** The `backup` user, its forced `rsync --daemon` through `setpriv`,
  snapper's `immich` config and its hourly snapshots. All installed on Alpine on
  2026-11-20, none yet on Leap.
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

What crosses from Alpine to Leap on the stick, and what does not. The third column is the
design; where it differs from the second, the work is listed under *What `make-stick` and
the first-boot script need*.

| Item | Today | For `zero` |
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

**Where the Tailscale state lands is not proven.** The first-boot script runs inside a
transactional-update shell that binds only `/root`, `/var/log` and a few `/var` paths, so
a write to `/var/lib/tailscale` may vanish as writes to `/home` did before
`mount_subvolumes`. The script mounts `/var` or stages the file and the simulation proves
it survives the reboot.

## The files

Every Leap copy changes its header to `infra-os: leap`, `infra-init: systemd`. The new
directory is `hosts/zero/leap/`, laid out as `one`'s.

| Alpine file | Leap form |
|---|---|
| `fstab` | `leap/fstab.append`: the array's `/mnt/ext`, `/media/immich` (subvolid 281), `/media/syncthing` (278), swap on `sda3`, Docker's store on `sda2` by a new subvolid. Each line gains `x-systemd.device-timeout=180s`; the array lines gain `context=system_u:object_r:container_file_t:s0`, `/mnt/ext` included, since they share one superblock. No `autodefrag`. Root, boot and tmpfs lines are the image's own |
| `bcache-register` | nothing: bcache-tools' udev rule. `bcache-tools` is not in the shared package list, so `zero`'s script installs it |
| `dmcrypt`, `dm-crypt.conf` | `system/crypttab`: `data-4 UUID=c00f99a6-… /etc/keys/data.key luks,nofail` with a device timeout, not `noauto` while protection is off; no `discard`. No modules-load file, once `pi-image.yml` shows the Pi image's kernel carries dm-crypt and Adiantum's modules (below) |
| `zram-swap` | `system/zram-generator.conf`, `one`'s verbatim (2G, zstd, priority 100) |
| `cloudflared`, `cloudflared-config.yml` | `one`'s `cloudflared.service`, pinned binary, `--no-autoupdate`; the config's body unchanged apart from stale comments |
| `sshd-infra.conf` | `one`'s, with `KbdInteractiveAuthentication no` |
| `tailscaled` | Tailscale's repo package (`one`'s `tailscale.repo`) and its unit, with the carried state |
| `snapper-config-immich` | its header, and its comment saying Leap's timers take over |
| `snapper-sysconfig`, `snapper-immich` | `snapper --no-dbus` with `immich` kept out of `SNAPPER_CONFIGS`, as `three` runs it (*agent's call*), from a new hourly service and timer: create then cleanup, with `RequiresMountsFor=/media/immich`. `three`'s own snapshot fires after its daily pull, not on a timer, so the timer is new. One snapper pattern on the fleet, hourly cleanup kept, and the mount check kept. Leap's own timers would clean up daily and lose the check. `snapper-sysconfig` stays on Alpine |
| `sudoers-backup`, `backup-authorized-keys` | `/bin/setpriv` becomes `/usr/bin/setpriv` in both, in the same commit, as `three`'s `sudoers-restore` and `restore-authorized-keys` have it |
| `rsyncd-backup.conf` | unchanged apart from its header |
| `backup-age-check` | stays on Alpine, not installed |
| `devpool` | deleted with phase 10's end |
| none | from `one`: `wired.nmconnection` at `192.168.86.100`, `rebootmgr.conf`, `transactional-update.conf`, `sudoers-gavin`, `docker-mounts.conf` |
| none | `combustion/script`, from `one`'s, with gavin and his group at 1001, the `backup` user with a real shell (sshd runs the forced command through it), its root-owned home, the key file, the Tailscale state, the restore key, and `/media/immich`, `/media/syncthing` made as bare mountpoints |
| none | `volumes`: `pearl-wallet_wallet` |
| none | firewalld: `firewall-offline-cmd --add-service=syncthing` in `combustion/script`, as `three`'s has it (22000 tcp and udp, 21027 udp) |
| none | `MOVED`, committed on the day once `zero` answers |

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

- **Carry** the key file, the Tailscale state and the restore key, each with a
  `check_carry` entry, and refuse when the key file is absent on a host whose `crypttab`
  names it.
- **A disk guard for `zero`:** refuse any disk holding a bcache superblock, a LUKS header
  or a btrfs member, read with `blkid` on the whole disk and on each partition (the
  backing disks are unpartitioned), before the size cap.
- **Refuse dev secrets** on a host with no `dev` link.
- **The first-boot script safe to re-run**, and `leap/README.md` and `firstboot.sh` no
  longer saying a failed run leaves the image unconfigured: writes to `/home`,
  `/usr/local`, `/root`, `/var` and the FAT partition survive one (phase 12's
  prerequisites). Each step checks what it would create (the group, the users, the clone,
  the fstab lines) and skips it when present.

## The plays

- `server-update-leap.yml` pings `zero` as its tailnet peer, so `-e target=zero` pings
  itself. The peer becomes a host var, `three` for `zero`.
- `server-create-restore-key.yml` reads `hosts/<host>/system/rsyncd-backup.conf` directly
  and calls `/usr/local/bin/tailscale`. Both follow `MOVED` and the package's path.
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
not use the array and runs throughout. The simulation proves this by attaching the array
after Docker has started. Phase 16's gate is this proof: with protection on, every boot is
a late array until the owner unlocks it.

## The bench boot

A spare SD card with build 3.17 and a minimal Combustion config, booted on `zero` with
the Alpine card out, to prove the Pi 5 boots the image and reaches the LAN before the day.

- **The stick:** `leap/make-stick --bench` writes only a script that installs gavin's
  `authorized_keys`, enables sshd and gives the wired port `192.168.86.100`. It carries
  no host key, password hash, tunnel credential, key file or Tailscale state.
- **The disks are unplugged** (*agent's call*). The image would not touch them, since
  nothing names them in its fstab and `bcache-tools`, whose udev rule registers bcache
  devices, is not in it. Unplugging removes the question. USB power with the disks is
  already proven under the same firmware.
- **The owner reaches it** from the LAN with a throwaway host key:
  `ssh -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no gavin@192.168.86.100` from
  Windows, `/dev/null` in place of `NUL` elsewhere. Then a read-only check block: the
  kernel, the RP1 Ethernet link, `modinfo bcache dm_crypt adiantum`, `lsusb`, `dmesg`
  warnings, health-checker's state.
- **After it:** power off, the Alpine card back in. The spare card is flashed again for
  the day, since Combustion runs on a first boot only. `zero`'s services are down for the
  length of the bench boot.

## The simulation

`sim/microos/run-host.sh zero` boots `zero`'s real first-boot script, as it does `one`'s
and `three`'s. New: `sim/microos/host/zero.sh` and `checks-zero.sh`.

**The disks** are a partitioned SSD (p1 a bcache cache, p2 btrfs with the store
subvolume at its committed id, p3 swap), two backing disks attached to p1's cache set,
LUKS2 `data-luks-4` on one of them opened by a stand-in key file, and btrfs RAID1 over
`bcache0` and `data-4` with `zero`'s UUID and subvolumes made so their ids come out at 278
and 281. They are built in a separate first VM boot, inside the guest, as
`run-late-disks.sh` builds its array, then attached to a fresh VM for the first boot. That
keeps `make-bcache` and `cryptsetup` off the runner (*agent's call*).

**The checks:** both bcache devices attached and writethrough; `data-4` open with no
password prompt; btrfs with two devices; each mount by subvolid with `context=`; Docker on
the new store; swap on the SSD; gavin at 1001; the `backup` user, its forced command run
end to end with an `rsync` listing of the `snapshots` module; snapper's timer taking a
snapshot; Tailscale's state file present after the reboot; no `security.selinux` xattr
written to a file on the array, so the Alpine card reads the array as it left it; a
pearl-wallet volume restored; the deploy play's plan for Immich and Syncthing.

**And the failures:** a boot with the key file missing, and one with a backing disk
missing, to record what the box does. The first-boot relabel trap predicts emergency mode
on a first boot; the simulation shows what a later boot does.

**What it cannot prove:** the Pi 5 boots the image, RP1 Ethernet, USB power with 2.5"
disks, the Sabrent bridges, aarch64 images, and the real array's ids. A bench boot and a
paste from the box cover those.

## Before the day

1. **Phase 10's removal**, so no dev secret reaches the stick and the store has room.
2. **`zero`'s host checkout accounted for:** the worktrees and commits under
   `~gavin/infra/.claude/` (above).
3. **The new store subvolume** made on `sda2` under Alpine, its id committed.
4. **The repo work**: `hosts/zero/leap/`, `make-stick`, the first-boot script, the plays.
5. **The simulation**, passing in CI.
6. **`pi-image.yml` checks the Pi 5 and the array's modules**: the `bcm2712` device tree,
   the `[pi5]` section, the RP1 Ethernet driver in the initramfs, and `bcache`,
   `dm-crypt`, `adiantum`, `nhpoly1305` and the `xchacha` modules in the kernel, for the
   build `zero` will boot. Today they are proven only on the x86_64 image the simulation
   boots.
7. **`leap/pins` moves to build 3.17** (the owner's call 12), with its SHA-256 from
   openSUSE's `.sha256` file. `one` and `three` booted 3.16, which openSUSE has
   withdrawn; the pin records what the next first boot uses.
8. **The bench boot** (above).

## The day

1. On Alpine, after `three`'s last pull has finished: stop Immich, Syncthing and
   pearl-wallet (`server-stop-deployments.yml`), then `make-stick` on `zero`.
2. Power off. Every disk attached, as a precondition: a missing one sends the first boot
   to emergency mode. The new card in, the stick in, power on.
3. The first boot runs. The owner reaches `zero` over the LAN at `192.168.86.100`, then
   checks the tunnel and the tailnet answer at the old address.
4. Checks: the array mounted with both devices, `data-4` open, gavin at 1001, the ssh host
   key unchanged.
5. Restore pearl-wallet's volume. Deploy Immich and Syncthing, then pearl-wallet.
6. Run `three`'s pull by hand and read its result.
7. Commit `hosts/zero/leap/MOVED`. Slice 4's checks run again later.

**The way back,** at any step: power off, the Alpine card in, power on. Alpine's Docker
store is untouched, the array carries no labels from Leap, and Immich's database is the
same version on both. Any snapshot snapper took on Leap stays readable to Alpine's
snapper, which continues the numbering.

## Traps already known

- A first boot with a data disk missing goes to emergency mode despite `nofail`
  (`leap/README.md` § *What the November visit's first boots taught*). On `zero` a missing
  key file does the same, since `data-4` stays shut.
- A data mount names its subvolume by `subvolid=`, never `subvol=`, or health-checker can
  strand the box (`plans/microos-cutover.md`). `zero`'s Alpine store line uses `subvol=`.
- Every array entry needs `context=system_u:object_r:container_file_t:s0`; home-dir binds
  need `:z` (`decisions.md`, calibre-web's row).
- The first-boot script is not safe to re-run, and the docs overstate its rollback.

## Open questions for the owner

None. The owner's answers of 2026-11-20 are calls 7 to 12 above.
