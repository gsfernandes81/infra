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

`system/backup-authorized-keys` carries two of zero's values as placeholders, and
`make-stick` refuses a stick while they are there. Both exist once zero is on the tailnet
(`server-install-tailscale.yml`). From the phone:

```fish
# on the phone: make zero's backup key if it has none, and print the values three's key line needs
cd ~/infra/ansible; and ansible-playbook playbooks/server-create-backup-key.yml -e target=zero -K
```

It makes `/root/.ssh/mirror-backup` only if no key is there, and prints its public key,
zero's tailnet address and the key's fingerprint. The infra agent commits the key and the
address in place of the placeholders, checking the key against the fingerprint, and the
stick can be built. [`plans/visit-runbook.md`](../../../plans/visit-runbook.md) § Before
the visit, step 4, is the same step.

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
`/etc/crypttab` names. Inside is a btrfs holding `incoming` (where zero's backup lands),
`syncthing` and `snapshots`.

### Unlocking, after every boot

Every boot leaves the array locked, and nothing waits for it. From the phone:

```fish
# unlock three's array; sudo asks for gavin's password, then systemd for the passphrase
ssh -t three 'sudo systemctl start systemd-cryptsetup@mirror.service; and sudo systemctl start media-mirror.mount'
```

Two starts, so the mount's 5-minute wait for the device begins only once the passphrase is
in, however long finding it takes. The mount starts Docker, which brings Syncthing up
under its restart policy, and the snapshot and scrub timers. Until then, Docker is skipped
by its condition, and `docker` answers that it cannot connect. A hand `mount /media/mirror`
starts none of them: only `systemctl start` does. For a few seconds while Docker first
starts, a new ssh connection can be refused; the simulation saw one attempt fail between
two that answered. Try again. The cause is not yet known (`docs/management-plane.md`,
phase 9). A backup run against a locked `three`
fails and the next one retries.

To lock it again without a reboot (Docker, a running snapshot and a running scrub stop
with the mount). The passphrase is not cached, so the next unlock asks for it again:

```fish
# lock three's array: Docker first, then the mount, then the LUKS volume; it prints
# "locked" only once the volume is really closed
ssh -t three 'sudo systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service; and test ! -e /dev/mapper/mirror; and echo locked'
```

### Snapshots and scrubs

Twice a day, `mirror-snapshot` makes at most one read-only snapshot of `incoming`, named for
the day in UTC, and keeps the newest 90. It skips a turn while the backup user has a
process. The scrub runs monthly. A turn missed while the box was off or locked runs once
the array is unlocked. `btrfs scrub status /media/mirror` shows the last result.

## The backup

zero pushes it nightly at 04:00 (`hosts/zero/system/mirror-backup`) into `incoming`, over
the tailnet, with a key that starts only the rsync daemon of `system/rsync-backup.conf`. That
daemon runs as the backup user and can only write into `incoming`: it serves no file back,
lists nothing, and confines every name and symlink to that directory. The backup user is not
root, so each file's real owner and mode travel in an xattr (`--fake-super`), and a restore
puts them back.

A restore from a snapshot on `three`, into a directory that is not on the array's
`incoming`, with owners and modes as zero had them. After `ssh three`:

```fish
# restore Immich's library from a snapshot; --fake-super reads the kept owners, -M--super writes them
sudo ls /media/mirror/snapshots
sudo rsync -aHAX --numeric-ids --fake-super -M--super --mkpath /media/mirror/snapshots/2026-11-20/immich/library/ /media/mirror/restore/library/
```

Use a date the listing shows in place of `2026-11-20`. Getting a restore back onto zero is
the visit runbook's.

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
