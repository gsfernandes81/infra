# The November visit: what is left

The runbook for [`microos-cutover.md`](microos-cutover.md). The visit ended on 2026-11-21,
and its finished slices are deleted; what each did, and where its record now lives, is the
first section. What stays is still open: slice 4, the clean-up it unlocks and the items
for after the visit. The Pi image and card steps stay too, since the next Leap host's card
reuses them. Once
slice 4 and the clean-up are done, those steps need another home, with the workflow
following them, before this file is deleted.

Every block is fish, and its first line names where it runs: the phone, or a box, after
`ssh <host>` (`ssh host 'sudo …'` hangs, CLAUDE.md § Privileged commands). Plays run from
the control node, the phone, in `~/infra/ansible`, where `ansible.cfg` is read. The infra
agent is the session in the `infra` container; it commits the values the steps send it.

## What the visit did

The procedures as run are in the history: `git show 774eb42:plans/visit-runbook.md`.

| Slice | Done | The record now |
|---|---|---|
| Before the visit: the Pi image, `zero` on the tailnet, `zero`'s restore key, the new `PermitOpen` on every host | 2026-11-13 to 20 | [`hosts/zero/system/README.md`](../hosts/zero/system/README.md) § Tailscale; `decisions.md` § *The setup plays* |
| 1. `one` moves to the 8 GB board, on Leap | 2026-11-18 | `hosts/one/leap/MOVED`; its bench checks in the phase table of `docs/management-plane.md` |
| 2. `zero`'s disk swap: the new WD Red Plus, encrypted as `data-luks-4` | 2026-11-19 to 20 | `decisions.md` § *`zero`'s encrypted member*; `hosts/zero/system/README.md` § The encrypted member |
| 3. `three` joins: first boot, array, tunnel, tailnet; the array renamed to "backup"; the pull set up and the first pull run | 2026-11-18 to 20 | [`hosts/three/leap/README.md`](../hosts/three/leap/README.md); `decisions.md` § *The backup's names and layout on `three`* |
| The move on `zero`: Immich into one subvolume, `immich` (281), at `/media/immich` | 2026-11-20 | `hosts/zero/system/fstab`; `hosts/zero/system/README.md` § The backup; `decisions.md` § *`zero`'s backup is pulled by rsync from snapshots* |
| 4. The backup proven | open | below |

## The Pi image

**The Pi image, downloaded and checked on `two`,** and kept there. There is no pin of
ours: the card is written from the newest build openSUSE lists on the day, checked against
openSUSE's own `.sha256`. The directory holds only the newest build and builds have turned
over within days, so the file on `two` is the one every card is written from. The bench
boot and the day use the same file; do not replace it in between, since the bench is what
proves it.

