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

## The stick

`three` has no old system to carry anything from, so its stick is built on `one`'s Alpine
system, the board that becomes `three`:

```fish
cd ~/infra; and git pull
sudo leap/make-stick --new three /dev/sdX
```

It makes `three`'s ssh host key on the stick and prints its fingerprint: check it at the
first `ssh three`. It asks for `three`'s root password, which the console needs. It takes
gavin's password hash and keys from `one`. It carries no tunnel credentials, `.env` or
volume, because `three` has none yet.

## After the first boot: the tunnel

The first boot leaves `cloudflared` installed and enabled, and skipped until its config
exists. On the LAN, from the phone, with `three` in the inventory's `[fleet]` group:

1. `server-create-host-tunnel.yml -e target=three -K` writes `/etc/cloudflared/three.json`
   and prints the tunnel id.
2. The infra agent commits `system/cloudflared-config.yml` with that id, in the shape of
   every host's.
3. On `three`: `git pull`, `sudo bin/install-system-file` the config, then
   `sudo systemctl start cloudflared`.

## The array

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
ssh -t three sudo systemctl start systemd-cryptsetup@mirror.service media-mirror.mount
```

The mount starts Docker, which brings Syncthing up under its restart policy, and the
snapshot and scrub timers. Until then, Docker is skipped by its condition, and `docker`
answers that it cannot connect. The fstab entry gives the mount 5 minutes for the
passphrase. A backup run against a locked `three` fails and the next one retries.

To lock it again without a reboot:

```fish
# lock three's array: Docker first, then the mount, then the LUKS volume
ssh -t three sudo systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service
```

### Snapshots and scrubs

Twice a day, `mirror-snapshot` makes at most one read-only snapshot of `incoming`, named for
the day in UTC, and keeps the newest 90. It skips a turn while the backup user has a
process. The scrub runs monthly. A turn missed while the box was off or locked runs once
the array is unlocked. `btrfs scrub status /media/mirror` shows the last result.

## Before three ships

In the UK, `three` uses the static `.103`, which would also connect in Singapore and leave
no route out. So the last thing before the shipping power-off, after `ssh three`:

```fish
# Singapore: the static UK profile stops connecting, so the DHCP one takes over next boot
sudo nmcli connection modify wired connection.autoconnect no
# Wi-Fi only if Singapore has no Ethernet for it; the password is asked for, so it never
# lands in history or scrollback, and NetworkManager keeps it in a root-only file
read -s -P 'Wi-Fi password: ' psk; and sudo nmcli connection add type wifi con-name wifi ssid 'THE-SSID' wifi-sec.key-mgmt wpa-psk wifi-sec.psk $psk; set -e psk
sudo systemctl poweroff
```

Put Singapore's network name in place of `THE-SSID`. The Wi-Fi lines are untested until
then, because the simulation has no radio.
The tracked `wired.nmconnection` then describes `three` as it was in the UK. Back in the UK,
`sudo nmcli connection modify wired connection.autoconnect yes` undoes the flip.
