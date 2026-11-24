# leap

How a host moves to openSUSE Leap 16.1 Immutable
([`docs/decisions.md`](../docs/decisions.md) § *Two OSes in the end state*): one USB stick,
made on the host's old Alpine system, that the new system reads once at its first boot.

| File | What it is |
|---|---|
| `firstboot.sh` | The first-boot steps every Leap host shares. Sourced by each host's script. |
| `pins` | The versions and SHA-256s of the binaries a package would get wrong (`cloudflared`, Compose): what a new host's first boot installs, and what `ansible/playbooks/server-update-leap.yml` moves a running host to. Also the Pi image's URL and SHA-256, which `plans/visit-runbook.md` must quote and no host reads. |
| `motd` | The update recipes every login shows, at `/etc/motd.d/50-infra-updates`: the normal update, and the locked boot firmware's. A plain file, with no `infra-` header for logins to show. |
| `make-stick` | Builds a host's stick, or with `--card` writes the same onto the host's new SD card. Run as root on the host's old system, or with `--new` for a host that has none. With `--bench` it writes the bench boot's config instead. |
| `bench/` | The bench boot's whole config: a script that makes `gavin` with his keys, enables sshd and gives the wired port `192.168.86.100`, and that port's profile. |
| `tailscale-repo.gpg` | Tailscale's repository signing key, fingerprint `2596 A99E AAB3 3821 893C 0A79 458C A832 957F 5868`. The first boot trusts the repository through this reviewed copy. |

Each host's own part is in `hosts/<host>/leap/`:

| Path | What it is |
|---|---|
| `combustion/script` | The host's first-boot script: its values, then the shared steps in order. |
| `system/` | Every `/etc` file the host gets, each with the `infra-` header that names where it installs ([`hosts/zero/system/README.md`](../hosts/zero/system/README.md)). When the host has moved, these replace `hosts/<host>/system/`, whose copies describe the Alpine system until then. |
| `MOVED` | The record that the host runs Leap, committed on the day it moved. While it exists, `bin/install-system-file`, `bin/check-system-drift` and the plays read `leap/system/`; without it they read `hosts/<host>/system/`. A new host such as `three` has one from its first boot. Deleting it is the repo's half of going back to the Alpine card ([`docs/decisions.md`](../docs/decisions.md) § *A host's move to Leap is a file in the repo*). |
| `fstab.append` | The data entries, appended to the image's own fstab. Each names its subvolume by `subvolid=`, never `subvol=`, so stock health-checker cannot strand the box ([`plans/microos-cutover.md`](../plans/microos-cutover.md)). Every entry on one filesystem carries the same `context=`, Docker's store included: the subvolumes share one superblock, and SELinux refuses a second mount of it whose options differ from the first, so mixed options would make which mounts fail depend on which mounted first. |
| `volumes` | The named Docker volumes the stick carries as tar files. |

## Making the stick

On the host's old system, from its checkout, with the stick plugged in, and with every
deployment that uses a listed volume stopped (`make-stick` refuses otherwise):

```fish
cd ~/infra; and git pull
sudo leap/make-stick one /dev/sdX
```

`make-stick` first names any tool it needs that is missing, with its Alpine package, and
refuses a host directory with a `FILL-FROM-` placeholder left in it. Then it refuses a
device that is not a whole USB disk, one that is mounted or used as swap, one holding a
UUID `/etc/fstab` names, and one over 256G. It also refuses a device where `blkid -p`
finds a bcache superblock, a LUKS header or a btrfs filesystem on the disk or on any
partition. That guard is for `zero`, whose array disks are on USB like a stick, and whose
bcache backing disks have no partitions and no UUID in fstab, so the guards before it miss
them. It refuses a carry-over with anything missing, among them a root password, which the
console needs. It asks for the device name before it writes anything, shows the device's
model and labels for that, and reads the device again after the answer: its place on the
USB bus, its size, its USB serial, its signatures and, for a card, its partition table. If
any of them changed while the prompt waited, it stops with nothing written.

