# three on Leap

`three` is the off-site backup in the Argon EON ([`plans/three.md`](../../../plans/three.md)).
It is a new host: the 1 GB Pi 4 that runs `one` today, on a new SD card. This directory is
its first boot, in `one`'s shape ([`leap/README.md`](../../../leap/README.md)), plus what only
`three` has: the backup array behind a passphrase.

| Path | What it is |
|---|---|
| `combustion/script` | The first-boot script. |
| `system/` | Every file the first boot installs, each at the path its `infra-` header names. |
| `fstab.append` | The array's entry, `noauto`. |
| `make-mirror` | Formats the backup drive, once, at the visit. |

## Before the stick

Two files carry zero's values as placeholders, and `make-stick` refuses a stick while they
are there: `system/restore-authorized-keys`, zero's restore key, and `system/zero-known-hosts`,
zero's ssh host key, which the pull pins. Both are printed by one play, once zero is on the
tailnet (`server-install-tailscale.yml`). From the phone:

```fish
# on the phone: make zero's restore key if it has none, and print it, zero's address and zero's host key for three's files
cd ~/infra/ansible; and ansible-playbook playbooks/server-create-restore-key.yml -e target=zero -K
```

It makes `/root/.ssh/restore` only if no key is there. The infra agent commits the key and
zero's host key in place of the placeholders, checking each against the fingerprint the play
prints, and the stick can be built. Zero's tailnet address is already in both files. A
rebuilt three also makes a new pull key (§ The backup), so zero's mirror line changes after
its first boot.

## The stick

`three` has no old system to carry anything from, so its stick is built with `--new` on
`zero` or `two`. Never on the old `one`'s Alpine card while Leap `one` runs: both would
claim `one`'s address and tunnel.

```fish
# on zero or two: build three's first-boot stick; put the stick's device in place of /dev/sdX
cd ~/infra; and git pull
sudo leap/make-stick --new three /dev/sdX
```

It makes `three`'s ssh host key on the stick and prints its fingerprint: check it at the
first `ssh three`. It asks for `three`'s root password, which the console needs. It takes
gavin's password hash and keys from the box it runs on, so `three`'s sudo password is that
box's. It carries no tunnel credentials, `.env` or
volume, because `three` has none yet.

## After the first boot: the tunnel

The first boot leaves `cloudflared` installed and enabled, and skipped until its config
exists. On the LAN, from the phone:

1. The infra agent adds `three` to `ansible/inventory`'s `[fleet]` and `[containerized]`
   groups, which it joins only once it answers, since every fleet-wide play would
   otherwise stop on it.
2. `server-create-host-tunnel.yml -e target=three -K` writes `/etc/cloudflared/three.json`
   and prints the tunnel id.
3. The infra agent commits `system/cloudflared-config.yml` with that id, in the shape of
   every host's: `ssh-three` to port 22, and `syncthing-three` to `http://127.0.0.1:8384`,
   Syncthing's GUI, which nothing else reaches (sshd's `PermitOpen` allows port 22 only).
   The `syncthing-three` rule carries `originRequest: {httpHostHeader: localhost}`: a
   Syncthing GUI bound to `127.0.0.1` refuses a request whose `Host` is not a local name,
   with "Host check error", and through the tunnel the `Host` is `syncthing-three`'s. `zero`'s
   and `torrents`' GUIs listen on every address, where Syncthing makes no such check.
4. On `three`, in `~/infra`: `git pull`, then
   `sudo bin/install-system-file cloudflared-config.yml --commit --allow-content-change --new`,
   then `sudo systemctl start cloudflared`. The tools read `leap/system/` because
   `leap/MOVED` says `three` runs Leap. From the phone,
   `server-install-system-files.yml -l three -e only=cloudflared-config.yml -K` does the
   same install.
5. `server-create-fleet-ssh-access.yml -e host=three` gates `ssh-three` behind Access,
   admitting each client's fleet token, as it does every box's ssh hostname. It reads the
   routing from `leap/system/`, by the same `leap/MOVED`, and refuses unless this client's
   ssh config already sends `three` through `~/.config/fleet/access-ssh`, which the fleet
   ssh block does once the infra agent has added `three` to it.
