# Recovery

For the case that matters: you're remote, on a ship link, and a box rebooted.

## First, on either host

```sh
sudo bin/check-mount-guards      # zero only — are the data guards still intact?
```

## Bring the stacks back

`one`:

```sh
cd ~/infra
bin/compose torrents      up -d
bin/compose ionic-traces  up -d
bin/compose send2ereader  up -d
netstat -tln | grep -E '8080|3001|7777|8384|22000'
```

`zero`:

```sh
cd ~/infra
bin/compose immich    up -d
bin/compose syncthing up -d
netstat -tln | grep -E '2283|8384|22000|2222'
```

On `one`, all state is on `/media` bind mounts, so containers are disposable —
recreating loses nothing. After a gluetun recreate expect a **new** forwarded port; see
[port-forwarding.md](port-forwarding.md).

On `zero` that is **not** true of the database. `immich_postgres` keeps its cluster on
`/media/immich-db`. Recreating the container is fine; losing or shadowing that mount is
not. Immich writes its own nightly `pg_dump` to `/media/immich-data/backups/` — those
live on the same array as the data they protect, so they cover logical corruption and
not array loss. Take one off-array before anything invasive.

The two Claude dev containers on `zero` (`dd-dev`, `dd-mysql`) are **`restart=no`** and
do not come back on their own. That is deliberate — they hold live sessions and
uncommitted worktrees. Start them with `make dev` from `~/destiny-director`, never
casually.

---

## ⚠ The trap that silently eats data — and the flag that stops it

If a volume fails to mount, a container bind-mounting that path **starts against an
empty directory and writes into it.** On `zero` that means Immich coming up with a blank
library, and Postgres running `initdb` over nothing. Nothing about the container's
configuration prevents this: `/etc/init.d/docker` declares only
`need sysfs cgroups net` — it has no dependency on the mounts existing.

Two things stop it, and `bin/check-mount-guards` verifies both:

1. **`nofail`** on every `/media/*` fstab entry, so a missing array can never stall boot.
2. **`chattr +i` on the bare mountpoints** — the directories on the root filesystem
   *underneath* the btrfs mounts. While the array is mounted the flag is shadowed and
   irrelevant. If the array fails to mount, every write to that path returns **EPERM,
   even as root**, so the corruption cannot happen. The failure becomes loud instead of
   silent.

### The thing that will confuse you at 2am

**You will one day get `Permission denied` as root on `/media/immich-data`,
`/media/immich-db` or `/media/syncthing`, and it will make no sense.** `ls -ld` shows
a normal directory, you are root, and the write still fails.

That is this guard working as designed, on an unmounted mountpoint. To do legitimate
work on a bare mountpoint:

```sh
sudo umount /media/immich-data
sudo chattr -i /media/immich-data      # <-- the bit you will forget
#   ... do the work ...
sudo chattr +i /media/immich-data      # <-- put it BACK
sudo mount /media/immich-data
sudo bin/check-mount-guards            # prove you put it back
```

`lsattr -d` on a **mounted** path answers a different question — it reports the mounted
btrfs root, not the directory underneath. `bin/check-mount-guards` bind-mounts `/` to
see the real thing, and attempts an actual write rather than trusting the flag.

### Why not an OpenRC guard service

An earlier design used a service that checked the mounts and refused to start Docker.
It was dropped: it put new code on the boot path, created a fresh way for the box to
come up with no containers, and had a false-failure mode — renaming a Syncthing share
would have silently stopped Docker on the next reboot. `chattr +i` makes the bad write
**impossible** rather than **detected**, with no moving parts. On MicroOS this is
replaced by `RequiresMountsFor=`.

---

## Why a missing USB disk doesn't stop boot

**`one`:** all four `/media/*` mounts are on `/dev/sdb1`. They now carry `nofail`, and
all four bare mountpoints are `chattr +i` (Aug 2026) — all four were confirmed empty
first, so the trap had never fired here. Independently of that, OpenRC would have
survived a missing array anyway: `critical_mounts` is empty in `/etc/conf.d/localmount`
so `localmount` forces `rc=0`, and all four are passno 0 so fsck never touches them.
Only `/` and `/boot` are fsck'd, both on the SD card. The guards matter for the
systemd migration, and for the `restart: always` containers that would otherwise
populate an empty mountpoint today.

**`two`:** diskless, running from RAM with the SD card read-only. It has no `/media/*`
data mounts to guard, so `nofail` and `chattr +i` do not apply — but check rather than
assume, since the fix is only meaningful where a container bind-mounts a path that
could fail to mount.

**Per-host status, at a glance:**

| | `nofail` | `chattr +i` | token moved out of the init script |
|---|---|---|---|
| `zero` | ✅ Aug 2026 | ✅ Aug 2026 | ✅ Aug 2026 — **not rotated** |
| `one` | ✅ Aug 2026 | ✅ Aug 2026 | ✅ Aug 2026 — **not rotated** |
| `two` | n/a (diskless) | n/a | check |