It carries these where the old system has them, and leaves them out where it does not:

- **The array's key file**, `/etc/keys/data.key`, at 0400 in a 0700 directory. When the
  host's `system/crypttab` names a key file, `make-stick` refuses unless it is that one
  and this system has it, since without it the array cannot mount.
- **Tailscale's state**, `/var/lib/tailscale/tailscaled.state`, so the new system is the
  same node at the same tailnet address. The old system and the new one are then one
  node, and must never both be up.
- **root's restore key**, `/root/.ssh/restore` and its `.pub`, with the lines of root's
  `known_hosts` that name `three`, by its address in `ansible/group_vars/all.yml` or by
  name. `three` accepts only that key. A restore key with no such line is refused, since
  the first restore would then trust whatever answered at `three`'s address.

It refuses any `~gavin/.*-secrets` directory on a host with no `hosts/<host>/dev` link:
those are the dev containers' secrets, and a host without the dev stack has no use for
them. It lists every file and directory in the checkout that git does not track, ignored
ones included, other than the `.env` files it carries. The new system clones the
repository fresh, so a file in that list stays on the old system unless the owner copies
it.

### One card

With `--card`, `make-stick` writes onto the host's new SD card, in a USB reader, instead
of erasing a stick, so the day needs no stick (`plans/zero-leap.md` § One card):

```fish
cd ~/infra; and git pull
sudo leap/make-stick --card zero /dev/sdX
```

The card must be freshly flashed with the pinned image and read exactly as the image
does: a DOS partition table with two partitions, `EFI` (vfat) and then `ROOT` (btrfs),
root last, nothing after it. `make-stick` refuses anything else, and it never erases or
formats either partition. The disk guard lets through this one btrfs: `ROOT` on the
card's second partition, which the kernel has not mounted. `make-stick` moves the end of
root's partition entry to the last MiB boundary at least 256 MiB before the card's end,
and makes a third partition in that space, ext4 labelled `combustion`, with the same
contents a stick gets. It reads the table and both filesystems back to prove the first
two partitions are as they were, and the new label to prove Combustion will find it.

The partition is fixed at 256 MiB, so `make-stick` estimates the payload first, the
volumes' data included, and refuses a card whose payload is over 192 MiB, leaving room for
ext4's own journal and tables. A host whose volumes are larger uses a stick. Once the
table is rewritten, any failure prints a `make-stick:` line saying the card must be
flashed again before another try.

The first boot grows root's filesystem to fill its larger partition before it installs
anything. The `combustion` partition stays until the first boot's checks are done. It
holds a second copy of every secret on the card, and Combustion would read it again on
any boot caught by the relabel trap below, so the owner then discards it with
`blkdiscard`, deletes it and grows root into its space, by hand.

### The bench boot

`make-stick --bench <device>`, with or without `--card`, writes only `bench/`: a script
that makes `gavin` with the `authorized_keys` of the box it runs on, enables sshd and
gives the wired port `192.168.86.100`, and that port's profile. It carries no host key,
password hash, tunnel credential, key file or Tailscale state, and no fstab entry, so a
bench card holds nothing secret. `gavin` has no password and no sudo there. It runs on any
box of the fleet, and the card is flashed again after the bench
(`plans/zero-leap.md` § The bench boot).

### A new host

A host with no old system, `three` first, gets its stick from `make-stick --new <host>
<device>`, run on any other host of the fleet. It makes the new host's ssh host key on the
stick and prints its fingerprint, asks for the new host's root password, and takes gavin's
password hash and `authorized_keys` from the box it runs on. It carries no tunnel
credentials, `.env`, secrets directory or volume, and refuses a host whose directory has a
tunnel config or a volume list, since such a host has an old system to build on. The new
host's tunnel is made after its first boot, by `server-create-host-tunnel.yml`; until its
config is installed, the host's `cloudflared` unit is skipped by a condition.
[`hosts/three/leap/README.md`](../hosts/three/leap/README.md) has `three`'s steps.

