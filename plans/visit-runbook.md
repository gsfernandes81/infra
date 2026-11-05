# The November visit, slice by slice

The runbook for [`microos-cutover.md`](microos-cutover.md): what the owner does at the
cluster, one section per slice, each ending with the fleet working. Each slice has what
must be true before it, its steps, the checks that say it worked, and its way back. When
the visit is done, what stays true moves to `docs/decisions.md` and the host READMEs, and
this file is deleted.

Every block is fish, pasted into a shell on the box its comment names (`ssh <host>` first:
`ssh host 'sudo …'` hangs, CLAUDE.md § Privileged commands). The infra agent is the
session in the `infra` container; it commits the values the steps send it.

## The slices

The owner decided on 2026-11-05 that slice 1's bench test runs with the old `one` powered
off, and that what passes there stays: slices 1 and 3 of the plan are one slice.

| # | Slice | Hours | Ends with |
|---|---|---|---|
| 1 | `one` moves to the 8 GB board on its new card, the old board kept as the way back | 2 | `one` serving from the 8 GB board, on Leap |
| 2 | `zero`'s disk swap, borrowing `one`'s Sabrent | 2 | `zero` on the new disk, still on Alpine |
| 3 | the 1 GB board into the Argon as `three`, with the first WD Red; the first backup | 2 | seeding over the LAN, unattended |
| 4 | a restore from one of `three`'s snapshots; Syncthing on `three` if its memory allows | 1 | the backup proven |
| | spare | 3 | |

Slice 2 and slice 1 never share a day. Slice 3 waits a day after slice 1, because the old
board is slice 1's way back until then, unless the Alpine card has booted on the 8 GB board
(slice 1, step 2), which makes the 8 GB board its own way back.

## Before the visit

Over ssh, from the phone, any day before. Each is a step a slice would otherwise wait on.