**Neither token has been rotated.** Both were world-readable in a 755 init script for
months, so both must be assumed disclosed — anyone who copied one can still run a
connector for that tunnel. Moving them shrank future exposure and did nothing about
past exposure. Regenerate both in the Zero Trust dashboard when physically present.

**`zero`:** all three `/media/*` entries now carry `nofail`. Its array is btrfs **RAID1
across two bcache devices**, so *both* must assemble before it can mount read-write —
btrfs refuses a degraded RAID1 mount unless you pass `degraded`. `/etc/init.d/bcache-register`
registers them and then **waits, bounded to 30s**, for `/dev/bcache0` and `/dev/bcache1`
to appear. It always exits 0: a failure there must never stop the boot, because the
mountpoints are immutable and nothing can be corrupted by the mounts being absent.

**This protection is an OpenRC property and vanishes on systemd.** There, an entry
without `nofail` becomes a `local-fs.target` dependency: a missing or slow disk stalls
boot ~90s, then drops to emergency mode — no network, no SSH, and you're not in the
building.

Before the first reboot on any systemd distro, every `/media/*` entry needs:

```
nofail,x-systemd.device-timeout=10
```

and every unit touching those paths needs:

```
RequiresMountsFor=/media/immich-data
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

`zero`'s `/etc/init.d/bcache-register` is consistent with this: it registers by
`/dev/disk/by-uuid/`, which is the bcache superblock UUID, not a `by-id` name.

`/etc/fstab` is tracked read-only under `hosts/<host>/system/`. This repo documents it;
it does not control it.

---

## Don't break remote access

Both hosts run `cloudflared` from `/etc/init.d/cloudflared`. It's your way back in.

**`zero` — token moved, NOT yet rotated (Aug 2026).** The token now lives in
`/etc/conf.d/cloudflared` at mode 600, sourced automatically by OpenRC; the init script
references `${CF_TUNNEL_TOKEN}` and is tracked under `hosts/zero/system/`. **The old
value was world-readable for months and must be assumed disclosed** — anyone who copied
it can still run a connector for this tunnel until it is regenerated in the Zero Trust
dashboard. Moving it shrank future exposure; it did not undo past exposure. Rotate when
physically present.

**`one` — same, done Aug 2026, also NOT rotated.** Identical layout to `zero`, tracked
under `hosts/one/system/`. The move was proven inert before restarting: the new config
was sourced, `command_args` expanded, and its SHA-256 compared against the running
command line — identical, so the daemon restarted with a byte-identical invocation. It
recovered in 5s and the `connectorId` changed, which is what proves it actually
re-registered rather than never having restarted.

The probe that watched it was `http://127.0.0.1:20241/ready` (HTTP 200,
`readyConnections >= 1`), chosen because it read healthy against the *working* tunnel.
Port-7844 socket counts and the log file were both tried and rejected: on `one` they
read dead while the tunnel was serving normally, and either would have rolled back a
good change.

**`two` — check before assuming.** If the token is still inline in the world-readable
init script, the same fix applies: move it to `/etc/conf.d/cloudflared` (mode 600),
reference `${CF_TUNNEL_TOKEN}`, verify, then rotate. Confirm with:

```sh
grep -c 'eyJ' /etc/init.d/cloudflared      # 0 = already moved
ls -l /etc/conf.d/cloudflared              # expect 600 root:root
```

The step-by-step method — the two-phase split, the hash comparison that proves the new
command line is byte-identical before anything restarts, and the rollback design — is
in [`../CLAUDE.md`](../CLAUDE.md#changing-the-thing-you-are-connected-through).

Doing this remotely is safe if — and only if — you are **not connected through the
tunnel you are restarting**. On `zero` that meant the bastion (`ssh zero-two` via `two`)
plus a `screen` session that survives its own SSH dying. Verify the health probe reads
healthy against the *working* tunnel before trusting it as a verdict: counting sockets
on port 7844 reads 0 here even while the tunnel serves, so a socket-based check would
roll back a good change. Probe a public hostname end-to-end instead.

On `zero` there is a second way in: **SSH from `one` over the LAN.** That is the reason
every change on `zero` is designed to fail *degraded* — box up, network up, sshd up —
rather than unbootable.

## Privileges

`gavin` is in `wheel` (sudo needs a password) and deliberately **not** in `docker` —
that group is root-equivalent, since anyone in it can bind-mount `/` into a container.
The group exists and is empty. Rootless Podman later removes the question.

**Don't touch:** `/boot`, kernel, bootloader, `/etc/init.d/cloudflared`, any bind-mount
source under `/media/`. `/etc/fstab` is editable but only ever by hand, never generated.

**Never `apk del containerd` on `zero`.** `docker-engine` hard-depends on that package —
`/usr/bin/containerd` and `/usr/bin/containerd-shim-runc-v2` are the binaries dockerd's
own containerd and every running shim exec from. Removing it kills every container at
the next start or boot, and the dev containers are `restart=no`. The standalone
`containerd` *service* is unused and was removed from the runlevel; the *package* must
stay.