The stick holds an ext4 filesystem labelled `combustion`. Everything is under
`combustion/`, because Combustion copies that directory alone and runs the script from the
copy:

```
combustion/script            the host's script
combustion/leap/             firstboot.sh, pins, motd and the Tailscale key
combustion/host/             the host's system/ files and fstab.append
combustion/carry/            the carry-over: ssh host keys, root's and gavin's password
                             hashes, gavin's authorized_keys, the tunnel credentials, each
                             deployment's .env and ~gavin/.<deployment>-secrets, the volumes
                             (a new host's: its new host key, the hashes and the keys only)
combustion/carry/keys/       the array's key file, where the old system has one
combustion/carry/tailscale/  Tailscale's state, where the old system has one
combustion/carry/root-ssh/   root's restore key and three's known_hosts lines, likewise
```

A bench config holds `combustion/script`, `combustion/bench/wired.nmconnection` and
`combustion/carry/gavin/authorized_keys`, and nothing else.

**The stick then holds live secrets.** Keep it with the other secret-bearing media, and
once the new system is proven, erase it whole, never by deleting files, which flash keeps:
`blkdiscard`, or `blkdiscard -z`, which writes zeros, on the many sticks that cannot
discard (`plans/visit-runbook.md` § Writing a card, and erasing a stick). A card's
`combustion` partition is discarded the same way before it is deleted.

## What the first boot does

Combustion runs the script twice. First with `--prepare`, in the initramfs before any
network is up: the host's NetworkManager profile goes in there, so the network Combustion
brings up for the packages already uses the host's own address rather than a DHCP lease.
Then for real, in the new system, in order: sets the clock from a plain-HTTP answer's
`Date` header (a Pi has no clock, and HTTPS refuses certificates from the future), checks
the carry-over, grows root's filesystem when the config came from the card itself (§ One
card), sets the hostname, installs the packages (Tailscale's from its own repository,
openSUSE's `docker-compose` locked out, the Pi's boot firmware locked), installs
`cloudflared` and Compose from their pinned downloads after checking each SHA-256, sets
root's password, makes `gavin` with his old uid and gid, his password and his keys,
installs the old ssh host keys and every file in `system/`, makes the `/media`
mountpoints, appends the fstab entries, enables the units, masks the update timer, turns
off the reboot strategy, keeps sshd, the network, `cloudflared`, `tailscaled` and logins
up in rescue mode, clones this repository into `~gavin/infra` with each deployment's
`.env`, and leaves the volume tar files in `/root/volumes` for the runbook to restore once
Docker runs. For the optional carry-over, `firstboot.sh` has a step each, which a host's
script calls when its stick carries the item: `install_data_key`, before the fstab
entries; `install_tailscale_state`, which writes through `/var`'s own subvolume, since
the shell Combustion runs in does not bind `/var/lib/tailscale`; and
`install_restore_key`. `check_carry` takes the items a host requires as arguments.

A failed step stops the script, and Combustion then rolls back the new snapshot: `/etc`,
the packages and everything else in it are gone. What the script wrote outside the
snapshot stays: `/home`, `/usr/local`, `/root`, `/var` and the FAT boot partition.
Combustion runs the script again at the next boot while its config is there, and that run
meets the half-written state, or, after the relabel trap below, a finished snapshot. So
each step checks what it would create and skips it when it is there: the groups, the
users, the clone, each fstab line and Tailscale's state. A group or user of the same name
but another id stops the script rather than being used. Everything the script prints is
also kept in `/var/log/infra-firstboot.log`, which survives a failed run: with no screen
to hand, a raw search of the card for `firstboot:` reads it.

**If the first boot never answers ssh** (it answers ping on its address, but port 22 is
refused): the script stopped. Read its log off the card on `two`, through the card reader
(`plans/visit-runbook.md` § Writing a card, and erasing a stick), by a raw search, since
the reader cannot mount a card the first boot grew:

