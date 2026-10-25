# Recovery

For a box that rebooted while you are remote: getting its deployments back without losing
data or the way in. Read it on the phone, which is the control node.

What should be running is [fleet-inventory.md](fleet-inventory.md), which a playbook
generates from the boxes themselves. Its Listening section for the host you are
recovering is the shortest description of "back to normal" this repo has, and the checks
below compare against it.

## First, on any host

```fish
sudo bin/check-mount-guards
```

It checks that every `/media` mount is `nofail` and that every bare mountpoint under it is
immutable, by trying a write. If it fails, start nothing: read *The mount trap* below
first, because a container started over an unmounted path writes into it.

## Bring the deployments back

Docker restarts every deployment's containers on its own after a reboot: each one says
`restart: always` or `unless-stopped`. So look first, and start only what is missing.

```fish
sudo docker ps --format '{{.Names}}  {{.Status}}'
```

Each deployment is started with stock Compose, from its directory on the host. Compose
reads `.env` from that directory and needs nothing else from this repo.

**`one`:**

```fish
cd ~/infra/deployments/torrents;     sudo docker compose up -d
cd ~/infra/deployments/send2ereader; sudo docker compose up -d
cd ~/infra/deployments/garmin-mcp;   sudo docker compose up -d
cd ~/infra/deployments/calibre-web;  sudo docker compose up -d   # once set up (its README)
netstat -tln | grep -E '8080|8384|22000'                        # all three
sudo docker ps --filter name=cloudflared --format '{{.Names}}  {{.Status}}'   # each (healthy)
```

`send2ereader`, `garmin-mcp` and `calibre-web` publish no port. Each is reached through a
`cloudflared` sidecar in its own project, which dials out to its own tunnel, so the
sidecar's health is the check, not `netstat`. `send2ereader`'s project refuses to start
until its first deploy from the control node has written its tunnel settings (its README).

`ionic-traces` stays stopped, and 7777 is expected to be absent. It was stopped by
decision ([management-plane.md](management-plane.md), 2c): it has very few users, only its
database is worth anything, and starting it would restart the crash loop that stopping it
ended, on the one copy of that database. Its compose file, `SOURCE` and `.env` remain, so
repairing it is for a person to decide, not a reboot.

On `one`, state is on `/media` bind mounts, except `garmin-mcp`'s Garmin session, which is
the named volume `garmin-tokens` on the SD card. Recreating a container loses nothing;
`docker volume prune` or `docker compose down -v` loses that session, and logging in again
needs the MFA step in its README.
After gluetun is recreated, expect a new forwarded port
([port-forwarding.md](port-forwarding.md)).

**`zero`:**

```fish
cd ~/infra/deployments/immich;    sudo docker compose up -d
cd ~/infra/deployments/syncthing; sudo docker compose up -d
netstat -tln | grep -E '2283|8384|22000'                        # all three
```

On `zero`, recreating `immich_postgres` is fine, but losing or shadowing its mount is
not: the database cluster is on `/media/immich-db`. Immich writes a nightly `pg_dump` to
`/media/immich-data/backups/`, on the same array as the data, so it covers logical
corruption and not the array's loss. Take a dump off the array before anything invasive.

**`two`:** nothing to bring back. Its one deployment, `destiny-director`, is stopped since
2026-10-25 with its files kept ([README](../README.md)).

**Two things the greps do not show, by design.** The dev containers' ports (2222, 2223,
`127.0.0.1:2224`) are absent after a reboot, because nothing starts those containers; a
grep for them would only ever fail. And 8384 and 22000 are Syncthing on host networking,
on both boxes: they appear in `netstat` but not in `docker ps`'s ports. `one`'s Syncthing
is part of the `torrents` deployment and syncs a different share from `zero`'s.

## The dev containers on `zero`

They are `restart: no` and stay down after a reboot, because they hold live sessions and
uncommitted worktrees. Each is started by hand, with `make dev` in its own repo:

| container | start it from |
|---|---|
| `dd-dev` (its database `dd-mysql` comes up with it) | `~/destiny-director` |
| `ds-dev` | `~/dossier` |
| `or3-dev` | `~/or3` |
| `infra-dev` | `~/infra` |

**Their volumes cannot be recreated.** `<project>_*-claude` holds the Claude Code login
and the session history (22 MB of it for `or3-dev`), so a container rebuilt without its
volume comes back logged out and empty. Check `sudo docker volume ls` on `zero`, or the
Volumes section of [fleet-inventory.md](fleet-inventory.md), before removing anything.

