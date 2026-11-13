# The November visit, slice by slice

The runbook for [`microos-cutover.md`](microos-cutover.md): what the owner does at the
cluster, one section per slice, each ending with the fleet working. Each slice has what
must be true before it, its steps, the checks that say it worked, and its way back. When
the visit is done, what stays true moves to `docs/decisions.md` and the host READMEs, and
this file is deleted.

Every block is fish, and its first line names the box it runs on, after `ssh <host>`
(`ssh host 'sudo …'` hangs, CLAUDE.md § Privileged commands). Plays run from the control
node, in `~/infra/ansible`, where `ansible.cfg` is read. The infra agent is the session in
the `infra` container; it commits the values the steps send it.

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

**Every Pi joins the tailnet with `--accept-dns=false`**, so Tailscale never takes over a
box's resolver: if `tailscaled` broke, a box resolving through it would lose its tunnel
too (`decisions.md`).

## Before the visit

Over ssh, from the phone, any day before. Each is a step a slice would otherwise wait on.

1. **The Pi image, downloaded and checked on `two`,** and kept there: openSUSE's
   directory holds only the newest build, and builds have turned over within days, so
   the copy on `two` is the one the cards are written from. The pin in `leap/pins` records
   that copy.

   ```fish
   # on two: download Leap 16.1's Pi image, build 3.16, with openSUSE's .sha256 file, and check the image against that file and then against the pin
   df -h ~
   cd ~; curl -fLO https://download.opensuse.org/distribution/leap/16.1/appliances/Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.16.raw.xz.sha256; and curl -fLO https://download.opensuse.org/distribution/leap/16.1/appliances/Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.16.raw.xz
   sha256sum -c Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.16.raw.xz.sha256
   echo '6b224592371168a6991b540bc8e2755383004d6b153f9898a309c2a15d395551  Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.16.raw.xz' | sha256sum -c -
   ```

   It needs about 1.3 GB free, and both `sha256sum` lines must print `OK`: the first
   against openSUSE's file, the second against the pin. If a `curl` answers 404, openSUSE
   has replaced the build. Then take the newest
   `Leap-16.1-Immutable.aarch64-RaspberryPi-Build*.raw.xz` from
   [the directory](https://download.opensuse.org/distribution/leap/16.1/appliances/),
   download it and its `.sha256` the same way, check it with the first `sha256sum` line,
   and move the pin to it: its URL and SHA-256 in `leap/pins` and in this block, in one
   commit. CI fails when the two disagree (`.github/workflows/pi-image.yml`).
2. **The tailnet's settings,** in its admin console: auto-update off, and a `tagOwners`
   entry for `tag:fleet` in the policy (`decisions.md`).
3. **`zero` on the tailnet.** Tailscale's repo has nothing for Alpine, so `zero` runs
   Tailscale's own static build with the tracked service `hosts/zero/system/tailscaled`
   ([`hosts/zero/system/README.md`](../hosts/zero/system/README.md) § Tailscale). Keep the
   first ssh session open until a second one has answered.

   ```fish
   # on zero: check Alpine's own tailscale is absent; go on only if this prints "absent"
   apk info -e tailscale; and echo 'STOP: Alpine tailscale is installed'; or echo absent
   ```

   ```fish
   # on zero: install Tailscale 1.104.5's static arm64 build, checked against Tailscale's published SHA-256
   cd /tmp; curl -fLO https://pkgs.tailscale.com/stable/tailscale_1.104.5_arm64.tgz
   echo 'e900b0e6e25023a1e504b2c237ce2a32ea0535e006f8c1a1097a490886493b6c  tailscale_1.104.5_arm64.tgz' | sha256sum -c -; and tar -xzf tailscale_1.104.5_arm64.tgz
   sudo install -D -m 755 tailscale_1.104.5_arm64/tailscaled /usr/local/sbin/tailscaled; and sudo install -D -m 755 tailscale_1.104.5_arm64/tailscale /usr/local/bin/tailscale
   rm -rf /tmp/tailscale_1.104.5_arm64 /tmp/tailscale_1.104.5_arm64.tgz
   ```

   ```fish
   # on zero: install the tailscaled service from the repo, start it, and join the tailnet as a fleet node, keeping zero's own resolver
   cat /etc/resolv.conf
   cd ~/infra; and git pull; and sudo bin/install-system-file tailscaled --commit --allow-content-change --new
   sudo rc-update add tailscaled default; and sudo rc-service tailscaled start
   sudo tailscale up --advertise-tags=tag:fleet --accept-dns=false
   ```

   Open the URL the last line prints on the phone.

   **Checks:** a second `ssh zero` answers through the tunnel; `cat /etc/resolv.conf` reads
   as it did before; `tailscale status` lists `zero`; `sudo docker ps` lists everything that
   ran before; Immich and the dev hub answer.

   **Way back:** `sudo tailscale down; and sudo rc-service tailscaled stop; and sudo
   rc-update del tailscaled default`, and the node removed in the admin console.
4. **`zero`'s backup key**, the three lines in
   [`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § Before the stick. Send
   the infra agent the key and the address they print; until it commits them,
   `make-stick` refuses `three`'s stick.
5. **`rsync` on the Alpine hosts:** `ansible-playbook playbooks/server-install-packages.yml
   --check --diff -K` to read what it would install, then without `--check`.
6. **The new `PermitOpen`** (it adds `three`'s `.103`) on `two`, then `one`, then `zero`,
   with the same two blocks on each, after `ssh <host>`. `one` needs it even though the
   8 GB board replaces it, because its Alpine card is slice 1's way back. The first block
   is a dry run: with no `--commit` it writes nothing, and `--allow-content-change` lets
   it reach its `sshd -t` checks instead of refusing after the diff. Its diff is the
   `PermitOpen` line, a new comment above it, and two reworded comments, and it ends
   `pre-checks on the repo copy: ok` and `DRY RUN`. If it shows anything else, stop. It
   asks for your sudo password even so, for its `sshd -t` checks.

   ```fish
   # on two: pull, then a dry run of the new sshd drop-in, which shows the diff and writes nothing
   cd ~/infra; and git pull --ff-only; and bin/install-system-file sshd-infra.conf --allow-content-change
   ```

   ```fish
   # on two: install the sshd drop-in, reload sshd, and print the PermitOpen now on disk
   cd ~/infra; and sudo bin/install-system-file sshd-infra.conf --commit --allow-content-change; and sudo rc-service sshd reload; and sudo sshd -T | grep -i permitopen
   ```

   ```fish
   # on one: pull, then a dry run of the new sshd drop-in, which shows the diff and writes nothing
   cd ~/infra; and git pull --ff-only; and bin/install-system-file sshd-infra.conf --allow-content-change
   ```

   ```fish
   # on one: install the sshd drop-in, reload sshd, and print the PermitOpen now on disk
   cd ~/infra; and sudo bin/install-system-file sshd-infra.conf --commit --allow-content-change; and sudo rc-service sshd reload; and sudo sshd -T | grep -i permitopen
   ```

   ```fish
   # on zero: pull, then a dry run of the new sshd drop-in, which shows the diff and writes nothing
   cd ~/infra; and git pull --ff-only; and bin/install-system-file sshd-infra.conf --allow-content-change
   ```

   ```fish
   # on zero: install the sshd drop-in, reload sshd, and print the PermitOpen now on disk
   cd ~/infra; and sudo bin/install-system-file sshd-infra.conf --commit --allow-content-change; and sudo rc-service sshd reload; and sudo sshd -T | grep -i permitopen
   ```

   The last line ends `192.168.86.103:22`; it reads the file on disk, and the second
   session below is what proves the running sshd answers. This is safe over the tunnel.
   `install-system-file` runs `sshd -t` on the file and on the whole config before it
   writes, runs it again after, and puts the old file back if that fails. A reload keeps
   every open session, and the tunnel is not touched. Before you close the session the
   reload ran in, open a second `ssh <host>` and wait for it to answer.

   **Way back:** in the session that is still open, copy back the backup the install named
   after `backed up`: `sudo cp -a <that path> /etc/ssh/sshd_config.d/10-infra.conf; and
   sudo rc-service sshd reload`.
7. **The ntfy topic** for the backup's age alert. Its URL is asked for, never typed on a
   command line:

   ```fish
   # on zero: store the ntfy topic's URL for the backup's age alert, root's alone
   sudo install -d -m 700 /var/lib/mirror-backup
   read -s -P 'ntfy URL: ' u; and printf '%s\n' $u | sudo sh -c 'umask 077; cat > /var/lib/mirror-backup/ntfy-url'; set -e u
   ```

## Writing a card, and erasing a stick

**The card is written on `two`, never on `zero`:** zero's USB disks are Immich's array, and
`dd` writes to whatever device it is given. `two` is a Pi 1, so the write runs detached and
takes a while; the image is there from Before the visit, step 1.

```fish
# on two: read which device the card reader is
lsblk -o NAME,SIZE,MODEL,TRAN
```

```fish
# on two: write the image to the card, detached from this session, only if the device is a USB disk nothing has mounted; put the card's device in place of sdX
set d sdX; readlink -f /sys/block/$d | grep -q usb; and not grep -q "^/dev/$d" /proc/mounts; and sudo sh -c "setsid nohup sh -c 'xzcat /home/gavin/Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.16.raw.xz | dd of=/dev/$d bs=4M conv=fsync && sync && echo written' </dev/null >/var/log/card-write.log 2>&1 &"
```

`sudo cat /var/log/card-write.log` ends with `written` when it is done. Label the card with
the host's name: a host's name follows its card.

**The stick** is built by `leap/make-stick` ([`leap/README.md`](../leap/README.md)), which
asks for the device name before it erases anything. It holds live secrets once built, so
it is erased once its host has passed the slice's checks, on the host it booted. Many USB
sticks cannot discard, so zeros are the fallback:

```fish
# on the host the stick booted: erase the first-boot stick, only if it is the stick; zeros where it cannot discard; put its device in place of sdX
lsblk -o NAME,SIZE,MODEL,TRAN,LABEL
set d sdX; sudo blkid /dev/$d | grep -q 'LABEL="combustion"'; and begin; sudo blkdiscard /dev/$d; or sudo blkdiscard -z /dev/$d; end; and echo erased
```

## Slice 1: `one` moves to the 8 GB board

**Before:** a card written and labelled `one`; a stick to hand; `one`'s live slots checked,
since its move ends them; a quiet hour for `one`'s apps to be down. Once Leap `one` runs,
the Alpine card boots only with Leap `one` off: both claim `one`'s address and tunnel.

1. **Build `one`'s stick, on the old `one`.** `make-stick` refuses while a container uses a
   carried volume, so garmin-mcp stops first.

   ```fish
   # on the old one: stop garmin-mcp, whose token volume the stick carries, then build one's stick
   cd ~/infra/deployments/garmin-mcp; and sudo docker compose stop
   cd ~/infra; and git pull; and sudo leap/make-stick one /dev/sdX
   ```

2. **Optional, and worth it: the Alpine card on the 8 GB board.** Power the old `one` off
   (`sudo poweroff`), move its Alpine card and its Sabrent, with the SSD, to the 8 GB board,
   and power it on. If `ssh one` answers and `sudo docker ps` lists its apps, the 8 GB board
   is its own way back and slice 3 need not wait a day. Power it off again.
3. **Boot Leap.** The new card in the 8 GB board, the Sabrent with the SSD on its USB 3
   port, the stick in another port, the Ethernet in, and power on. The first boot takes
   several minutes, since it installs packages before it answers. Then, from the phone,
   `ssh one`; the host key is `one`'s own, so no warning.
4. **The named volume, then the apps.** The garmin-mcp volume restore in
   [`leap/README.md`](../leap/README.md) § After the first boot, then one deployment at a
   time, `ansible-playbook playbooks/server-deploy-compose.yml -e deployment=<name> -K`
   for `calibre-web`, `garmin-mcp`, `send2ereader` and `torrents`. garmin-mcp's play pauses
   at its Garmin login.
5. **The second way in.** `sudo tailscale up --advertise-tags=tag:fleet
   --accept-dns=false` on `one`, and open the URL it prints.
6. **Erase the stick,** once the checks below pass.

**Checks:**

- `ssh one` answers through the tunnel, and `tailscale status` on `one` lists it online.
- `systemctl --failed` is empty, or lists only `import-pubring-from-rpmdb.service`, which
  openSUSE fails on a first boot and clears at the next (`sim/microos/README.md`).
- `findmnt /var/lib/docker` names `var-lib-docker-leap`, and `sudo docker ps` lists each app.
- Each app answers at its own hostname.
- **Bench checks, sent to the infra agent for the phase table:**
  - `rpm -q kernel-firmware-brcm`, which `three`'s Wi-Fi needs;
  - `rpm -q --qf '%{VERSION} %{RSAHEADER:pgpsig}\n' tailscale`: Tailscale's own build,
    signed by key `458ca832957f5868`, at 1.104.2 or later (the TS-2026-013 fix);
  - `sudo grub2-editenv - list` and `sudo journalctl -b -u health-checker`, to see whether
    health-checker can clear its boot flag on a Pi (`microos-cutover.md` § Still open);
  - `sudo firewall-cmd --list-all` after `tailscale up`, to see Tailscale through firewalld;
  - a serial console, if a USB serial adapter is to hand.

**Way back:** power off, the Alpine card and the Sabrent back on the old board (or on the
8 GB board, if step 2 passed), power on, `ssh one`, then `sudo docker compose start` in
`~/infra/deployments/garmin-mcp`, which step 1 stopped; if its play logged in to Garmin on
Leap, log in again. The SSD's data is Alpine's, plus what Leap's apps wrote: Leap's Docker
store is a subvolume of its own, and the data mounts carry `context=` without writing
labels.

## Slice 2: `zero`'s disk swap

Not the day of slice 1. Every step, its checks and its order are in
[`three.md`](three.md) § *`zero`'s disk swap*: it borrows `one`'s Sabrent, so `one` is off
for its length, and nothing reboots between `btrfs replace` starting and `btrfs replace
status` reading finished. Before its shutdown step, `zero`'s live agent slots are checked:
the dev hub, and the infra agent with it, run on `zero`. The value it sends the infra
agent is the new member's bcache UUID, for `bcache-register`.

**Checks:** `sudo btrfs device usage /media/immich-data` shows the new device and not
`sdb`'s; `sudo bin/check-mount-guards` passes after the reboot; Immich answers.

**Way back:** before `btrfs replace` finishes, `btrfs replace cancel` leaves `sdb` where it
was. After, there is none, since the replace wipes `sdb`'s superblock: the array is whole
on the new disk and the WD Elements, and a new disk that misbehaves is replaced the same way.

## Slice 3: `three` joins

**Before:** a day after slice 1, or step 2 of it passed; the stick buildable (Before the
visit, step 4); `one`'s old board free; a card written and labelled `three`.

1. **Build `three`'s stick** on `zero` or `two`, whichever has a free port; never on the old
   `one`'s Alpine card while Leap `one` runs. `three`'s gavin password is the build host's.

   ```fish
   # on zero or two: build three's stick; it asks for three's root password and prints three's host key fingerprint, to write down
   cd ~/infra; and git pull; and sudo leap/make-stick --new three /dev/sdX
   ```

2. **Boot.** The 1 GB board into the Argon, the WD Red in a middle bay, the card, the stick,
   the Ethernet, power. From the phone on the home Wi-Fi, once the first boot has finished
   installing: `ssh gavin@192.168.86.103`, and check the fingerprint it asks about against
   step 1's.
3. **The drive.** Its serial checked with WD, and `sudo smartctl -d sat -i -A -l scterc
   /dev/sdX` read (`three.md` § The Argon EON), then the array made and unlocked, as
   [`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § The array says.
4. **The two ways in.** `sudo tailscale up --advertise-tags=tag:fleet --accept-dns=false`
   on `three`. Then, before the tunnel play, the infra agent merges the branch
   `three-joins-fleet`, which puts `three` in the inventory, reached at `three-local` until
   its tunnel answers, and gives the phone `three` and its mesh aliases. Run
   `ansible-playbook playbooks/client-home-ssh-config.yml` on the phone, then `ssh
   three-local true` once, checking the fingerprint against step 1's: Ansible refuses an
   unknown host key, and step 2's `ssh gavin@192.168.86.103` stored it under the address.
   Then the tunnel and its Access gate, as that README's § After the first boot says. Once
   `ssh three` answers through the tunnel, the infra agent drops `ansible_host` from the
   inventory.
5. **Erase the stick,** once `ssh three` answers through the tunnel.
6. **The backup.** Send the infra agent `three`'s address from `tailscale ip -4`; it fills
   it into `mirror-backup` and writes the install for `zero` of `mirror-backup` and
   `mirror-backup-age`. Then the first push, detached, so a dropped ssh session does not end
   it:

   ```fish
   # on zero: start the first push to three now rather than at 04:00, detached from this session; it seeds about 120 GB and runs for hours
   sudo sh -c 'setsid nohup /etc/periodic/hourly/mirror-backup now </dev/null >/dev/null 2>&1 &'
   ```

   If it stops before it finishes, `three`'s next snapshot run clears what it staged and
   the 04:00 run starts over.

**Checks:** `pgrep -a rsync` on `zero` lists the push, and `sudo du -sh
/media/mirror/incoming` on `three` climbs; `free -m` on `three` stays clear of its swap. The
next morning, `sudo cat /var/lib/mirror-backup/last-success` on `zero` is recent, and
`three` has a snapshot dated today.

**Way back:** none needed: nothing depends on `three`. Power it off.

## Slice 4: the backup proven

1. **A restore**, as [`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § The
   backup says, of Immich's library from today's snapshot into `/media/mirror/restore/`.
   Then compare it with zero's: `sudo find /media/mirror/restore/library -type f | wc -l` on
   `three` against `sudo find /media/immich-data/library -type f | wc -l` on `zero` (a few
   more on `zero` are uploads since the push), and `sudo stat` one file on each for its
   owner and mode. Then `sudo rm -rf /media/mirror/restore`.
2. **Syncthing on `three`,** if `free -m` showed room through the seeding:
   `ansible-playbook playbooks/server-deploy-compose.yml -e deployment=syncthing-three -K`,
   then its GUI through `three`'s tunnel, once it has a DNS record and an Access login
   application, which no play makes yet (`docs/management-plane.md`, phase 9). Watch
   `free -m` for a day.
3. **A lock and an unlock,** to see both commands work on the real drive: the lock prints
   `locked`, and the unlock asks for the passphrase again.

**Checks:** the counts match but for new uploads, the owner and mode match, and Syncthing's
GUI answers.

**Way back:** for Syncthing, `sudo docker compose down` in its deployment; nothing else
changes.

## After the visit

Over ssh: the dev hub moves to `one`, at a quiet time and not in a slice; podman later.
Before `three` ships, the tailnet's policy limits what each tagged box reaches: `zero` only
`three`'s sshd, for the backup, and `three` nothing of `zero`'s (`decisions.md`, filed in
the phase table).
`three` ships to Singapore at a date the owner picks, after
[`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § Before three ships.
