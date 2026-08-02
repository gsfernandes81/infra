# Recovery and boot model — host `one`

Written for the case that matters: you are remote, on a ship link, and `one` has
rebooted. What follows is why it comes back, and what would stop it.

## Remote access path — do not break this

`cloudflared` runs from `/etc/init.d/cloudflared` (OpenRC). **The tunnel token is in
plaintext in that file**, which is mode 755 and world-readable. That is a fourth
secret beyond the three in `.env` files.

**Phase 2 deliberately did not touch it.** It is the remote-access path; changing it
while remote risks locking yourself out for months to fix a permissions nicety.

Future job, **to be done while physically present**: move the token to
`/etc/conf.d/cloudflared` (mode 600) and have the init script source it. Rotate the
token afterwards, since the old value has been readable by any local user.

## Why a missing USB disk does not stop boot — today

All four `/media/*` btrfs mounts live on `/dev/sdb1`, a USB SSD, and **none of them
carry `nofail`**. On Alpine + OpenRC that is currently safe, for four separate
reasons:

1. `/etc/conf.d/localmount` leaves `critical_mounts` commented out, and
   `/etc/init.d/localmount` forces `rc=0` when it is empty — a failed `mount -a` logs
   an error and boot continues.
2. All four `/media/*` entries are **passno 0**, so `fsck` never touches them.
3. Only `/` and `/boot` are fsck'd, and both are on the SD card, not the USB disk.
4. Swap is on the same USB disk; a failed `swapon` is non-fatal under OpenRC.

`/etc/fstab` is **tracked as a reference copy only** at `hosts/one/system/fstab`. This
repo documents it; it does not control it. Generating a real fstab from repo fragments
was considered and rejected — it puts a generated file directly on the boot path,
which is the one red line.

There is **no `/etc/crypttab`** on `one`, no `/dev/mapper`, no LUKS. Nothing to track.

## The blocking checklist item for the systemd migration

**This is exactly what breaks on any systemd distro. Read this before the first reboot
after migrating.**

Under systemd, an `/etc/fstab` entry without `nofail` becomes a dependency of
`local-fs.target`. If `/dev/sdb1` is missing or slow to enumerate — a USB disk, on a
Pi — boot stalls for ~90 s and then drops to **emergency mode**: no network, no SSH,
and you are not in the building.

Before rebooting on systemd, every `/media/*` entry needs:

```
nofail,x-systemd.device-timeout=10
```

Better still, on systemd these become individual `.mount` units in
`/etc/systemd/system/`, which are one file per mount, individually trackable, and can
express `After=`/`Requires=` ordering against containers — which fstab cannot. That is
the migration target, and it is the real answer to "there is no `fstab.d`".

## The silent-corruption trap — the one line to remember

If a data volume fails to mount, a container that bind-mounts that path **starts
happily against an empty directory** and begins writing into it. On `one` that would
mean qBittorrent with an empty config; on `zero` it would mean Immich coming up with a
blank library.

Guard every such unit:

```
RequiresMountsFor=/media/torrents
```

in the Quadlet file. It derives the correct `.mount` dependency automatically, so you
cannot get the unit name wrong.

**`Wants=` is not sufficient.** It is advisory — the container starts anyway if the
mount failed, straight into this trap. It needs `Requires=` + `After=`, or just
`RequiresMountsFor=`.

## Privilege model

`gavin` is in `wheel`, and sudo requires a password. `gavin` is **not** in the
`docker` group; the group exists (gid 102) and is empty. That is deliberate, not an
oversight — membership of `docker` is root-equivalent, because anyone in it can
bind-mount `/` into a container.

The restructure in Phase 2 needed exactly one privileged command:

```sh
sudo chown -R gavin:gavin ~/docker-compose
```

Everything after it was unprivileged. Config files are read by the `docker compose`
CLI as the invoking user; the daemon runs as root and reads them regardless of owner.
Nothing under `/media` or `/var/lib/docker` was touched, and nothing there should be.

No NOPASSWD sudoers rule was added — it would outlive the session for no benefit.
Rootless Podman later removes the need for the socket question entirely.

## Restarting the stacks by hand

```sh
cd ~/infra
bin/compose torrents      up -d
bin/compose ionic-traces  up -d
bin/compose send2ereader  up -d
```

All persistent state is on `/media` bind mounts, so containers are disposable —
gluetun holds no state, and qBittorrent's config lives on `/media/torrents-config`.
Recreating them loses nothing. After a gluetun recreate, expect a **new** forwarded
port; see `docs/port-forwarding.md`.

## Expected listening ports

`8080` (qBittorrent WebUI, via gluetun) · `7777` (ionic-traces web) ·
`3001` (send2ereader) · `8384` and `22000` (syncthing, host network).

```sh
netstat -tln | grep -E '8080|3001|7777|8384|22000'
```
