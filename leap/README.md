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
its own repository, openSUSE's `docker-compose` locked out, the Pi's boot firmware locked), installs `cloudflared` and
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

## Moving a pin by hand

`cloudflared` and Compose are pinned binaries in `/usr/local`, outside every snapshot, until
the Leap update play moves them. By hand, on the box, with the version and the SHA-256 from
the project's own release page (for Compose, the release's `.sha256` asset):

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
`cloudflared` moves the same way, at `/usr/local/bin/cloudflared`, followed by `sudo
systemctl restart cloudflared`, which is the tunnel: do it over Tailscale, not through the
tunnel itself (CLAUDE.md § Changing the thing you are connected through).

## How it is tested

`sim/microos/run-host.sh` boots each host's real script in a Leap VM, from a stick laid out
as `make-stick` lays it out, with stand-ins for the carry-over and the host's disks, and
checks the box it makes ([`sim/microos/README.md`](../sim/microos/README.md)). `make-stick`
itself reads a live Alpine host, so CI does not run it.
