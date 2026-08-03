# Recovery — host `one`

For the case that matters: you're remote, on a ship link, and `one` rebooted.

## Bring the stacks back

```sh
cd ~/infra
bin/compose torrents      up -d
bin/compose ionic-traces  up -d
bin/compose send2ereader  up -d
netstat -tln | grep -E '8080|3001|7777|8384|22000'
```

All state is on `/media` bind mounts, so containers are disposable — recreating loses
nothing. After a gluetun recreate expect a **new** forwarded port; see
[port-forwarding.md](port-forwarding.md).

## Don't break remote access

`cloudflared` runs from `/etc/init.d/cloudflared` (OpenRC), **with the tunnel token in
plaintext** in that world-readable file. It's your way back in. Leave it alone
remotely.

When you're physically present: move the token to `/etc/conf.d/cloudflared` (mode
600), source it from the init script, then rotate it — the old value has been readable
by any local user for a long time.

## Why a missing USB disk doesn't stop boot — *today*

All four `/media/*` mounts are on `/dev/sdb1` and none carry `nofail`. On Alpine +
OpenRC that's survivable: `critical_mounts` is empty in `/etc/conf.d/localmount` so
`localmount` forces `rc=0`, and all four are passno 0 so fsck never touches them. Only
`/` and `/boot` are fsck'd, both on the SD card.

**This protection is an OpenRC property and vanishes on systemd.** There, an entry
without `nofail` becomes a `local-fs.target` dependency: a missing or slow USB disk
stalls boot ~90 s, then drops to emergency mode — no network, no SSH, and you're not
in the building.

Before the first reboot on any systemd distro, every `/media/*` entry needs:

```
nofail,x-systemd.device-timeout=10
```

`/etc/fstab` is tracked read-only at `hosts/one/system/fstab`. This repo documents it;
it does not control it.

## The trap that silently eats data

If a volume fails to mount, a container bind-mounting that path **starts against an
empty directory and writes into it.** On `zero` that means Immich coming up with a
blank library.

Guard every such unit:

```
RequiresMountsFor=/media/torrents
```

`Wants=` is **not** enough — it's advisory, so the container starts anyway. Use
`RequiresMountsFor=`, or `Requires=` + `After=`.

## Name mounts by filesystem UUID — never `by-id`

The Sabrent dual-bay USB enclosure reports an **identical serial (all zeros) and WWN
for both drives**, so `/dev/disk/by-id/` names collide. On `one` they already resolve
wrongly: the base link points at `sda` while its `-part1`/`-part2` links point into
`sdb` — a different disk. `sda`/`sdb` can also swap across reboots.

The usual advice is "use `by-id` instead of `/dev/sdX` for stability". **Here that
advice is actively wrong.** Use filesystem UUIDs, which are stored inside the
filesystem: `/etc/fstab` already does, and systemd `.mount` units must too
(`What=/dev/disk/by-uuid/adc3a286-…`).

A mount unit pointing at the wrong disk drops you straight into the trap above.

## Privileges

`gavin` is in `wheel` (sudo needs a password) and deliberately **not** in `docker` —
that group is root-equivalent, since anyone in it can bind-mount `/` into a container.
The group exists and is empty. Rootless Podman later removes the question.

The whole Phase 2 restructure needed exactly one privileged command:
`sudo chown -R gavin:gavin ~/docker-compose`. Never chown anything under `/media` or
`/var/lib/docker`.

**Don't touch:** `/boot`, kernel, bootloader, `/etc/fstab`, `/etc/init.d/cloudflared`,
any bind-mount source under `/media/`.
