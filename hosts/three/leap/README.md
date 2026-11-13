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
`make-stick` refuses a stick while they are there. Both exist once zero is on the tailnet.
After `ssh zero`:

```fish
# make zero's backup key, root's alone, and print the two values for the infra agent
sudo install -d -m 700 /root/.ssh
sudo ssh-keygen -t ed25519 -N '' -C 'zero mirror-backup' -f /root/.ssh/mirror-backup
sudo cat /root/.ssh/mirror-backup.pub
tailscale ip -4
```

The infra agent commits them in place of the placeholders, and the stick can be built.

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
4. On `three`, in `~/infra`: `git pull`, then
   `sudo bin/install-system-file cloudflared-config.yml --commit --allow-content-change --new`,
   then `sudo systemctl start cloudflared`. The tools read `leap/system/` for a host with
   no Alpine copies.
5. `server-create-fleet-ssh-access.yml -e host=three` gates `ssh-three` behind Access,
   admitting each client's fleet token, as it does every box's ssh hostname. It reads the
   routing from `leap/system/`, and refuses unless this client's ssh config already sends
   `three` through `~/.config/fleet/access-ssh`, which the fleet ssh block does once the
   infra agent has added `three` to it.

The play leaves `syncthing-three` alone, since a browser needs a login, not a service
token. That hostname also has no DNS record, because the tunnel play makes `ssh-three`'s
only. It needs an Access application with a login, as `one`'s Syncthing GUI has, and then
a CNAME to `three`'s tunnel, in that order so the GUI is never open. No play makes either
for a host's own tunnel yet, so until both exist the GUI cannot be reached from outside.

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