```fish
# on two: search the card's root partition for the first boot's log lines, detached, into a file; put the card's device in place of sdX
sudo sh -c "setsid nohup sh -c 'dd if=/dev/sdX2 bs=4M count=1536 2>/dev/null | strings -n 8 | grep \"^firstboot: \" > /home/gavin/firstboot-lines.txt; echo done >> /home/gavin/firstboot-lines.txt' </dev/null >/dev/null 2>&1 &"
```

`cat ~/firstboot-lines.txt` once its last line says `done`; the `STOPPED` line says why.

## What it does not do

It does not join the tailnet, which needs the owner's login (`sudo tailscale up
--advertise-tags=tag:fleet --accept-dns=false`), and it does not start a deployment: those
are the visit's runbook, after the box answers.

## What the November visit's first boots taught

Found on `one` and `three`, 2026-11-18, and kept here because the next Leap first boot
(`zero`, phase 12) meets them again.

- **A first boot with a data disk missing is fatal, despite `nofail`.** Combustion always
  leaves `/etc/selinux/.autorelabel` in the new snapshot, and microos-tools'
  `selinux-autorelabel-generator` then makes one relabel unit per fstab entry, with
  `RequiresMountsFor=` and required by `local-fs.target`, ignoring `nofail`. It skips only
  `noauto`, `x-systemd.automount` and `_netdev` entries, so `three`'s `noauto` array is
  safe. The boot goes to emergency mode before `systemd-machine-id-commit`, so the next
  boot is a first boot again and Combustion re-runs on the finished snapshot. `one` met it
  when its SSD was not seen through a USB link. The same holds on any later boot that
  relabels. Options, for phase 12: the disk attached as a precondition (what the visit
  did), native `.mount` units for the data disks, or a report to microos-tools.
- **The Pi image's initramfs has no Wi-Fi** (no `brcmfmac`, firmware, `wpa_supplicant` or
  NetworkManager's Wi-Fi plugin, per build 3.17's initrd listing), so a first boot needs a
  wired LAN on `192.168.86.0/24`.
- **On a Pi, health-checker clears its flag:** `grub2-editenv - list` is empty after the
  first boot. **The system's journal starts at the image's build date** until the clock
  syncs, so early boot lines read 19 August, and `uptime` can read months for the same
  reason. Tailscale 1.104.7 was signed by `458ca832957f5868`.

## After the first boot: the named volumes

A named volume lives in Docker's store, which the new system starts empty, so each one the
host lists in `volumes` came across as a tar file and waits in `/root/volumes`. Restore it
before the deployment's first `up`, under the name and labels Compose gives its own, so
Compose adopts it rather than warning that it did not create it. For `one`, after `ssh one`:

```fish
# restore garmin-mcp's token volume, before garmin-mcp's first deploy; one chained line, so a
# failed step stops it before the tar, the only copy, is deleted
sudo docker volume create --label com.docker.compose.project=garmin-mcp --label com.docker.compose.volume=garmin-tokens garmin-mcp_garmin-tokens; and sudo tar --numeric-owner -C (sudo docker volume inspect -f '{{.Mountpoint}}' garmin-mcp_garmin-tokens) -xpf /root/volumes/garmin-mcp_garmin-tokens.tar; and sudo docker run --rm -v garmin-mcp_garmin-tokens:/v:ro docker.io/library/alpine:3.22 ls -la /v; and sudo rm /root/volumes/garmin-mcp_garmin-tokens.tar
```

The listing it prints is the volume as the container will see it; the tar is deleted only
after that read succeeds. `--numeric-owner` restores each file's owner by number, as Alpine
recorded it, whatever names Leap gives those numbers.

The project and volume labels are the deployment's `name:` and the volume's key in its
`compose.yaml`; the volume's name is the two joined by `_`. The simulation runs the same
commands, in bash under `set -e`, which stops at a failed step as the chain does, and reads
the volume back through a container.

## Updating a host, and moving a pin

Every update is by hand, one host at a time, from the control node:

```fish
# update one Leap host: transactional-update, the pins, the reboot, and the checks after
cd ~/infra/ansible
ansible-playbook playbooks/server-update-leap.yml -e target=one -K
```

It asks before it reboots, reports any update a lock held back and the Compose openSUSE
offers, and is done only once the box answers over the tunnel and the tailnet. Its header
says each step. `--check` reads and reports and changes nothing.

`cloudflared` and Compose are pinned binaries in `/usr/local`, outside every snapshot. A pin
moves by a commit to `pins`, with the version and both architectures' SHA-256 from the
project's own release page, then that play. The play keeps the binary it replaces:
`/usr/local/lib/cloudflared.previous` and `/usr/local/lib/docker/docker-compose.previous`.

### By hand

When the play cannot run, on the box, with the version and the SHA-256 from the project's
own release page (for Compose, the release's `.sha256` asset):

```fish
# move Compose to a new release, keeping the old one beside, not in, the plugin directory;
# put the release's sha256 for docker-compose-linux-aarch64 in place of PASTE_SHA256_HERE
set v 5.7.0; set sum PASTE_SHA256_HERE
curl -fsSL -o /tmp/docker-compose https://github.com/docker/compose/releases/download/v$v/docker-compose-linux-aarch64
echo "$sum  /tmp/docker-compose" | sha256sum -c -; and sudo cp -p /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/docker-compose.previous; and sudo install -m 755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version
```

The previous binary is kept in `/usr/local/lib/docker/`, not in `cli-plugins/`, where Docker
would read any `docker-*` file as a plugin. Going back is the same `install` from there.
`cloudflared` moves the same way, at `/usr/local/bin/cloudflared`, its previous kept at
`/usr/local/lib/cloudflared.previous`, followed by `sudo systemctl restart cloudflared`, which is the tunnel: do it over Tailscale, not through the
tunnel itself (CLAUDE.md § Changing the thing you are connected through): from a device on
the tailnet, or at the console, since the phone's one VPN slot is taken.

## How it is tested

`sim/microos/run-host.sh` boots each host's real script in a Leap VM, from a stick laid out
as `make-stick` lays it out, with stand-ins for the carry-over and the host's disks, and
checks the box it makes ([`sim/microos/README.md`](../sim/microos/README.md)). `make-stick`
itself reads a live Alpine host and writes a real USB device, so CI runs neither it nor
`--card`'s partitioning, and the bench boot is the first run of `--card`. The stand-in
carry-over has no key file, Tailscale state or restore key, the stand-in stick is a disk
of its own, and each host's script runs once. So CI runs `grow_root`'s stick branch only,
and none of `install_data_key`, `install_tailscale_state`, `install_restore_key`, the card
branch or a second run. `zero`'s simulation is to run them (`plans/zero-leap.md` § The
build, item 6).

That VM is x86_64, so `.github/workflows/pi-image.yml` covers what it cannot. Its `image`
job downloads the Pi image `pins` names, checks its SHA-256 and inspects it read-only with
`sim/pi-image/inspect.sh`: whether the initrd carries Combustion, which Wi-Fi firmware and
packages the image has, what is on its FAT partition and its partition table. For `zero`
it also reads the Pi 5's device tree and the `[pi5]` section of `config.txt`, asks the
image's own `modprobe` which drivers the SD card and the RP1 Ethernet need and whether the
initrd has them, finds the array's `bcache`, `dm-crypt` and Adiantum modules, and checks
that `bcache-tools` is absent. It does the same for the newest build openSUSE publishes,
once that is not the pinned one. It reports
ANSWER lines and fails only when a download or checksum fails; a pinned build openSUSE has
since withdrawn is reported, since the pin records the copy kept on `two`. It runs when
`pins`, the script or the workflow changes.

`.github/workflows/leap-pins.yml` downloads both architectures' `cloudflared` and Compose
and fails when one differs from its SHA-256 in `pins`, or when `plans/visit-runbook.md`
quotes another image or names another build. It runs when `pins` or the runbook changes.