**`infra-dev` is not a control node.** It carries Ansible and the inventory but has no
route to `zero`, `one` or `two`, by decision
([management-plane.md](management-plane.md) § *A control node inside the fleet*), so it
cannot run a playbook against a host. When the fleet is broken, the phone is the control
node. `infra-dev` also runs on `zero`, so it cannot help when `zero` is down
([dev/README.md](../dev/README.md)).

## The mount trap

If a volume fails to mount, a container that bind-mounts that path starts against an
empty directory and writes into it. On `zero` that is Immich coming up with a blank
library and Postgres running `initdb` over nothing. Docker's init script declares only
`need sysfs cgroups net`, so nothing in the boot order waits for the mounts.

Two guards stop it, and `bin/check-mount-guards` verifies both:

1. **`nofail`** on every `/media/*` fstab entry, so a missing array never stalls boot.
2. **`chattr +i` on the bare mountpoints**, the directories on the root filesystem
   underneath the btrfs mounts. While the array is mounted the flag is hidden and does
   nothing. If the array fails to mount, every write to that path returns EPERM, even for
   root, so a container fails loudly instead of writing.

What it looks like when it fires: a container in a crash loop with a message that reads
like its own bug, such as `chown: ... Operation not permitted`. That happened on `one` in
August 2026, and the database on the unmounted disk was untouched.

**You will one day get `Permission denied` as root on an unmounted `/media` path**, while
`ls -ld` shows an ordinary directory. That is the guard. To do legitimate work on a bare
mountpoint:

```fish
sudo umount /media/immich-data
sudo chattr -i /media/immich-data      # the step you will forget
#   ... the work ...
sudo chattr +i /media/immich-data      # put it back
sudo mount /media/immich-data
sudo bin/check-mount-guards            # prove you put it back
```

`lsattr -d` on a mounted path reports the mounted filesystem's root, not the directory
underneath it. `bin/check-mount-guards` bind-mounts `/` to see the real directories.

An OpenRC service that checked the mounts and refused to start Docker was tried and
dropped. It put new code on the boot path, made a new way for a box to come up with no
containers, and had a false failure: renaming a Syncthing share would have stopped Docker
at the next reboot. The immutable flag makes the bad write impossible rather than
detected. On MicroOS, `RequiresMountsFor=` replaces it.

## Why a missing disk does not stop boot

**`one`:** every `/media` mount is on the MX500 (`/dev/sda1`, the only disk), with
`nofail`, and every bare mountpoint is immutable. All four were checked empty before the
flag went on, in August 2026. `calibre-web` adds two more (`/media/calibre/library` and
`/media/calibre/config`); the tracked fstab has carried them since 2026-10-24, and they
get both guards when its README's step 2 creates them. OpenRC would boot without the array
regardless: `critical_mounts` is empty in `/etc/conf.d/localmount`, so `localmount` exits
0, and every `/media` entry has fsck pass 0. Only `/` and `/boot`, both on the SD card,
are checked. A reboot with no hands was tested on 2026-08-24: every subvolume mounted,
every container up, the guards intact.

If `one`'s array is missing after a reboot, read what the kernel found with
`cat /proc/partitions`, not `lsblk`, which opens the block devices and can hang a fragile
USB bridge. A wedged USB-SATA bridge cannot be fixed from software: every kernel-side
reset was tried in August 2026, and only cutting the enclosure's power brought it back
(2026-08-24). The MX500 is still in that Sabrent enclosure.

**`zero`:** all three `/media` entries carry `nofail`. The array is btrfs RAID1 across two
bcache devices, so both must assemble before it can mount read-write; btrfs refuses a
degraded RAID1 mount without `degraded`. `/etc/init.d/bcache-register` registers them and
waits up to 30 seconds for `/dev/bcache0` and `/dev/bcache1`. It always exits 0, so a
failure there never stops the boot, and the immutable mountpoints mean nothing is written
while the array is absent.

**`two`:** root on `/dev/mmcblk0p2`, an ordinary writable install, and no `/media` data
mounts, so neither guard applies. Diskless mode is planned, not done
([host-setup.md](host-setup.md)); after that switch an `/etc` change is lost on reboot
unless committed with `lbu`.

**This protection is OpenRC's, and systemd removes it.** On systemd an fstab entry without
`nofail` becomes a dependency of `local-fs.target`: a missing disk stalls boot for about
90 seconds and then drops to emergency mode, with no network and no ssh. Before the first
reboot on any systemd distro, every `/media` entry needs

```
nofail,x-systemd.device-timeout=10
```

and every unit that touches those paths needs `RequiresMountsFor=/media/<path>`.
`Wants=` is not enough: it is advisory, so the container starts anyway.