1. **`zero` on the tailnet, and its backup key.** First, in the tailnet's admin console,
   auto-update off and a `tagOwners` entry for `tag:fleet` in the policy (`decisions.md`).
   Tailscale's repo has nothing for Alpine, so zero runs Tailscale's own static build,
   checked against its published SHA-256, with the tracked service
   `hosts/zero/system/tailscaled`. After `ssh zero`:

   ```fish
   # install Tailscale 1.104.5's static arm64 build, checked against Tailscale's published SHA-256
   cd /tmp; curl -fLO https://pkgs.tailscale.com/stable/tailscale_1.104.5_arm64.tgz
   echo 'e900b0e6e25023a1e504b2c237ce2a32ea0535e006f8c1a1097a490886493b6c  tailscale_1.104.5_arm64.tgz' | sha256sum -c -; and tar -xzf tailscale_1.104.5_arm64.tgz
   sudo install -m 755 tailscale_1.104.5_arm64/tailscaled /usr/local/sbin/tailscaled; and sudo install -m 755 tailscale_1.104.5_arm64/tailscale /usr/local/bin/tailscale
   rm -rf /tmp/tailscale_1.104.5_arm64 /tmp/tailscale_1.104.5_arm64.tgz
   ```

   ```fish
   # install zero's tailscaled service from the repo, start it, and join the tailnet as a fleet node
   cd ~/infra; and git pull; and sudo bin/install-system-file tailscaled --commit --allow-content-change --new
   sudo rc-update add tailscaled default; and sudo rc-service tailscaled start
   sudo tailscale up --advertise-tags=tag:fleet
   ```

   Open the URL the last line prints on the phone. Then the three lines in
   [`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § Before the stick. Send
   the infra agent the key and the address they print; until it commits them,
   `make-stick` refuses `three`'s stick. zero's Tailscale moves by hand, the same way, to a
   new version and its SHA-256 from `https://pkgs.tailscale.com/stable/`.
2. **`rsync` on the Alpine hosts**, from the control node:
   `ansible-playbook playbooks/server-install-packages.yml -K`.
3. **The new `PermitOpen`** (it adds `three`'s `.103`) on `zero`, `one` and `two`. The infra
   agent writes the handover; each host's sshd reloads only through a way in that is not
   that sshd.
4. **An ntfy topic** for the backup's age alert, its URL in root's
   `/var/lib/mirror-backup/ntfy-url` on `zero`, mode 600 (`hosts/zero/system/README.md`).

## Writing a card, and building a stick

Both are erased whole, so each step names the device and checks it before writing.

**The card**, on whichever Alpine host has a free port for the card reader, `two` likely.
`two` is a Pi 1: the unpacking takes a long while there, so start it early. After
`ssh two`, with the reader in and the card in it:

```fish
# download Leap 16.1's Pi image, build 3.13, and check it against the SHA-256 openSUSE published for it
df -h ~
cd ~; curl -fLO https://download.opensuse.org/distribution/leap/16.1/appliances/Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.13.raw.xz
echo 'db929eaa51c6f20e37214349609a3d65bb305ccbf59abdea086596116cb5592b  Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.13.raw.xz' | sha256sum -c -
```

It needs about 1.3 GB free in `~`, and `sha256sum` must print `OK`. Then, with the card
reader's device read off `lsblk` (its size is the card's):

```fish
# write the image to the card; put the card's device in place of /dev/sdX after reading lsblk
lsblk -o NAME,SIZE,MODEL,TRAN
xzcat ~/Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.13.raw.xz | sudo dd of=/dev/sdX bs=4M conv=fsync; and sync
```

Label the card with the host's name: a host's name follows its card.

**The stick** is `leap/make-stick`, on the host's own old system for `one`, and with `--new`
on any Alpine host for `three` ([`leap/README.md`](../leap/README.md)). It asks for the
device name before it erases anything. Once the host it built has booted and answered,
the stick holds live secrets until it is erased:

```fish
# erase a first-boot stick once its host is proven; put the stick's device in place of /dev/sdX
lsblk -o NAME,SIZE,MODEL,TRAN,LABEL
sudo blkdiscard /dev/sdX
```

## Slice 1: `one` moves to the 8 GB board

**Before:** a card written as above and labelled `one`; a stick to hand; `one`'s live slots
checked, since its reboot ends them; a quiet hour for `one`'s apps to be down.

1. **Build `one`'s stick, on the old `one`.** `make-stick` refuses while a container uses a
   carried volume, so garmin-mcp stops first. After `ssh one`:

   ```fish
   # stop garmin-mcp, whose token volume the stick carries, then build one's stick
   cd ~/infra/deployments/garmin-mcp; and sudo docker compose stop
   cd ~/infra; and git pull; and sudo leap/make-stick one /dev/sdX
   ```

2. **Optional, and worth it: the Alpine card on the 8 GB board.** Power the old `one` off
   (`sudo poweroff`), move its Alpine card and its Sabrent, with the SSD, to the 8 GB board,
   and power it on. If `ssh one` answers and `docker ps` lists its apps, the 8 GB board is
   its own way back and slice 3 need not wait a day. Power it off again.
3. **Boot Leap.** The new card in the 8 GB board, the Sabrent with the SSD on its USB 3
   port, the stick in another port, the Ethernet in, and power on. The first boot takes
   several minutes, since it installs packages before it answers. Then, from the phone,
   `ssh one`; the host key is `one`'s own, so no warning. Then erase the stick.
4. **The named volume, then the apps.** The garmin-mcp volume restore in
   [`leap/README.md`](../leap/README.md) § After the first boot, then from the control node,
   one deployment at a time, `ansible-playbook playbooks/server-deploy-compose.yml -e
   deployment=<name> -K` for `calibre-web`, `garmin-mcp`, `send2ereader` and `torrents`.
   garmin-mcp's play pauses at its Garmin login.
5. **The second way in.** After `ssh one`, `sudo tailscale up --advertise-tags=tag:fleet`,
   and open the URL it prints.

**Checks:**

- `ssh one` answers through the tunnel, and `tailscale status` on `one` lists it online.
- `systemctl --failed` is empty, or lists only `import-pubring-from-rpmdb.service`, which
  openSUSE fails on a first boot and clears at the next (`sim/microos/README.md`).
- `findmnt /var/lib/docker` names `var-lib-docker-leap`, and `docker ps` lists each app.
- Each app answers at its own hostname.
- **Bench checks, recorded in the phase table:** `rpm -q kernel-firmware-brcm` (Wi-Fi for
  `three`); `sudo grub2-editenv - list` and `journalctl -b -u health-checker`, to see
  whether health-checker can clear its boot flag on a Pi (`microos-cutover.md` § Still
  open); `firewall-cmd --list-all` after `tailscale up`, to see Tailscale through
  firewalld; and a serial console, if a USB serial adapter is to hand.

**Way back:** power off, the Alpine card and the Sabrent back on the old board (or on the
8 GB board, if step 2 passed), power on, and `ssh one`. The SSD is as Alpine left it:
Leap's Docker uses a subvolume of its own and the data mounts carry `context=` without
writing labels.

## Slice 2: `zero`'s disk swap

Not the day of slice 1. Every step, its checks and its order are in
[`three.md`](three.md) § *`zero`'s disk swap*: it borrows `one`'s Sabrent, so `one` is off
for its length, and nothing reboots between `btrfs replace` starting and `btrfs replace
status` reading finished. The value it sends the infra agent is the new member's bcache
UUID, for `bcache-register`.

**Checks:** `btrfs device usage /media/immich-data` shows the new device and not `sdb`'s;
`sudo bin/check-mount-guards` passes after the reboot; Immich answers.

**Way back:** before `btrfs replace` finishes, `btrfs replace cancel` leaves `sdb` where it
was. After, there is none: `sdb` is out of the array, and the array is whole on the new disk
and the WD Elements.

## Slice 3: `three` joins

**Before:** a day after slice 1, or step 2 of it passed; the stick buildable (Before the
visit, step 1); `one`'s old board free; a card written and labelled `three`.

1. **Build `three`'s stick** on any Alpine host with a free port, `zero` or `two`:
   `cd ~/infra; and git pull; and sudo leap/make-stick --new three /dev/sdX`. It asks for
   `three`'s root password, the console's, and prints `three`'s host key fingerprint:
   write it down.
2. **Boot.** The 1 GB board into the Argon, the WD Red in a middle bay, the card, the stick,
   the Ethernet, power. From the phone on the home Wi-Fi, once the first boot has finished
   installing: `ssh gavin@192.168.86.103`, and check the fingerprint it asks about against step 1's.
   Then erase the stick.
3. **The drive.** Its serial checked with WD, and `sudo smartctl -d sat -i -A -l scterc
   /dev/sdX` read (`three.md` § The Argon EON), then the array made and unlocked, as
   [`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § The array says.
4. **The two ways in.** After `ssh gavin@192.168.86.103`,
   `sudo tailscale up --advertise-tags=tag:fleet`; then the tunnel, as that README's §
   After the first boot says, with the infra agent adding `three` to the inventory.
5. **The backup.** Send the infra agent `three`'s address from `tailscale ip -4`; it fills
   it into `mirror-backup` and writes the install for `zero` of `mirror-backup`,
   `mirror-backup-age` and their state directory. Then the first push, by hand, after
   `ssh zero`:

   ```fish
   # start the first push to three now, not at 04:00; it seeds about 120 GB and runs for hours
   sudo /etc/periodic/hourly/mirror-backup now &
   ```

**Checks:** `sudo tail /var/lib/mirror-backup/last.log` on `zero` grows, and `sudo du -sh
/media/mirror/incoming` on `three` climbs; `free -m` on `three` stays clear of its swap. The
next morning, `last-success` on `zero` is recent and `three` has a snapshot dated today.

**Way back:** none needed: nothing depends on `three`. Power it off.

## Slice 4: the backup proven

1. **A restore**, as [`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § The
   backup says, of Immich's library from today's snapshot into `/media/mirror/restore/`.
   Then compare it with zero's: `sudo find /media/mirror/restore/library -type f | wc -l` on
   `three` against `sudo find /media/immich-data/library -type f | wc -l` on `zero`, and
   `stat` one file on each for its owner and mode. Then `sudo rm -rf /media/mirror/restore`.
2. **Syncthing on `three`,** if `free -m` showed room through the seeding:
   `ansible-playbook playbooks/server-deploy-compose.yml -e deployment=syncthing-three -K`,
   then its GUI through `three`'s tunnel. Watch `free -m` for a day.
3. **A lock and an unlock,** to see both commands work on the real drive: the lock prints
   `locked`, and the unlock asks for the passphrase again.

**Checks:** the counts match, the owner and mode match, and Syncthing's GUI answers.

**Way back:** for Syncthing, `docker compose down` in its deployment; nothing else changes.

## After the visit

Over ssh: the dev hub moves to `one`, at a quiet time and not in a slice; podman later.
`three` ships to Singapore at a date the owner picks, after
[`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § Before three ships.