6. Once Syncthing is deployed (`plans/visit-runbook.md`, slice 4), from the phone:
   `server-create-browser-login.yml -e host=three -e subdomain=syncthing-three` puts the
   GUI behind an Access login and then gives it its DNS record. The fleet ssh play leaves
   `syncthing-three` alone, since a browser needs a login, not a service token, and the
   tunnel play makes `ssh-three`'s record only.

   It makes an Access application, `syncthing-three`, admitting the addresses in
   `~/.config/cloudflare/access-emails` on the phone by the account's login methods, as
   `calibre-web`'s login does; only once it has read that back does it write the CNAME to
   `three`'s tunnel, so the GUI is never open. It refuses a hostname that is not an http
   rule in the tracked config above, and a `tunnel:` that `ssh-three`'s record does not
   point at. It then proves from the phone that the hostname redirects an unauthenticated
   request to the Access login, and deletes the record again if the hostname answers
   anything else. It needs no `-K`, since it touches only Cloudflare. Until it has run,
   the GUI cannot be reached from outside; after, it is `https://syncthing-three.gsrpi.uk/`.
   A "Host check error" after the login means step 3's `httpHostHeader` is missing.

## The array

The first drive is a WD Red Plus that reports itself as `WDC WD40EFZZ-68CPAN0` (sold as the
WD49EFZZ), serial `WD-WXB2D76N8PYJ`. The owner checked the serial with WD, and smartctl read
it on 2026-11-18 at 0 power-on hours, with no reallocated or pending sectors and error
recovery at 7 seconds.

The drive is formatted once, after the first boot, with the drive in the Argon's middle bay
and nothing on it. After `ssh three`:

```fish
# find the new drive: the WD Red, about 3.6T, with no partitions
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN
# format it; it asks for the device name, then the passphrase twice, and leaves it locked
sudo ~/infra/hosts/three/leap/make-mirror /dev/sdX
```

`make-mirror` refuses a drive with partitions or any signature on it, so it never formats a
drive in use. It writes LUKS2 with Adiantum, labelled `mirror-luks`, which
`/etc/crypttab` names. Inside is a btrfs holding `syncthing` and `received-backups`:

| On the array | What | Whose |
|---|---|---|
| `received-backups/`, `received-backups/immich/` | directories | root's, 755 |
| `received-backups/immich/current/` | subvolume: the copy of zero's newest snapshot that `mirror-pull` keeps up to date | the backup user's, 700 |
| `received-backups/immich/current/.snapshots/<N>/snapshot` | snapper's read-only snapshots of `current/`, one per good pull | root's, 750 |
| `received-backups/immich/state/` | `pulled`: what the last good pull copied | the backup user's, 700 |
| `received-backups/immich/last-pulled` | what the last snapshot holds | root's |
| `syncthing/` | subvolume: Syncthing's data and identity | gavin's |

The array made on 2026-11-18 holds the layout before the pull: `incoming` and `snapshots`.
Its change is § The backup, below, step 2.

### Unlocking, after every boot

Every boot leaves the array locked, and nothing waits for it. From the phone:

```fish
# unlock three's array; sudo asks for gavin's password, then systemd for the passphrase
ssh -t three 'sudo systemctl start systemd-cryptsetup@mirror.service; and sudo systemctl start media-mirror.mount'
```

Two starts, so the mount's 5-minute wait for the device begins only once the passphrase is
in, however long finding it takes. The mount starts Docker, which brings Syncthing up
under its restart policy, and the pull and scrub timers. Until then, Docker is skipped
by its condition, and `docker` answers that it cannot connect. A hand `mount /media/mirror`
starts none of them: only `systemctl start` does. For a few seconds while Docker first
starts, a new ssh connection can be refused; the simulation saw one attempt fail between
two that answered. Try again. The cause is not yet known (`docs/management-plane.md`,
phase 9). A pull against a locked `three` is skipped by
its condition, and the timer, `Persistent=`, pulls once the array is unlocked.

To lock it again without a reboot (Docker, a running pull and a running scrub stop with
the mount). The passphrase is not cached, so the next unlock asks for it again:

```fish
# lock three's array: Docker first, then the mount, then the LUKS volume; it prints
# "locked" only once the volume is really closed
ssh -t three 'sudo systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service; and test ! -e /dev/mapper/mirror; and echo locked'
```

### Snapshots, scrubs

Snapshots are the backup's, below. The scrub runs monthly; a month missed while the box was
off or locked scrubs once the array is unlocked. `btrfs scrub status /media/mirror` shows
the last result.

## The backup