## Name mounts by filesystem UUID, never `by-id`

The Sabrent dual-bay USB enclosure reports the same serial (all zeros) and the same WWN
for both drives, so `/dev/disk/by-id/` names collide. With both bays full (until
2026-08-24), `one`'s base link pointed at one disk while its `-part1` and `-part2` links
pointed into the other, and names could swap across reboots. One bay is empty now; the
collision returns with a second disk.

So the usual advice, `by-id` over `/dev/sdX`, is wrong here. Use the filesystem UUID,
which is stored inside the filesystem: the fstabs do, and a systemd `.mount` unit must too
(`What=/dev/disk/by-uuid/...`). `zero`'s `bcache-register` registers by
`/dev/disk/by-uuid/` as well, which there is the bcache superblock's UUID.

`one`'s and `zero`'s fstabs are tracked in `hosts/<host>/system/fstab` and installed with
`bin/install-system-file`, which checks their UUIDs against the running system. Edit the
tracked copy; never generate it.

## Don't break the way in

Each host runs `cloudflared` from `/etc/init.d/cloudflared`, and its tunnel is how you
reach the box. The secret is `/etc/cloudflared/<host>.json`, mode 0600, owned by root.
`/etc/cloudflared/config.yml` is tracked in `hosts/<host>/system/cloudflared-config.yml`
and holds the tunnel id, the path to that secret, the metrics port and the routing. Every
tunnel is locally managed, so that file is the routing in force. No host passes a token on
the command line.

**Rebuilding a tunnel needs two files, not a token.** `config.yml` installs from the repo
with `bin/install-system-file cloudflared-config.yml`. `<host>.json` is not in the repo:
regenerate it from the tunnel's token in Zero Trust, which is base64 of
`{"a":AccountTag,"t":TunnelID,"s":Secret}` and maps to
`{"AccountTag":...,"TunnelID":...,"TunnelSecret":...}`.

**Cycle it with stop, wait, start, never `rc-service cloudflared restart`.** The config
pins the metrics port, cloudflared's grace period is 30 seconds, and `restart` does not
wait: the new process cannot bind the port the old one still holds, exits 1, and
`supervise-daemon` gives up after five respawns. That took a tunnel down on 2026-08-23.
Stop it, poll until `127.0.0.1:20241` is free, then start it.

**Never from a session that goes through the tunnel you are cycling.** `ssh-zero.gsrpi.uk`
is `zero`'s tunnel. Come in another way: through `two` as a bastion (`ssh zero-two`)
inside a `screen` session that survives its ssh dying, or from `one` over the LAN, which
is `zero`'s second way in. Every change on `zero` is designed to fail degraded (box up,
network up, sshd up) rather than unbootable, so that a second way in stays useful. The
two-phase procedure, with its byte-for-byte check of the new command line before anything
restarts, is in [CLAUDE.md](../CLAUDE.md#changing-the-thing-you-are-connected-through).

**`/ready` is not enough to call a tunnel healthy.** It reports that the connector is
registered with Cloudflare and knows nothing about routing, so a tunnel serving 404 for
everything still reads healthy. `curl 127.0.0.1:20241/config` shows the rules in force;
then fetch a real hostname end to end. Counting sockets on port 7844 reads 0 on a tunnel
that is serving, so never use it as the verdict.

**After touching `/etc/init.d`, grep the directory for tokens:**

```fish
sudo grep -rl eyJ /etc/init.d/
```

A backup of the init script, made when the token moved out of it, sat in that directory
on `one` for a month with the token inline and mode 755 (found and removed 2026-08-23). A
check of the file being fixed passes while the copy beside it leaks. Anything executable
in `/etc/init.d` is also an OpenRC service, so a backup there shows up as a phantom
stopped service. Back up outside the directory, at 0600.

## Privileges, and what not to touch

`gavin` is in `wheel`, where `sudo` asks for a password, and not in `docker`: that group
is root-equivalent, because anyone in it can bind-mount `/` into a container. The group
exists and is empty. Rootless Podman later removes the question.

Do not touch `/boot`, the kernel, the bootloader, `/etc/init.d/cloudflared`, or any
bind-mount source under `/media`.

**Never `apk del containerd` on a Docker host.** `docker-engine` depends on the package:
`/usr/bin/containerd` and `containerd-shim-runc-v2` are the binaries that dockerd's own
containerd and every running container's shim run from. Removing it kills every container
at the next start or boot, and the dev containers do not come back on their own. The
standalone `containerd` service is unused and is out of the runlevel; the package stays.
