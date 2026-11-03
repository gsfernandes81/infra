# leap

How a host moves to openSUSE Leap 16.1 Immutable
([`docs/decisions.md`](../docs/decisions.md) § *Two OSes in the end state*): one USB stick,
made on the host's old Alpine system, that the new system reads once at its first boot.

| File | What it is |
|---|---|
| `firstboot.sh` | The first-boot steps every Leap host shares, and the pins for the binaries a package would get wrong (`cloudflared`, Compose). Sourced by each host's script. |
| `make-stick` | Builds a host's stick. Run as root on the host's old system. |
| `tailscale-repo.gpg` | Tailscale's repository signing key, fingerprint `2596 A99E AAB3 3821 893C 0A79 458C A832 957F 5868`. The first boot trusts the repository through this reviewed copy. |

Each host's own part is in `hosts/<host>/leap/`:

| Path | What it is |
|---|---|
| `combustion/script` | The host's first-boot script: its values, then the shared steps in order. |
| `system/` | Every `/etc` file the host gets, each with the `infra-` header that names where it installs ([`hosts/zero/system/README.md`](../hosts/zero/system/README.md)). When the host has moved, these replace `hosts/<host>/system/`, whose copies describe the Alpine system until then. |
| `fstab.append` | The data entries, appended to the image's own fstab. Each names its subvolume by `subvolid=`, never `subvol=`, so stock health-checker cannot strand the box ([`plans/microos-cutover.md`](../plans/microos-cutover.md)). Every entry on one filesystem carries the same `context=`, Docker's store included: the subvolumes share one superblock, and SELinux refuses a second mount of it whose options differ from the first, so mixed options would make which mounts fail depend on which mounted first. |
| `volumes` | The named Docker volumes the stick carries as tar files. |

## Making the stick

On the host's old system, from its checkout, with the stick plugged in, and with every
deployment that uses a listed volume stopped (`make-stick` refuses otherwise):

```fish
cd ~/infra; and git pull
sudo leap/make-stick one /dev/sdX
```

It refuses a device that is not a whole USB disk, one that is mounted, one over 256G, a
host directory with a `FILL-FROM-` placeholder left in it, and a carry-over with anything
missing, among them a root password, which the console needs. It asks for the device name
before it erases anything.

The stick holds an ext4 filesystem labelled `combustion`. Everything is under
`combustion/`, because Combustion copies that directory alone and runs the script from the
copy:

```
combustion/script            the host's script
combustion/leap/             firstboot.sh and the Tailscale key
combustion/host/             the host's system/ files and fstab.append
combustion/carry/            the carry-over: ssh host keys, root's and gavin's password
                             hashes, gavin's authorized_keys, the tunnel credentials, each
                             deployment's .env and ~gavin/.<deployment>-secrets, the volumes
```

**The stick then holds live secrets.** Keep it with the other secret-bearing media, and
once the new system is proven, erase it with `blkdiscard`, never by deleting files, which
flash keeps.

## What the first boot does

Combustion runs the script twice. First with `--prepare`, in the initramfs before any
network is up: the host's NetworkManager profile goes in there, so the network Combustion
brings up for the packages already uses the host's own address rather than a DHCP lease.
Then for real, in the new system, in order: checks the carry-over, sets the hostname, installs the packages (Tailscale's from
its own repository, openSUSE's `docker-compose` locked out), installs `cloudflared` and
Compose from their pinned downloads after checking each SHA-256, sets root's password,
makes `gavin` with his old uid and gid, his password and his keys, installs the old ssh
host keys and every file in `system/`, makes the `/media` mountpoints, appends the fstab
entries, enables the units, masks the update timer, turns off the reboot strategy, keeps
sshd, the network, `cloudflared`, `tailscaled` and logins up in rescue mode, clones this
repository into `~gavin/infra` with each deployment's `.env`, and leaves the volume tar
files in `/root/volumes` for the runbook to restore once Docker runs.

A failed step stops the script, and Combustion then leaves the image unconfigured rather
than half-configured.

## What it does not do

It does not join the tailnet, which needs the owner's login (`sudo tailscale up`), and it
does not start a deployment: those are the visit's runbook, after the box answers.

## How it is tested

`sim/microos/run-host.sh` boots each host's real script in a Leap VM, from a stick laid out
as `make-stick` lays it out, with stand-ins for the carry-over and the host's disks, and
checks the box it makes ([`sim/microos/README.md`](../sim/microos/README.md)). `make-stick`
itself reads a live Alpine host, so CI does not run it.