`three` pulls `zero`'s backup ([`plans/three-backup-pull.md`](../../../plans/three-backup-pull.md)).
`zero` takes an hourly read-only snapper snapshot of its Immich, the library and Postgres in
one subvolume. Daily at 01:00 UTC, `mirror-pull.timer` starts `mirror-pull.service`, which
runs `/usr/local/bin/mirror-pull` as the backup user: it lists `zero`'s snapshots, picks the
newest finished one, and, if it is not the one pulled last, copies it with rsync into
`received-backups/immich/current`, at 32 Mbit/s. Only a success starts
`mirror-snapshot.service`, which takes a read-only snapper snapshot of `current/`, prunes to
14 daily, 8 weekly and 12 monthly, and writes `last-pulled`. A pull cut off, or one of a
snapshot `zero` deleted mid-way (rsync's exit 24), takes no snapshot; the next day's pull
finishes the copy.

The backup user owns `current/` and nothing else, never logs in, and runs the pull in a
sandbox that can write only `current/` and `state/`. It reaches `zero` with its own key,
`/home/backup/.ssh/zero-pull`, through `system/backup-ssh-config`, which names zero's tailnet
address and accepts only the host key in `system/zero-known-hosts`; both are root's. On
`zero` that key runs nothing but a read-only rsync daemon. zero's owners and modes are kept
in an xattr (`--fake-super`), and every symlink is stored with a `/rsyncd-munged/` prefix, so
none leads anywhere on `three`.

The timezone is UTC: 01:00 in a UK winter, 02:00 in a UK summer, 09:00 in Singapore.

### The pull's setup, owner-run, on the array made on 2026-11-18

Once, in this order, after `ssh three`. The first boot of a rebuilt `three` does steps 3, 4
and 5 itself, and `make-mirror` makes step 2's layout on a new drive.

1. **Unlock**, as § Unlocking says, and pull the checkout: `cd ~/infra; and git pull --ff-only`.
2. **The layout.** The old `incoming` and `snapshots` must be empty, since no push ever ran;
   the first command prints nothing if so, and the rest runs only then:

   ```fish
   # on three: check the old push's places are empty, then remove them and make received-backups
   sudo find /media/mirror/incoming /media/mirror/snapshots -mindepth 1 | head
   test -z (sudo find /media/mirror/incoming /media/mirror/snapshots -mindepth 1 | head -n 1); and sudo btrfs subvolume delete /media/mirror/incoming; and sudo rmdir /media/mirror/snapshots; and sudo install -d -m 755 /media/mirror/received-backups /media/mirror/received-backups/immich; and sudo btrfs subvolume create /media/mirror/received-backups/immich/current; and sudo chown backup:backup /media/mirror/received-backups/immich/current; and sudo chmod 700 /media/mirror/received-backups/immich/current; and sudo btrfs subvolume create /media/mirror/received-backups/immich/current/.snapshots; and sudo chmod 750 /media/mirror/received-backups/immich/current/.snapshots; and sudo install -d -o backup -g backup -m 700 /media/mirror/received-backups/immich/state; and sudo ls -la /media/mirror /media/mirror/received-backups/immich
   ```

3. **What the push left, gone; the restore user made; the array's mount hardened.** The
   timer first, so nothing starts the old script:

   ```fish
   # on three: stop and remove the old snapshot timer and script, the push's daemon config and key line; give backup no shell; make the restore user
   sudo systemctl disable --now mirror-snapshot.timer; sudo rm -f /etc/systemd/system/mirror-snapshot.timer /usr/local/sbin/mirror-snapshot /etc/rsync-backup.conf /home/backup/.ssh/authorized_keys
   sudo usermod -s /usr/sbin/nologin backup; and sudo useradd --system --user-group --no-create-home --home-dir /home/restore --shell /bin/bash --comment "zero's read-only restores" restore; and sudo install -d -m 755 /home/restore /home/restore/.ssh
   sudo sed -i '/[[:space:]]\/media\/mirror[[:space:]]/s/,noatime /,noatime,nosuid,nodev /' /etc/fstab; and grep /media/mirror /etc/fstab
   ```

   The fstab line ends `noatime,nosuid,nodev 0 0`; it takes effect at the next unlock.
4. **The pull key**, made here and never carried:

   ```fish
   # on three: make the backup user's key to zero, then print its public half and fingerprint for zero's mirror line
   sudo ssh-keygen -t ed25519 -N '' -C 'three mirror-pull' -f /home/backup/.ssh/zero-pull; and sudo chown backup:backup /home/backup/.ssh/zero-pull /home/backup/.ssh/zero-pull.pub
   cat /home/backup/.ssh/zero-pull.pub; ssh-keygen -lf /home/backup/.ssh/zero-pull.pub
   ```

   Send the infra agent the public key and its fingerprint: it commits the key into
   `hosts/zero/system/mirror-authorized-keys`, which `zero` then installs
   (`hosts/zero/system/README.md` § The backup).
5. **The files**, each with a dry run first, once the infra agent has committed zero's two
   values (§ Before the stick):

   ```fish
   # on three: install the pull, its units, snapper's config, the restore module and both users' ssh files; then label them and reload systemd
   cd ~/infra; and git pull --ff-only
   for f in mirror-pull mirror-pull.service mirror-pull.timer mirror-snapshot.service mirror-mount.conf snapper-config-received-immich backup-ssh-config zero-known-hosts sudoers-restore rsyncd-restore.conf restore-authorized-keys
       bin/install-system-file $f --new; and sudo bin/install-system-file $f --new --commit --allow-content-change; or break
   end
   sudo restorecon -Rv /home/backup /home/restore /usr/local/bin/mirror-pull; and sudo systemctl daemon-reload; and sudo systemctl start mirror-pull.timer
   ```

   `mirror-snapshot.service` and `mirror-mount.conf` exist already, so their dry runs show a
   content change; the rest are new. From the phone,
   `server-install-system-files.yml -l three -K` does the same installs.
6. **The first pull**, once `zero` has its first snapshot (`hosts/zero/system/README.md`
   § The backup). In the UK, over the LAN, with no rate limit, by a runtime drop-in that
   the next boot forgets:

   ```fish
   # on three: lift the rate limit until the next boot, and start the first pull without waiting for it
   sudo mkdir -p /run/systemd/system/mirror-pull.service.d; and printf '[Service]\nEnvironment=MIRROR_PULL_BWLIMIT=0\n' | sudo tee /run/systemd/system/mirror-pull.service.d/lan.conf; and sudo systemctl daemon-reload; and sudo systemctl start --no-block mirror-pull.service
   ```

   ```fish
   # on three: follow the pull and its snapshot, then list three's snapshots
   journalctl -fu mirror-pull -u mirror-snapshot
   sudo snapper --no-dbus -c received-immich list
   ```

   The journal ends `pulled snapshot <N> of <time>`, rsync's statistics, and
   `snapshot taken of the pull of zero snapshot <N>`; the list shows one snapshot,
   `pulled <N>`. About 93 GB on 2026-11-02, so hours. If the session drops, the pull goes on.
   Before the box ships, remove the drop-in:
   `sudo rm /run/systemd/system/mirror-pull.service.d/lan.conf; and sudo systemctl daemon-reload`.

**Checks:** each morning `journalctl -u mirror-pull -u mirror-snapshot --since yesterday`
reads a pull and a snapshot, or `nothing new`; `systemctl list-timers mirror-pull.timer`
names the next 01:00 UTC. Nothing alerts when pulls stop; that waits on a fleet-wide dead
man's switch (`docs/management-plane.md`, phase table).

**Way back:** nothing on `zero` depends on `three`. Stop the timer and leave the array.

### Restore

A restore onto `zero` runs from `zero`, with its restore key
(`hosts/zero/system/README.md` § A restore). On `three` itself, into a directory off
`received-backups`, with the owners and modes `zero` had, the pull's xattr read back:

```fish
# on three: list three's snapshots, then restore Immich's library from snapshot N into /media/mirror/restore; --fake-super reads the kept owners, -M--super writes them
sudo snapper --no-dbus -c received-immich list
sudo rsync -aHAX --numeric-ids --fake-super -M--super --mkpath /media/mirror/received-backups/immich/current/.snapshots/N/snapshot/data/library/ /media/mirror/restore/library/
```

Put a number from the list in place of `N`; its description, `pulled <M>`, names zero's
snapshot. A database to look into is a reflink copy of that snapshot's `db`, which costs no
space, started in a throwaway Postgres container, whose entrypoint gives the files back to
its own user (§ Slice 4 in [`plans/visit-runbook.md`](../../../plans/visit-runbook.md)).
Never `btrfs property set ... ro false` on a snapshot: copy it.

## The fan

The Argon EON's fan has a controller on the Pi's own I2C bus, bus 1 at `0x1a`, which takes
one byte. On this EON only the bottom of its range changes the speed: 0 stops the fan, 1 to
5 are five audibly different speeds, and everything from about 6 up sounds the same as 100.
With nothing writing to it, the fan runs at full speed. Leap's image leaves that bus off, so
three files work together:

- `system/extraconfig.txt` turns the bus on, with `dtparam=i2c_arm=on`, on the FAT boot
  partition at `/boot/efi`. openSUSE's `config.txt` there ends with `include
  extraconfig.txt`; an update of the firmware package rewrites `config.txt` and leaves this
  file alone. The firmware reads it only at power-on, so it takes a reboot.
- `system/i2c-dev.conf` loads `i2c-dev`, which makes `/dev/i2c-1`.
- `system/argon-fan`, run by `system/argon-fan.service`, steps the fan through seven
  levels, 0, 1, 2, 3, 4, 5 and 100: silent with the CPU below 45 °C and the drive below
  45 °C, 5 by a CPU of 60 °C or a drive of 49 °C, and 100 at 65 °C or 50 °C. It steps up as
  soon as either temperature asks for more, and down only once both are a few degrees below
  the level's entry point. It reads the CPU every 30 seconds.
- It reads the drive with `smartctl` about every 3 minutes while the drive is reading or
  writing, and not at all while it is idle: the CPU's idle temperature then stands in for
  the room, and one read is taken if the CPU rises 3 °C above where it was at the last
  reading. A SMART read on an idle drive that still spins would reset its standby timer,
  should one ever be set; a WD Red ships with none, so it does not spin down today.
  `smartctl` never wakes a drive that has spun down. An idle drive keeps its last reading
  for as long as it stays idle. It finds the drive by the array's label, `mirror-luks`;
  with the drive unplugged, it follows the CPU alone.
- A temperature it cannot read sets the fan to 100: the CPU's, a failed drive read, or a
  drive working for 6 minutes with no good read. So does a stop. Without the bus, it logs
  that and tries again every 30 seconds.

To change a level or a threshold, edit the numbers at the top of `system/argon-fan` and
commit. Then,
from the phone, and on `three`:

```fish
# on the phone: install the changed fan script on three; the first run shows it, the second installs it
cd ~/infra/ansible; and ansible-playbook playbooks/server-install-system-files.yml -l three -e only=argon-fan --check -K
ansible-playbook playbooks/server-install-system-files.yml -l three -e only=argon-fan -K
```

```fish
# on three: restart the fan's unit; the stop sets 100, the start picks the level again
sudo systemctl restart argon-fan.service
```

To check it:

```fish
# the fan's unit, then its log: each change of level with both temperatures and the reason,
# and the drive's readings when they move by 2 °C or more
systemctl status argon-fan.service
journalctl -b -u argon-fan.service
```

If the unit misbehaves, stop it, which sets 100, and set the fan by hand: 0 is off, 1 to 5
the quiet speeds, 100 full.

```fish
# stop the fan's unit, then write one byte to the controller, 3 here: 0 off, 1 to 5 quiet, 100 full
sudo systemctl stop argon-fan.service
sudo python3 -c 'import fcntl, os; f = os.open("/dev/i2c-1", os.O_RDWR); fcntl.ioctl(f, 0x0703, 0x1a); os.write(f, bytes([3]))'
```

## Before three ships

In the UK, `three` uses the static `.103`, which would also connect in Singapore and leave
no route out. So the last thing before the shipping power-off, after `ssh three`:

```fish
# Singapore: the static UK profile stops connecting, so the DHCP one takes over next boot
sudo nmcli connection modify wired connection.autoconnect no
# Wi-Fi only if Singapore has no Ethernet for it. The password is asked for and reaches the
# root-only profile on stdin, never on a command line, which sudo would log to the journal
read -s -P 'Wi-Fi password: ' psk; and printf '[connection]\nid=wifi\ntype=wifi\n\n[wifi]\nssid=%s\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' 'THE-SSID' $psk | sudo sh -c 'umask 077; cat > /etc/NetworkManager/system-connections/wifi.nmconnection'; and sudo nmcli connection reload; set -e psk
sudo systemctl poweroff
```

Put Singapore's network name in place of `THE-SSID`. The Wi-Fi lines are untested until
then, because the simulation has no radio.
The tracked `wired.nmconnection` then describes `three` as it was in the UK. Back in the UK,
`sudo nmcli connection modify wired connection.autoconnect yes` undoes the flip.