Each block below is fish, run on `two` after `ssh two`. Set the image name once, in the
shell that runs the blocks, to the newest build
[the directory](https://download.opensuse.org/distribution/leap/16.1/appliances/) lists
(`Leap-16.1-Immutable.aarch64-RaspberryPi-Build*.raw.xz`):

```fish
# on two: name the image, the newest build the directory lists; change the number to match
set img Leap-16.1-Immutable.aarch64-RaspberryPi-Build3.23.raw.xz
set dir https://download.opensuse.org/distribution/leap/16.1/appliances
```

```fish
# on two: download the image and openSUSE's .sha256 file, and check the image against that file
df -h ~
cd ~; curl -fLO $dir/$img.sha256; and curl -fLO $dir/$img
sha256sum -c $img.sha256
```

It needs about 1.3 GB free, and `sha256sum` must print `OK`. If a `curl` answers 404,
openSUSE has replaced the build: read the directory again, set `img` to the newest and
repeat. Keep the file and its `.sha256` in `~` on `two`. Every card-write block below uses
`$img`, so set it again in a new shell.

## Writing a card, and erasing a stick

**The card is written on `two`, never on `zero`:** zero's USB disks are Immich's array, and
`dd` writes to whatever device it is given. `two` is a Pi 1, so the write runs detached and
takes a while; the image is there from § The Pi image.

```fish
# on two: read which device the card reader is
lsblk -o NAME,SIZE,MODEL,TRAN
```

```fish
# on two: write the image to the card, detached from this session, only if the device is a USB disk nothing has mounted; put the card's device in place of sdX
set d sdX; readlink -f /sys/block/$d | grep -q usb; and not grep -q "^/dev/$d" /proc/mounts; and sudo sh -c "setsid nohup sh -c 'xzcat /home/gavin/$img | dd of=/dev/$d bs=4M conv=fsync && sync && echo written' </dev/null >/var/log/card-write.log 2>&1 &"
```

`sudo cat /var/log/card-write.log` ends with `written` when it is done. Then the card is
read back over the image's length and compared with the image, so a write that went wrong
is caught before the card reaches a Pi:

```fish
# on two: get the image's uncompressed size from its own stream; slow on a Pi 1, wait for it
set n (xzcat ~/$img | wc -c); echo $n
```

```fish
# on two: compare the card with the image over those bytes; put the card's device in place of sdX; the two hashes must match
xzcat ~/$img | sha256sum; sudo head -c $n /dev/sdX | sha256sum
```

`$n` is the byte count `dd` reports in the log. `two` has no `xz` to read it from the
file, only BusyBox's `xzcat`, so the first block counts the decompressed stream, which
takes a while on a Pi 1.

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

## Slice 4: the backup proven

Once, after the first pull, and again only after a change to the backup path, such as `zero`
moving to Leap.

1. **The whole tree.** On `zero`, through the restore module: a dry run with checksums
   that compares `three`'s snapshot of the pull with the `zero` snapshot it pulled, every
   file's contents, owner, mode, time and symlink. `sudo snapper --no-dbus -c
   received-immich list` on `three` gives `three`'s newest number, and its description,
   `pulled <M>`, the `zero` snapshot:

   ```fish
   # on zero: compare three's snapshot N with zero's snapshot M through the restore module; it prints nothing when they match; put the numbers in place of N and M
   sudo rsync -naHAXc --numeric-ids -i --delete --exclude=/.snapshots --exclude=/data/thumbs --exclude=/data/encoded-video -e 'ssh -i /root/.ssh/restore' restore@100.101.45.78::immich/current/.snapshots/N/snapshot/ /media/immich/.snapshots/M/snapshot/
   ```

   It reads every file on both boxes, so it takes a while, and prints nothing. The first
   connection asks to accept `three`'s host key: check its fingerprint against the one
   `make-stick` printed. The two placeholders are left out because btrfs makes up their
   times.
2. **The database.** On `three`, a reflink copy of the snapshot's `db`, which costs no space,
   then a throwaway container of the Postgres image in `deployments/immich/compose.yaml`
   (its digest too), with no network, on that directory. Its entrypoint gives the files to
   its own user before it starts:

   ```fish
   # on three: copy the db of snapshot N by reflink, and start Immich's Postgres image on it with no network; put the image and digest from deployments/immich/compose.yaml in place of IMAGE
   sudo cp -a --reflink=always /media/backup/immich/current/.snapshots/N/snapshot/db /media/backup/restore-db; and sudo docker run -d --name restore-check --network none -v /media/backup/restore-db:/var/lib/postgresql/data IMAGE
   sudo docker logs -f restore-check
   ```

   The log reads an automatic recovery, then "ready to accept connections". Then a count
   of Immich's assets, `sudo docker exec restore-check psql -U postgres -d immich -tAc
   'select count(*) from asset'` (`assets` before Immich 1.137), matches the web UI's but for
   uploads since the snapshot.
   Then `sudo docker rm -f restore-check; and sudo rm -rf /media/backup/restore-db`.
3. **Syncthing on `three`,** if `free -m` showed room through the pull:
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
4. **A lock and an unlock,** to see both commands work on the real drive: the lock prints
   `locked`, and the unlock asks for the passphrase again and starts the pull's timer.
5. **A restore of Immich itself**, if one is ever run from this: `thumbs` and
   `encoded-video` come back empty, and Immich checks each of its folders for an empty
   `.immich` file before its first start, so one is put in each.

**Checks:** step 1 prints nothing, step 2's count matches but for new uploads, and
Syncthing's GUI answers.

**Way back:** for Syncthing, `sudo docker compose down` in its deployment; nothing else
changes.

## Later: the old Immich subvolumes

After slice 4 has passed. The move on `zero` copied `media-immich-data` and
`media-immich-db` into `immich` by reflink and left them untouched, as the way back. Being
reflinked, they free only what has changed since. On `zero`, measure first with `sudo
btrfs filesystem du -s`, then `sudo btrfs subvolume delete` `media-immich-data` and
`media-immich-db`, and `chattr -i` and `rmdir` the two old bare mountpoints,
`/media/immich-data` and `/media/immich-db`. The array's top level mounts at `/mnt/ext`
(`sudo mount /mnt/ext`, then `sudo umount /mnt/ext` after).

## After the visit

Over ssh: the dev hub moves to `one`, at a quiet time and not in a slice; podman later.
The tailnet stays allow-all among the boxes (`decisions.md` § *The tailnet stays open
between the boxes*). `three` ships to Singapore at a date the owner picks, after
[`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § Before three ships.
