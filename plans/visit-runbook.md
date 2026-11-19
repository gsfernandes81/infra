# The November visit, slice by slice

The runbook for [`microos-cutover.md`](microos-cutover.md): what the owner does at the
cluster, one section per slice, each ending with the fleet working. Each slice has what
must be true before it, its steps, the checks that say it worked, and its way back. When
the visit is done, what stays true moves to `docs/decisions.md` and the host READMEs, and
this file is deleted.

Every block is fish, and its first line names where it runs: the phone, or a box, after
`ssh <host>` (`ssh host 'sudo …'` hangs, CLAUDE.md § Privileged commands). Plays run from
the control node, the phone, in `~/infra/ansible`, where `ansible.cfg` is read. The infra
agent is the session in the `infra` container; it commits the values the steps send it.

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

**`three` flies to Singapore on 21 November** (the owner, 2026-11-18), so the order is
set by that day. Slice 1 first, with its step 2, so slice 3 need not wait a day. Slice 3
the same day or the next, so the first push, which runs for hours, finishes in the UK.
Slice 4 once that push has finished and a snapshot exists, before the 21st. Then
[`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § Before three ships, the
last thing before its power-off. Slice 2 is not needed for `three` and never shares a day
with slice 1, so it goes on a day left over, or after the 21st.

**Every Pi joins the tailnet with `--accept-dns=false`**, and the tailnet approves each new
machine by hand: a `tailscale up` that prints a login URL also needs the machine approved
under Machines in the admin console. With `--accept-dns=false` Tailscale never takes over a
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
   and move the pin to it, in one commit, in all three places that carry the build:
   `leap/pins` (URL and SHA-256), this block, and the card-write block in *Writing a card,
   and erasing a stick*. CI fails when they disagree (`.github/workflows/leap-pins.yml`).
2. **The tailnet's settings,** in its admin console: auto-update off, and a `tagOwners`
   entry for `tag:fleet` in the policy (`decisions.md`).
3. **`zero` on the tailnet**, by `server-install-tailscale.yml`. Tailscale's repo has
   nothing for Alpine, so `zero` runs Tailscale's own static build, at the pin in
   `ansible/group_vars/fleet.yml`, with the tracked service `hosts/zero/system/tailscaled`
   ([`hosts/zero/system/README.md`](../hosts/zero/system/README.md) § Tailscale). First an
   auth key, in the admin console under Settings, Keys: tagged `tag:fleet`, not reusable,
   **pre-approved**, expiring within a day. The tailnet has device approval on, so a key
   that is not pre-approved leaves the box waiting at "To approve your machine": approve
   it under Machines and re-run, pressing Enter at the key prompt. Then, from the phone:

   ```fish
   # on the phone: read what the Tailscale play would do on zero; press Enter at the key prompt
   cd ~/infra/ansible; and ansible-playbook playbooks/server-install-tailscale.yml -e target=zero -K --check
   ```

   ```fish
   # on the phone: install Tailscale on zero, start it, and join the tailnet; paste the auth key at its prompt
   cd ~/infra/ansible; and ansible-playbook playbooks/server-install-tailscale.yml -e target=zero -K
   ```

   Each asks for your sudo password, then the key, which it does not echo. The dry run
   reports the versions it would install, the service file as a new file, and `would join`.
   The real run ends by printing `zero`'s tailnet address and name, then checks that `zero`
   is on the tailnet as `tag:fleet` with `--accept-dns=false`, that `tailscale status`
   lists it, and that `/etc/resolv.conf` reads as it did before. It refuses if Alpine's own
   `tailscale` package is installed. The play reaches `zero` through the tunnel and touches
   neither sshd nor `cloudflared`.

   **Checks:** a second `ssh zero` answers through the tunnel; `sudo docker ps` lists
   everything that ran before; Immich and the dev hub answer.

   **Way back:** `sudo tailscale down; and sudo rc-service tailscaled stop; and sudo
   rc-update del tailscaled default`, and the node removed in the admin console.

   **By hand, if the play cannot run**, after `ssh zero`, with the version and SHA-256 from
   `ansible/group_vars/fleet.yml` in place of the placeholders. Go on past the first block
   only if it prints `absent`, and open the URL the last line prints.

   ```fish
   # on zero, by hand: check Alpine's own tailscale is absent; go on only if this prints "absent"
   apk info -e tailscale; and echo 'STOP: Alpine tailscale is installed'; or echo absent
   ```

   ```fish
   # on zero, by hand: install the pinned static build and the tracked service, start it, and join keeping zero's resolver
   set v VERSION; set sum PASTE_SHA256_HERE
   cd /tmp; curl -fLO https://pkgs.tailscale.com/stable/tailscale_{$v}_arm64.tgz
   echo "$sum  tailscale_"$v"_arm64.tgz" | sha256sum -c -; and tar -xzf tailscale_{$v}_arm64.tgz; and sudo install -D -m 755 tailscale_{$v}_arm64/tailscaled /usr/local/sbin/tailscaled; and sudo install -D -m 755 tailscale_{$v}_arm64/tailscale /usr/local/bin/tailscale
   rm -rf /tmp/tailscale_{$v}_arm64 /tmp/tailscale_{$v}_arm64.tgz
   cd ~/infra; and git pull --ff-only; and sudo bin/install-system-file tailscaled --commit --allow-content-change --new
   sudo rc-update add tailscaled default; and sudo rc-service tailscaled start
   cat /etc/resolv.conf; sudo tailscale up --advertise-tags=tag:fleet --accept-dns=false; cat /etc/resolv.conf
   ```

4. **`zero`'s backup key**, by `server-create-backup-key.yml`, once step 3 has passed:

   ```fish
   # on the phone: make zero's backup key if it has none, and print the values three's key line needs
   cd ~/infra/ansible; and ansible-playbook playbooks/server-create-backup-key.yml -e target=zero -K
   ```

   It refuses until `zero` is on the tailnet, and never replaces a key that exists. It
   prints the public key, `zero`'s tailnet address and the key's fingerprint. Send the infra
   agent all three: it commits the key and the address into
   `hosts/three/leap/system/backup-authorized-keys`, and checks the key, which wraps on the
   phone's screen, against the fingerprint. Until it has, `make-stick` refuses `three`'s
   stick.
5. **`rsync` on the Alpine hosts:** `ansible-playbook playbooks/server-install-packages.yml
   --check --diff -K` to read what it would install, then without `--check`.
6. **The new `PermitOpen`** (it adds `three`'s `.103`) on `two`, then `one`, then `zero`,
   by `server-install-system-files.yml` narrowed to the one file. `one` needs it even though
   the 8 GB board replaces it, because its Alpine card is slice 1's way back. First a dry
   run on all three, which writes nothing:

   ```fish
   # on the phone: the dry run of the new sshd drop-in on two, one and zero, which shows each diff and writes nothing
   cd ~/infra/ansible; and ansible-playbook playbooks/server-install-system-files.yml -l two,one,zero -e only=sshd-infra.conf --check --diff -K
   ```

   It asks for your sudo password, for the `sshd -t` checks. Each host's diff is the
   `PermitOpen` line, a new comment above it, and two reworded comments, and it ends
   `pre-checks on the repo copy: ok` and `DRY RUN`. If it shows anything else, or a line
   saying the dry run refused a file, stop. Then, for each host in turn, the install from
   the phone, the reload on the host, and a second session:

   ```fish
   # on the phone: install the sshd drop-in on two; nothing is reloaded
   cd ~/infra/ansible; and ansible-playbook playbooks/server-install-system-files.yml -l two -e only=sshd-infra.conf -K
   ```

   ```fish
   # on two: reload sshd and print the PermitOpen now on disk
   sudo rc-service sshd reload; and sudo sshd -T | grep -i permitopen
   ```

   ```fish
   # on the phone: install the sshd drop-in on one; nothing is reloaded
   cd ~/infra/ansible; and ansible-playbook playbooks/server-install-system-files.yml -l one -e only=sshd-infra.conf -K
   ```

   ```fish
   # on one: reload sshd and print the PermitOpen now on disk
   sudo rc-service sshd reload; and sudo sshd -T | grep -i permitopen
   ```

   ```fish
   # on the phone: install the sshd drop-in on zero; nothing is reloaded
   cd ~/infra/ansible; and ansible-playbook playbooks/server-install-system-files.yml -l zero -e only=sshd-infra.conf -K
   ```

   ```fish
   # on zero: reload sshd and print the PermitOpen now on disk
   sudo rc-service sshd reload; and sudo sshd -T | grep -i permitopen
   ```

   The install ends naming `sshd-infra.conf` and saying nothing was restarted: the play
   never restarts or reloads anything, by design. The reload's last line ends
   `192.168.86.103:22`; it reads the file on disk, and the second session is what proves
   the running sshd answers. This is safe over the tunnel. `install-system-file` runs
   `sshd -t` on the file and on the whole config before it writes, runs it again after,
   and puts the old file back if that fails. A reload keeps every open session, and the
   tunnel is not touched. Before you close the session the reload ran in, open a second
   `ssh <host>` and wait for it to answer.

   **Way back:** in the session that is still open, the drop-in the install replaced, from
   its backup, which the install keeps under `/root/.infra-backups/<host>/`:

   ```fish
   # on the host whose second session failed: put back the sshd drop-in from the newest backup, and reload
   set b (sudo sh -c 'ls -d /root/.infra-backups/*/*/10-infra.conf' | tail -n 1); and echo $b; and sudo cp -a $b /etc/ssh/sshd_config.d/10-infra.conf; and sudo rc-service sshd reload
   ```
7. **The ntfy topic** for the backup's age alert, by `server-store-backup-ntfy-url.yml`:

   ```fish
   # on the phone: store the ntfy topic's URL on zero, root's alone, and send it one test message
   cd ~/infra/ansible; and ansible-playbook playbooks/server-store-backup-ntfy-url.yml -e target=zero -K
   ```

   It asks for the URL, without echoing it, then whether to send a test message: answer
   `y`. It prints that the URL was written, root 0600, and `Test message: HTTP 200`, and the
   message reaches the topic titled `zero backup`. Any other status stops the play with the
   URL stored: check the topic, then run it again with the right URL.

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

`sudo cat /var/log/card-write.log` ends with `written` when it is done. Then the card is
read back over the image's length and compared with the image, so a write that went wrong
is caught before the card reaches a Pi:

```fish
# on two: compare the card with the image over the bytes dd wrote; put the card's device in place of sdX; the two hashes must match
xzcat /home/gavin/Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.16.raw.xz | sha256sum; sudo head -c 4599054336 /dev/sdX | sha256sum
```

4,599,054,336 is build 3.16's uncompressed size, the byte count `dd` reports in the log;
`two` has no `xz` to read it from the file, only BusyBox's `xzcat`.

The only card reader to hand on 2026-11-19 was a Lexar RW047, an SDHC reader, which shows a
128 GB card as about 25 GB. That is enough for this write, which stays inside the first
4.6 GB, and the read-back proves it; on the Pi, whose slot reads SDXC, the card is its full
size again. Label the card with
the host's name: a host's name follows its card.

**The stick** is built by `leap/make-stick` ([`leap/README.md`](../leap/README.md)), which
asks for the device name before it erases anything. It holds live secrets once built, so
it is erased once its host has passed the slice's checks, on the host it booted. Many USB
sticks cannot discard, so zeros are the fallback:

```fish
# on the host the stick booted: erase the first-boot stick, only if it is the stick; zeros where it cannot discard; put its device in place of sdX
lsblk -o NAME,SIZE,MODEL,TRAN,LABEL
set d sdX; sudo blkid -p /dev/$d | grep -q 'LABEL="combustion"'; and begin; sudo blkdiscard -f /dev/$d; or sudo blkdiscard -fz /dev/$d; end; and echo erased
```

`blkid -p` reads the device itself, where plain `blkid` can answer from its cache about a
card that is no longer in the reader. `blkdiscard` refuses a device that still carries a
filesystem unless given `-f`; the label check above is what makes forcing it safe. The
Lexar reader shows a 128 GB card as about 23 GB, so only that much is erased, which covers
the stick: `make-stick` writes at its start.

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
- `lsblk -o NAME,SIZE,MOUNTPOINTS /dev/mmcblk0`: the root partition fills the card, about
  119 GB on a 128 GB card. If it is still about 4 GB, the first boot did not grow it; tell
  the infra agent, since a mounted btrfs root grows in place, without rescue mode.
- Each app answers at its own hostname.
- **Bench checks, sent to the infra agent for the phase table:**
  - `rpm -q kernel-firmware-brcm`, which `three`'s Wi-Fi needs;
  - `rpm -q --qf '%{VERSION} %{RSAHEADER:pgpsig}\n' tailscale`: Tailscale's own build,
    signed by key `458ca832957f5868`, at 1.104.2 or later (the TS-2026-013 fix);
  - `sudo grub2-editenv - list` and `sudo journalctl -b -u health-checker`, to see whether
    health-checker can clear its boot flag on a Pi (`microos-cutover.md` § Still open);
  - `sudo firewall-cmd --list-all` after `tailscale up`, to see Tailscale through firewalld;
  - a serial console, if a USB serial adapter is to hand.

**If the first boot never answers ssh** (it answers ping on its address, but port 22 is
refused): the script stopped. Read its log off the card on `two`, through the reader, by a
raw search, since the reader cannot mount a card the first boot grew:

```fish
# on two: search the card's root partition for the first boot's log lines, detached, into a file; put the card's device in place of sdX
sudo sh -c "setsid nohup sh -c 'dd if=/dev/sdX2 bs=4M count=1536 2>/dev/null | strings -n 8 | grep \"^firstboot: \" > /home/gavin/firstboot-lines.txt; echo done >> /home/gavin/firstboot-lines.txt' </dev/null >/dev/null 2>&1 &"
```

`cat ~/firstboot-lines.txt` once its last line says `done`; the `STOPPED` line says why.

**Way back:** power off, the Alpine card and the Sabrent back on the old board (or on the
8 GB board, if step 2 passed), power on, `ssh one`, then `sudo docker compose start` in
`~/infra/deployments/garmin-mcp`, which step 1 stopped; if its play logged in to Garmin on
Leap, log in again. The SSD's data is Alpine's, plus what Leap's apps wrote: Leap's Docker
store is a subvolume of its own, and the data mounts carry `context=` without writing
labels.

## Slice 2: `zero`'s disk swap

Not the day of slice 1. [`three.md`](three.md) § *`zero`'s disk swap* says why and in what
order; this section is the commands. It borrows `one`'s Sabrent, so `one` is off for its
length, and nothing reboots between `btrfs replace` starting and `btrfs replace status`
reading finished.

The new disk is the second WD Red Plus, serial `WD-WXB2D76H9RCN`, checked with WD by the
owner on 2026-11-18. **It is encrypted from the start**, the owner's decision of 2026-11-19
([`decisions.md`](../docs/decisions.md) § *`zero`'s encrypted member*): the disk, then its
bcache backing device, then LUKS2 with Adiantum as on `three`, then btrfs. A key file on
`zero`'s SD card opens it at every boot, so boots stay unattended. That is encryption with
protection off: turning it on later is a passphrase in place of the key file, with no
reformat.

The names, which the owner may change before step 6: LUKS label `data-luks-4`, mapping
`data-4`, key file `/etc/keys/data.key`. The 4 is the btrfs devid, which the new disk takes
over from `sdb`.

**Before:**

- the branch that made this section merged, and `git pull` run in `~/infra` on `zero`;
- the scrub finished, with both bcache devices on cache mode `none`, as on 2026-11-19;
- `one`'s live slots checked, since it is off for the slice;
- the owner's password manager open, for the passphrase of step 6;
- about 2 to 3 hours, most of it the copy.

**Where the agent stops.** The infra agent runs on `zero`, so it is there until step 10's
shutdown. At step 8 it commits the values the owner sends it. After the reboot it is back
through `ssh dev`.

1. **`one`'s Sabrent.** Power `one` off, take its SSD out of its Sabrent so `zero` never
   sees `one`'s filesystem, put the new disk in it, and connect it to a USB 2 port on
   `zero`.

2. **The starting state.**

   ```fish
   # step 2, on zero: the scrub, the caches, the error counters, each bcache device's backing disk and its UUID, the boot services, the kernel's dm modules
   sudo btrfs scrub status /media/immich-data
   cat /sys/block/bcache*/bcache/cache_mode
   sudo btrfs device stats /media/immich-data
   sudo btrfs device usage /media/immich-data | grep -E '^/dev'
   for s in /sys/block/bcache*/slaves/*; set n (basename $s); echo (string split / $s)[4] $n (sudo bcache-super-show /dev/$n | string match -r 'dev.uuid.*'); end
   rc-update show -v | grep -E '^ *(bcache-register|btrfs-scan|dmcrypt|localmount|modules) '
   ls /lib/modules/(uname -r)/kernel/drivers/md/ | grep -E '^dm-(crypt|mod)'
   ```

   It reads right when the scrub's status is finished with no errors; every cache mode
   reads `writethrough writeback writearound [none]`; every counter is 0; the usage lists
   `/dev/bcache0` and `/dev/bcache1`; the slaves line for `sdb` names `bcache1`, as the
   survey did; `bcache-register`, `btrfs-scan` and `localmount` are in `boot` (or
   `bcache-register` in `sysinit`); and both `dm-crypt.ko` and `dm-mod.ko` are listed.
   **Note `sdb`'s `dev.uuid`**, the value step 8 sends. Stop and tell the agent if
   `btrfs-scan` is in no runlevel, since the boot order below rests on it, or if the
   modules are missing, which means the kernel was upgraded without a reboot: `zero`
   reboots first, on its own, before anything here.

3. **The tools, the module, the new disk.**

   ```fish
   # step 3, on zero: install cryptsetup and its dmcrypt service, load dm-crypt, and find the new disk, the only sd disk over 3.5 TB, and read it
   sudo apk add cryptsetup cryptsetup-openrc
   sudo modprobe dm-crypt; and grep -c device-mapper /proc/misc
   set d (lsblk -dbno NAME,SIZE | awk '$1 ~ /^sd/ && $2 > 3500000000000 {print $1}'); echo "new disk: $d"
   sudo smartctl -d sat -i -A /dev/$d
   sudo blkid -p /dev/$d; echo "blkid exit $status"
   ```

   It reads right when `/proc/misc` counts 1; one disk name; smartctl shows serial
   `WD-WXB2D76H9RCN`, a few power-on hours, and 0 for `Reallocated_Sector_Ct`,
   `Current_Pending_Sector`, `Offline_Uncorrectable` and `UDMA_CRC_Error_Count`; and blkid
   prints nothing and exits 2, a blank disk. Send the smartctl lines to the agent; once the
   disk is in `zero`, its line belongs in `hosts/zero/system/hardware.md` through
   `bin/hw-inventory`. If blkid prints a partition table on the disk with that serial,
   `sudo apk add wipefs; and sudo wipefs -a /dev/$d` clears it; anything else, stop.

4. **The key file**, 4096 random bytes on the SD card, root's alone.

   ```fish
   # step 4, on zero: make the key file, never over an existing one, and read its mode and size, never its bytes
   sudo install -d -m 700 /etc/keys
   sudo sh -c 'test ! -e /etc/keys/data.key && umask 077 && dd if=/dev/urandom of=/etc/keys/data.key bs=512 count=8 status=none && chmod 400 /etc/keys/data.key'
   sudo stat -c '%a %U %s %n' /etc/keys /etc/keys/data.key
   ```

   It reads right as `700 root … /etc/keys` and `400 root 4096 /etc/keys/data.key`. The
   key is never printed, copied into the repo, into `~/.infra-backups` or into a handover.
   An image of `zero`'s SD card now carries it, so such an image is secret-bearing.

5. **The bcache backing device.** First the cache set's block size and UUID:

   ```fish
   # step 5, on zero: read the cache set's block size and UUID from the cache partition
   sudo bcache-super-show /dev/sda1 | grep -E '^(dev.sectors_per_block|cset.uuid)'
   ```

   The block size in bytes is `sectors_per_block` times 512: 8 is 4096, 1 is 512. Then:

   ```fish
   # step 5, on zero: make the new disk a bcache backing device at that block size, register it, attach it to the cache set, cache mode none; put the bytes in place of BLOCK and the cset.uuid in place of CSET
   set d (lsblk -dbno NAME,SIZE | awk '$1 ~ /^sd/ && $2 > 3500000000000 {print $1}'); test (count $d) -eq 1; and sudo make-bcache -B --block BLOCK /dev/$d
   test -e /sys/block/$d/bcache; or echo /dev/$d | sudo tee /sys/fs/bcache/register
   echo CSET | sudo tee /sys/block/$d/bcache/attach
   echo none | sudo tee /sys/block/$d/bcache/cache_mode
   echo "new bcache device:" (basename (readlink /sys/block/$d/bcache/dev)); cat /sys/block/$d/bcache/state /sys/block/$d/bcache/cache_mode
   sudo dmesg | grep -i bcache | tail -n 5
   sudo bcache-super-show /dev/$d | grep -E '^(dev.uuid|cset.uuid)'
   ```

   It reads right when the device is `bcache2`; its state is `clean`, not `no cache`; its
   mode reads `[none]`; dmesg says `Caching <disk> as bcache2 on set <CSET>`; and the
   superblock's `cset.uuid` is the cache set's. **Note its `dev.uuid`** for step 8. A
   `Couldn't attach` line in dmesg is a refused attach: stop there.
   **Way back:** `echo 1 | sudo tee /sys/block/$d/bcache/stop` and unplug the disk;
   nothing in the array has changed.

6. **LUKS2 on the new bcache device**, with the key file, labelled, without a prompt:

   ```fish
   # step 6, on zero: format the new bcache device as LUKS2 with Adiantum and the key file, only if it holds no signature
   set d (lsblk -dbno NAME,SIZE | awk '$1 ~ /^sd/ && $2 > 3500000000000 {print $1}'); set b (basename (readlink /sys/block/$d/bcache/dev)); echo "formatting /dev/$b"
   test (count $d) -eq 1; and test -b /dev/$b; and not sudo blkid -p /dev/$b; and sudo cryptsetup luksFormat --batch-mode --type luks2 --cipher xchacha12,aes-adiantum-plain64 --key-size 256 --pbkdf-memory 262144 --label data-luks-4 --key-file /etc/keys/data.key /dev/$b
   ```

   `/dev/$b` is read from the new disk's own bcache directory, so it cannot name
   `bcache0` or `bcache1`, and blkid refusing to find a signature on it is the second
   guard. `--pbkdf-memory 262144` keeps each keyslot's Argon2 at 256 MiB, so the disk
   still opens on a 1 GB board such as `three`'s: cryptsetup otherwise sizes it to the Pi
   5's memory, up to 1 GiB, and a smaller box then refuses with *Not enough available
   memory to open a keyslot*.

   Then the owner's passphrase as a second keyslot, the way in if the key file is lost
   with the SD card. It asks twice and shows nothing:

   ```fish
   # step 6, on zero: add the owner's passphrase as keyslot 1, authorised by the key file
   set d (lsblk -dbno NAME,SIZE | awk '$1 ~ /^sd/ && $2 > 3500000000000 {print $1}'); set b (basename (readlink /sys/block/$d/bcache/dev))
   sudo cryptsetup luksAddKey --pbkdf-memory 262144 --key-file /etc/keys/data.key /dev/$b
   ```

   The passphrase goes into the password manager now, before going on. It does not turn
   protection on: the key file's slot still opens the disk with nobody there. Protection
   comes on only when that slot is killed (`docs/management-plane.md`, the phase table).

   ```fish
   # step 6, on zero: open it as data-4 with the key file, read the header, test the passphrase, and resolve the UUID the way the boot will
   set d (lsblk -dbno NAME,SIZE | awk '$1 ~ /^sd/ && $2 > 3500000000000 {print $1}'); set b (basename (readlink /sys/block/$d/bcache/dev))
   sudo cryptsetup open --key-file /etc/keys/data.key /dev/$b data-4; and ls -l /dev/mapper/data-4
   sudo cryptsetup luksDump /dev/$b | grep -E '^(Version|Label|UUID):|^[[:space:]]+cipher:|^  [0-9]+: luks2|Memory:'
   sudo cryptsetup open --test-passphrase --key-slot 1 /dev/$b; and echo "the passphrase opens keyslot 1"
   sudo findfs UUID=(sudo cryptsetup luksUUID /dev/$b)
   grep -E '^driver.*adiantum' /proc/crypto | sort -u
   ```

   It reads right when `/dev/mapper/data-4` exists; the dump shows `Version: 2`,
   `Label: data-luks-4`, `cipher: xchacha12,aes-adiantum-plain64`, keyslots `0: luks2`
   and `1: luks2`, and `Memory: 262144` twice; the passphrase prompt ends with *the
   passphrase opens keyslot 1*; findfs prints `/dev/bcache2`, the lookup the boot makes;
   and `/proc/crypto` lists an Adiantum driver. **Note the `UUID:`** for step 8.
   **Way back:** `sudo cryptsetup close data-4`, then step 5's.

   **A header backup is optional here.** `cryptsetup luksHeaderBackup /dev/$b
   --header-backup-file <file>` saves the 16 MiB in front of the data, which holds the
   keyslots. The array's other copy already covers this member, so a damaged header costs a
   second replace, not data. If one is taken, CLAUDE.md § *Backups of secret-bearing files*
   governs it: the header with the key file opens the disk, so it never lives on `zero`
   beside `/etc/keys`, never in the repo, `~/.infra-backups` or the backup to `three`, and
   is kept at mode 600 off the box, with the passphrase. A header saved while the key
   file's slot exists keeps that slot alive in the copy, so once protection is on, any
   earlier copy is destroyed and a new one taken.

7. **The copy.** `-r` reads from the other mirror, the WD Elements disk, wherever it can,
   and from `sdb` only for a block whose other copy is bad, so the failing disk is read as
   little as possible. Writes during the copy still go to `sdb` as well, so it stays a
   whole copy until the replace finishes. Immich keeps running. About an hour over USB 2.

   ```fish
   # step 7, on zero: replace devid 4, sdb's bcache device, with the encrypted member, reading from the other mirror wherever it can
   sudo btrfs replace start -r 4 /dev/mapper/data-4 /media/immich-data
   sudo btrfs replace status -1 /media/immich-data
   ```

   Run the status line again now and then. **Nothing reboots or shuts down until it reads
   finished**: an interrupted replace leaves one full copy, on the worn WD Elements disk,
   and one partial. Then:

   ```fish
   # step 7, on zero: once the status reads finished: devid 4 is the mapping, sdb's device is gone, and the counters
   sudo btrfs replace status -1 /media/immich-data
   sudo btrfs filesystem show /media/immich-data
   sudo btrfs device stats /media/immich-data
   ```

   It reads right when the status is finished with `0 write errs, 0 uncorr. read errs`;
   the filesystem lists two devices, devid 3 on a `/dev/bcache` path and devid 4 on
   `/dev/mapper/data-4`, and no `bcache1`; and every counter is 0.
   **Way back, until it finishes:** `sudo btrfs replace cancel /media/immich-data` leaves
   `sdb` as devid 4. A new disk that drops off the USB 2 port mid-copy ends the replace
   the same way. After it finishes there is none, since the replace wipes `sdb`'s btrfs
   superblock: the array is whole on the new disk and the WD Elements disk.

8. **The agent commits; the owner installs.** Send the infra agent three values, none of
   them secret: `sdb`'s `dev.uuid` (step 2), the new disk's `dev.uuid` (step 5) and the
   LUKS `UUID` (step 6). It commits `bcache-register` with the new disk's UUID in place of
   `sdb`'s, not beside it, and `dmcrypt` with the LUKS UUID in place of
   `FILL-FROM-LUKS-UUID`, both to `main`. Then:

   ```fish
   # step 8, on zero: pull the agent's commit and dry-run the three files: bcache-register's diff, dmcrypt's check opening the member with the key file, dm-crypt.conf new
   cd ~/infra; and git pull --ff-only
   bin/install-system-file bcache-register --allow-content-change
   bin/install-system-file dmcrypt --allow-content-change
   bin/install-system-file dm-crypt.conf --new
   ```

   It reads right when `bcache-register`'s diff is `sdb`'s UUID out, the new one in and the
   `before dmcrypt btrfs-scan` order, and each ends `pre-checks on the repo copy: ok` and
   `DRY RUN`. `dmcrypt`'s check is the boot's unlock short of the boot: findfs resolves its
   `source=` and `cryptsetup open --test-passphrase` opens it with the key file. If it
   refuses although step 6's open worked, the check is wrong, not the member: stop and tell
   the agent.

   ```fish
   # step 8, on zero: install the three files, add dmcrypt to the boot runlevel, and read the order OpenRC recorded for it
   sudo true; and bin/install-system-file bcache-register --commit --allow-content-change; and bin/install-system-file dmcrypt --commit --allow-content-change; and bin/install-system-file dm-crypt.conf --new --commit
   sudo rc-update add dmcrypt boot
   sudo rc-update -u; and grep "^depinfo_"(grep "_service='dmcrypt'" /run/openrc/deptree | cut -d_ -f2)"_i" /run/openrc/deptree
   ```

   It reads right when each install ends `post-install checks: ok`, and dmcrypt's lines
   include an `iafter` of `bcache-register` and of `modules`, and an `ibefore` of
   `btrfs-scan` and of `localmount`. Nothing has restarted.

9. **`sdb` out of the cache set.** Put `sdb`'s backing name from step 2 (`sdb`, or its
   partition) in place of `SDB`:

   ```fish
   # step 9, on zero: detach sdb's bcache device from the cache set and stop it, only if the array no longer names it
   set s SDB; set o (basename (readlink /sys/class/block/$s/bcache/dev)); echo "sdb's bcache device: $o"
   sudo btrfs filesystem show /media/immich-data | grep -q "/dev/$o\$"; and echo "STOP: $o is still in the array"; or begin; echo 1 | sudo tee /sys/class/block/$s/bcache/detach; sleep 2; echo 1 | sudo tee /sys/class/block/$s/bcache/stop; end
   sleep 2; ls /sys/block | grep bcache
   ```

   It reads right when the device is `bcache1`, no `STOP` line prints, and two bcache
   devices are left. Its data is already gone from the array, so there is nothing to undo.

10. **The shutdown, the move, and the reboot test.** One shutdown does both: the new disk
    goes into `sdb`'s bay, so the boot after it is the configuration `zero` keeps, and it
    proves the unattended unlock, the boot order and the UUIDs at once. Everything is named
    by UUID, so the move changes no file. Check `zero`'s live agent slots first: the dev
    hub and the infra agent's session end here.

    ```fish
    # step 10, on zero: power off
    sudo poweroff
    ```

    Once the Pi's light stops, switch `zero`'s Sabrent off, take `sdb` out of its bay, put
    the new disk in it, unplug the borrowed Sabrent from `zero`, switch `zero`'s Sabrent
    on, and power `zero` on. After a few minutes, `ssh zero`:

    ```fish
    # step 10, on zero: after the boot: dmcrypt opened the member with nobody there, the array mounted with both devices, the guards hold, Immich answers
    rc-service dmcrypt status; ls -l /dev/mapper/data-4
    sudo btrfs filesystem show /media/immich-data
    findmnt -t btrfs -o TARGET,SOURCE
    sudo btrfs device stats /media/immich-data
    cd ~/infra; and sudo bin/check-mount-guards
    curl -fsS http://127.0.0.1:2283/api/server/ping
    ```

    It reads right when dmcrypt is started and the mapping exists; the filesystem lists
    two devices, one of them `/dev/mapper/data-4`; findmnt lists the three `/media` mounts
    and `/var/lib/docker`; every counter is 0; check-mount-guards passes; and Immich
    answers `{"res":"pong"}`. Then `ssh dev` brings the agent back, to be told how it read.

    **If the array is not mounted.** The box boots and ssh answers either way: nothing on
    the boot path needs the array, the `/media` entries carry `nofail`, and the bare
    mountpoints are immutable, so nothing writes into them. If ssh does not answer, the
    same blocks run at `zero`'s own console, a keyboard and the micro-HDMI port.
    [`hosts/zero/system/README.md`](../hosts/zero/system/README.md) § *The encrypted
    member* has the blocks: read what is there, register a missing bcache device, open
    `data-4` with the key file or else the passphrase, then scan, mount and cycle Immich
    and Syncthing. A boot that needed them is a fault in the order or the files, and the
    agent fixes it before step 11.

    **`mount -o degraded` is the last resort**, only when `data-4` cannot be opened by
    either key and Immich must serve before a fix. The array would then run on the worn
    WD Elements disk alone, with no second copy; what it writes while degraded lands in
    unmirrored chunks that need a balance and a scrub once a second device is back; and a
    mounted degraded array hides the fault it is working around. `-o degraded,ro` is
    enough to copy something off.

11. **The end of the slice.**

    ```fish
    # step 11, on zero: both bcache devices back to writethrough
    for m in /sys/block/bcache*/bcache/cache_mode; echo writethrough | sudo tee $m; end; cat /sys/block/bcache*/bcache/cache_mode
    ```

    Each reads `[writethrough]`. Then `one`'s SSD back into its Sabrent, the Sabrent back
    on `one`, and `one` powered on, so the slice ends with every box serving.
    `sudo btrfs filesystem resize 4:max /media/immich-data` is optional: a RAID1 array of
    a 4 TB and a 1 TB disk holds 1 TB either way, until the WD Elements disk is replaced as
    well. `sdb` is wiped on another machine, never `zero`, where its old bcache superblock
    could be registered again; it holds Immich's photos, unencrypted.

**Checks:** dmcrypt opened `data-4` at boot with nobody there; `sudo btrfs filesystem show
/media/immich-data` lists `/dev/mapper/data-4` and not `sdb`'s device; `sudo
bin/check-mount-guards` passes after the reboot; Immich answers; both caches read
`writethrough`.

**Way back:** step by step above. Until step 7's replace finishes, every step is undone by
closing the mapping, stopping the new bcache device and unplugging the disk. After it, the
array is the new disk and the WD Elements disk, and a new disk that misbehaves is replaced
the same way.

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
   `mirror-backup-age-check`. Then the first push, detached, so a dropped ssh session does not end
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
   `ansible-playbook playbooks/server-deploy-compose.yml -e deployment=syncthing-three -K`.
   Then its GUI, behind an Access login, with one play from the phone:

   ```fish
   # on the phone, in ~/infra/ansible: put three's Syncthing GUI behind the Access login, then give it its DNS record
   ansible-playbook playbooks/server-create-browser-login.yml -e host=three -e subdomain=syncthing-three
   ```

   It asks nothing. It reads who may log in from `~/.config/cloudflare/access-emails` on the
   phone, the same file `calibre-web`'s login uses, and when the file is missing it prints how
   to make one and stops with nothing made. It prints how many addresses it admits, never
   the addresses; that a login looks like a redirect to the team's `cloudflareaccess.com`
   page, read off `torrents`; then that `syncthing-three.gsrpi.uk` redirects to the login;
   and last the GUI's address and the undo. If it says the name does not answer from here
   yet, re-run it in a few minutes. Then open `https://syncthing-three.gsrpi.uk/` on the
   phone and log in with one of those addresses. A "Host check error" page means the tunnel config lacks the
   `httpHostHeader` that `hosts/three/leap/README.md` § After the first boot, step 3, gives
   it. Watch `free -m` for a day.
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
