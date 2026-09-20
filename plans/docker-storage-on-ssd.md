# Plan — Docker's storage onto the SSDs

**A proposal, not a decision.** It needs three measurements nobody has taken (§8) and one
decision only the owner can make (§6). Nothing here has been run on any host.

## 1. The ask, and what it turns out to be

*"Move our docker volume driver to use our SSD."* Two things make that not quite the
question:

- **There is only one volume driver.** `local` is what every stack here uses and the
  third-party drivers solve a problem this fleet does not have. So "change the driver"
  means, in practice, one of the four relocations in §3 — nothing gets swapped out.
- **`one` has no named volumes at all.** `docs/fleet-inventory.md` reports `None`, and
  every stack on it binds to `/media/*` instead. Moving "the volumes" on `one` moves
  zero bytes. What is actually on `one`'s SD card is the rest of the data-root — images,
  container writable layers, build cache, container logs — and that is the thing worth
  moving.

So the real subject is **`/var/lib/docker`**, not `/var/lib/docker/volumes`. On `zero`
the volumes are a real share of it (21 of them, mostly the dev containers'); on `one`
they are none of it.

## 2. Where the bytes would come from — and `one` needs no resize

This is the part the ask assumed wrong, and it turns out to be good news on both hosts.

**`one`: nothing to repartition.** `sda` *is* the 500 G MX500, and `sda1` is already the
btrfs array — `/media/torrents`, `/media/ionic-mysql` and the rest are subvolumes of an
SSD today. A docker directory there is `btrfs subvolume create` plus one `fstab` line.
Space comes out of the shared pool on demand, so "8 G, or more if really needed" is not
a number that has to be committed to in advance, and no partition moves.

The one thing a subvolume does not give you is a **wall**: a runaway build cache or an
unrotated container log can fill the array and take `mysql-ionic` and the torrents down
with it. Two answers, and the cheap one is probably right — cap the logs and prune
(§5), rather than reach for btrfs qgroups, whose cost and bug history are not worth
buying here for one directory.

**`zero`: `sda2` answers it — 64 G, free, and usable whole.** Owner-confirmed
2026-09-20; `hw-inventory.toml` had recorded it only as *unused*. That closes the space
question in the best way available: **nothing is repartitioned, the bcache cache is
never detached, and the array never runs uncached.** Take the partition whole — 64 G is
also the right size on its own merits (§5), so there is nothing to trade off.

**It becomes one btrfs filesystem carrying two subvolumes**, `docker` and
`container-tmp` (§4), which is what makes the arrangement identical on both hosts:
`one` gets the same two subvolumes out of the array it already has. A plain partition
with one filesystem per purpose would have been simpler to reason about and gives up
exactly the thing that makes `one` free — subvolumes sharing a pool on demand instead
of two sizes guessed in advance.

The two alternatives are recorded because they were genuinely on the table and because
one of them still matters later:

| Alternative | Why not now | Worth keeping in mind |
|---|---|---|
| Shrink swap (`sda3`) | unnecessary — `sda2` is enough | Its size is still unrecorded. Irrelevant unless something else later wants SSD space. |
| Shrink the bcache cache (`sda1`) | unnecessary, and the most expensive option on the critical box | **bcache cannot shrink a cache device in place.** It means detaching the cache from both backing devices, repartitioning, `make-bcache -C`, reattaching — with the array uncached throughout — and it is safe only while the mode is `writethrough` with 0 dirty. This is the same operation [roadmap §4](../docs/roadmap.md#4-encrypted-data-volume-on-zero) already requires when the array is encrypted, so if it ever happens it should happen **once**, not twice. |

## 3. The four relocations

**A. Move the whole data-root.** `/var/lib/docker` → the SSD, via `DOCKER_OPTS` in
`/etc/conf.d/docker`. Everything moves: images, layers, volumes, build cache, logs.
Biggest win for SD wear and SD space, one setting, nothing per-stack. Blast radius is
the whole daemon — a wrong path means a daemon with no containers, which is a fleet
outage but a *loud* one. **Recommended for both hosts.**

**B. Bind-mount `/var/lib/docker/volumes` alone.** Narrower, keeps images on the card.
Works only because the path is an ordinary directory — Docker does not support it and
will not tell you when it breaks. Leaves the largest consumer (images and build cache)
on the SD. **Not recommended:** it takes the same risk as A for a fraction of the gain.

**C. Per-volume, in the compose file:**

```yaml
volumes:
  model-cache:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DOCKER_VOL_ROOT:?set DOCKER_VOL_ROOT in .env}/immich-model-cache
```

The most literal reading of "change the volume driver", and the one that fits this repo
best: it is declarative, it lives in the stack, and the host-specific path goes to the
gitignored `.env` under the existing `:?` rule rather than into `compose.yaml`. It also
**fails closed** — a `bind` whose `device` does not exist is a mount error and the
container does not start, where a plain bind mount would have Docker create the
directory for you.

Its limit is scope: on `zero` it reaches 21 volumes across four compose projects (three
of them dev containers outside `deployments/`), and it reaches none of the images. Use
it to move *specific* volumes, not as the migration.

**D. Abolish the named volumes and bind to `/media/...`** — what `one` already does
everywhere. Most explicit, nothing to migrate later, and it is the pattern the fleet
already reads as normal. Worth doing for `immich_model-cache` on its own merits
whichever of the above is chosen.

## 4. The containers' `/tmp` — a subvolume on the SSD

**`/tmp` on the hosts is already `tmpfs`** — line 10 of each tracked `fstab`,
`nosuid,nodev`. RAM, never the SD card, and it stays exactly as it is. It is not the
subject here.

**⚠︎ That was offered as the whole answer on 2026-09-20 and it was half of one.** The
hosts' `/tmp` is tmpfs. **The containers' `/tmp` was not.** A container with no mount
at `/tmp` takes it from the writable overlay layer, which lives under
`/var/lib/docker` — on `zero`, the SD card. So every claude scratchpad, every npm and
`uv` extraction and every build temp file inside the dev containers has been an SD
write, and *"the host's `/tmp` is fine"* is precisely what hid it. It is wrong
independently of the disk, too: scratch in the writable layer costs an overlayfs
copy-up, counts as container size, and is reclaimed only on **recreate**, so a restart
inherits yesterday's `/tmp`.

### tmpfs was the first fix, and it is rejected

Not merely a preference. `/tmp` in these containers can legitimately be large — an
extraction, a build tree, a claude working set — and **tmpfs pages are charged to the
container's memory cgroup**. `infra-dev` is capped at `mem_limit: 1024m`, so a tmpfs
`/tmp` converts "this needs a few GB of scratch" into an OOM kill that reports a dead
process rather than a full disk. Sizing it small enough to be safe (256 M) is sizing it
too small to be useful, and sizing it usefully large is a loaded gun on a 4 GB Pi that
also runs Immich. Disk is the right medium for a scratch area whose size is not known
in advance; the SSD is what makes it cheap.

### The conflict this has to resolve first: on `zero`, the btrfs array is not the SSD

"A subvolume on the existing btrfs filesystem" means different hardware on each host,
and on the critical one it means the wrong hardware:

- **`one`** — `sda1` **is** the MX500. Its btrfs filesystem is already on the SSD, so a
  subvolume there is exactly what was asked for.
- **`zero`** — the btrfs filesystem lives on `/dev/bcache0` + `/dev/bcache1`, i.e. the
  two 1 T **spinning disks**. The SSD is the bcache *cache* in front of them. A
  subvolume there is an HDD subvolume, and for `/tmp` that is the worst case for
  bcache: writethrough means every scratch write lands on the platter at platter speed,
  while the cache fills with blocks that are about to be deleted.

**The resolution keeps the uniformity and fixes the device: make `sda2` a btrfs
filesystem and give it both subvolumes.** Then each host has one btrfs filesystem on an
SSD carrying a `docker` subvolume and a `container-tmp` subvolume, mounted under
`/media/` like every other data mount on this fleet — same filesystem type, same
subvolume idiom, same `fstab` shape, same guard coverage. The only difference left is
which pool they come out of, and that difference is real (below).

| | `zero` | `one` |
|---|---|---|
| Filesystem | **new** btrfs on `sda2` — 64 G, SSD, currently free | **existing** btrfs on `sda1` — the array, already SSD |
| Docker data-root | `/media/docker` | `/media/docker` |
| Container scratch | `/media/container-tmp` | `/media/container-tmp` |
| Per container | `/media/container-tmp/<container>` | same |
| Pool shared with | the data-root only | the data-root **and** `/media/torrents`, `/media/ionic-mysql` | 

On `one` that shared pool is where the **wall** question from §2 returns, and `/tmp` is
the likeliest thing to run away. A btrfs qgroup on the `container-tmp` subvolume alone
is a narrower use of quotas than capping the whole docker tree and is worth it there;
on `zero`'s dedicated 64 G pool the worst case is docker and scratch starving each
other, which is loud and local.

One consequence to record for `zero`: `sda2` is on the **same physical disk** as the
bcache cache. Losing `sda` takes the cache, the data-root and every container's scratch
at once. The array itself survives — writethrough, 0 dirty — so that is a stack that
comes back down rather than data loss, and `nofail` keeps it from being a boot failure.

### Four things that make or break it

1. **`create_host_path: false`, and the source pre-created.** The dev containers run as
   `dev`, not root. If Docker is allowed to invent a missing bind source it creates it
   root-owned `0755`, and the container comes up with a `/tmp` it cannot write —
   failing everything downstream with errors that never mention `/tmp`. Refusing to
   start is the better outcome. The directory must exist, be owned by the uid the
   container runs as, and be mode `1777`, before `make up`.
2. **One directory per container, never one shared.** All four dev containers run at
   the same uid, so a shared `/tmp` gives four claudes the same scratch with no
   isolation and no way to tell whose leftovers are whose.
3. **It persists, and `/tmp` must not.** This is the one thing tmpfs gave for free.
   A disk-backed `/tmp` survives `make up` and reboots and grows forever. The right
   place to empty it is the base image's `entrypoint.sh`, which all four containers
   share and which already runs as `dev` — the owner of everything in its own `/tmp` —
   at exactly the moment "the container just started" is true. **That is a base-image
   change: `make base` and a `BASE_TAG` bump, so it is deliberately not bundled into
   the compose change.** Doing it in `dev/Makefile` instead was considered and
   rejected: it would put `btrfs subvolume` commands in the one interface that is
   supposed to work the same on any host.
4. **`chattr +C` (nodatacow) on the scratch subvolume, while it is empty.** Scratch
   wants neither COW nor checksums; both cost fragmentation and write amplification on
   an SSD for files that are written once and deleted. It only takes effect if set
   before anything is written, which means at creation time or not at all.

### `/` stays on the SD card

Not inertia. `bin/check-boot-layout` passes today for exactly one reason: `/` and
`/boot` are on the same physical device, so pulling it halts the machine and tampering
costs a reboot you would notice. Move root to the SSD and leave `/boot` on the card —
what a half-migration looks like — and the check returns `*** GAP ***` and exits 1,
correctly. Its own preferred fix is *"boot entirely from the SSD and remove the SD
card"*, which the Pi 5 can do, and which is a different project with its own recovery
story.

`/var/log` stays too — the SD writer left standing once docker moves, `cloudflared`
through `log_proxy` on both hosts. Small, rotated, and recorded so it does not read
later as an oversight.

### This is not only the dev containers

Every container on both hosts has `/tmp` in its writable layer, not just the four with
a claude in them — `immich_server`, `mysql-ionic`, `torrent`, `send2ereader` and the
rest are all writing scratch to an SD card today. The mechanism above is the same for
all of them: a directory under `/media/container-tmp/<container>` and one bind mount in
the stack's compose file. It is filed as a sweep in §9 rather than done here, because
each one means recreating a running container and two of them are on the critical box.

## 5. Sizing

Neither host has been measured, so these are builds of materials, not readings. §8 is
how to replace them with facts.

**`zero` — order 15–20 G in use.** Immich server and machine-learning are the weight
(~1.5 G each on arm64), plus postgres-vectorchord, valkey, syncthing and `mysql:8`
(~1.2 G together), the `gsrpi-dev-base` family across four dev containers (~3–5 G, the
shared base is what keeps that number down), the volumes themselves (`model-cache` plus
the `uv-cache`/`zed-server`/`local-share` set — phase 2d already found a single one
holding 1,146 MB), and build cache.

**64 G is the right number, and it should not be trimmed to fit.** Three times the
working set is not extravagance on a data-root: build cache and dangling layers
accumulate between prunes, and an SSD kept under half full wears better and writes
faster than one run near the line. `sda2` holds exactly that, so take it whole.

**`one` — order 4–6 G in use, spiking during builds.** `mysql:8`, gluetun,
linuxserver/qbittorrent and syncthing are ~1 G together; `send2ereader`, `ionic-bot` and
`ionic-web` are all built on the box, so buildkit's cache is a first-class consumer here
in a way it is not on `zero`.

**8 G works and 16 G is comfortable — and since it is a subvolume, this is not a number
you have to get right.** A `docker build` on a box already holding 5 G of images will
walk into 8 G, and the failure mode is a build that dies mid-layer. Take 16 G of the
pool. If it is ever wrong it is one `fstab` line and no repartition to change.

**Cap the logs in the same change, on both hosts.** The `json-file` driver is unbounded
by default, and a chatty container is the one thing that can make any of these numbers
meaningless. `log-driver`/`log-opts` with `max-size` and `max-file`, set daemon-wide
alongside the data-root.

## 6. `zero` only — this weakens the physical-access story, and that is a decision

`bin/check-boot-layout` exists on the argument that **every persistent device on `zero`
is in active use, so pulling one halts the machine and a reboot is detectable**. The SD
card is inside the Pi. The SSD is in a USB enclosure on the desk.

Moving the data-root to a plain partition on that SSD puts, on a device someone can walk
off with while the box keeps running:

- `*_dd-gh`, `*_ds-gh`, `*_or3-gh` — GitHub auth
- `*_dd-claude`, `*_ds-claude`, `*_or3-claude` — Claude credentials
- `*_dd-ssh-host`, `*_ds-ssh-host`, `*_or3-ssh-host` — dev container host keys
- `destiny-director_dd-postgres-data`, `dd-mysql-data`
- and `containers/<id>/config.v2.json`, which
  [`management-plane.md`](../docs/management-plane.md) already records as holding
  secrets from the environment

Against a threat model whose stated premise is *"someone may have unsupervised physical
access to the stack for weeks while you are away"*, that is a real regression, and it is
one the current arrangement does not have.

**Three ways out, and the third is the recommendation:**

1. **Accept it.** Defensible only if the dev-container credentials are considered
   low-value and rotatable. They reach GitHub and this repo, so they are not.
2. **LUKS the docker partition too.** Correct, and it drags the boot path in with it:
   an unlock that is manual by design means docker must not start before it, which on
   OpenRC means taking docker off the default runlevel or writing a guard service — and
   [`CLAUDE.md`](../CLAUDE.md) records that an OpenRC mount-guard service was tried and
   **rejected**, for reasons that all apply again here.
3. **Move the harmless things now, sequence the rest with roadmap §4.** `immich_model-cache`
   is public model weights; the dev containers' `uv-cache` and `zed-server` are package
   and binary caches. Those are the write-heavy ones and none of them is a secret. Move
   them with option C onto a subvolume of the **array** — bcache read-caches them for
   free, they inherit the future LUKS automatically, and no partition is touched. Then
   move the full data-root when the SSD is opened for encryption anyway.

`one` has none of this problem: no credentials in volumes, no encryption plan, and its
SSD is already the array.

## 7. Two mechanics worth knowing before writing anything

**Mount the SSD at `/media/docker` and the guard is free.** `bin/check-mount-guards`
discovers its targets by reading `fstab` for `/media/*` entries that are not `noauto` —
so a new mount there is covered by the existing tooling with no code change, and
`chattr +i` on the bare mountpoint makes the failure mode *dockerd refuses to start*
rather than *dockerd populates an empty directory*. Mounting at `/var/lib/docker`
directly would work and would be invisible to every check this repo owns.

**`daemon.json` cannot carry an `infra-` header.** Docker's JSON parser rejects
comments, and the header is a comment — so a tracked `daemon.json` breaks
`check-system-drift` and `install-system-file` on day one. **`/etc/conf.d/docker` is the
Alpine-correct place** and it is shell, so it carries the header normally and is tracked
like `cloudflared` already is. Put `--data-root` and the log options in `DOCKER_OPTS`
there.

**This is Alpine-era work.** Under MicroOS the same setting is podman's `graphroot` in
`storage.conf`, so whatever is built here is replaced rather than carried over. That is
an argument for the smallest change that works, not for waiting.

## 8. What has to be measured before this is a decision

Three unknowns, all read-only. Per [`CLAUDE.md`](../CLAUDE.md) this is a handover block,
not something an agent session runs: `ssh zero` first, then paste inside that shell.

```sh
sudo sh -c 'exec > /root/docker-sizing.txt 2>&1
  lsblk -b -o NAME,SIZE,FSTYPE,MOUNTPOINT
  sfdisk -l /dev/sda
  df -h /
  du -sh /var/lib/docker
  du -sh /var/lib/docker/*
  docker system df -v
  btrfs filesystem usage /media/immich-data   # zero only
  cat /sys/block/bcache0/bcache/cache_mode    # zero only
  cat /sys/block/bcache1/bcache/cache_mode    # zero only
'
sudo chmod 600 /root/docker-sizing.txt
```

`docker system df -v` is the one that settles §5 — it breaks out images, containers,
build cache and every volume by size. Read it, then delete the file: it names containers
and volumes, and this repo does not keep host state lying around.

`zero`'s `sda2` is no longer among the unknowns — it is 64 G and free, confirmed by the
owner on 2026-09-20. What is left: **what does `/var/lib/docker` actually weigh on each
host**, **how much free space is in `one`'s array**, and — not needed for this work, but
cheap to read while you are in there and load-bearing for
[roadmap §4](../docs/roadmap.md#4-encrypted-data-volume-on-zero) — **is the bcache still
`writethrough` with 0 dirty**.

## 9. Suggested sequencing

1. Take the remaining measurements (§8). `zero`'s `sda2` is already settled at 64 G, so
   what is left is only sizing confirmation, not a go/no-go.
2. **`one` first** — it is the non-critical box, it needs no repartition, and it is the
   whole procedure end to end on something whose outage is a book arriving later.
   Subvolume → `/media/docker` in `fstab` → `chattr +i` the bare mountpoint → stop
   docker → `rsync -aHAX` → `DOCKER_OPTS` → start → verify by **container ID**, not by
   "is it running".
3. **Decide §6 for `zero`** before anything is carved. If option 3, the model-cache and
   dev-cache move is small and can happen immediately.
4. **`zero`'s data-root** goes with roadmap §4, or on its own if §6 resolves to 1.

**The `/tmp` work (§4) rides along rather than queueing behind this.** Its subvolume
comes out of the same filesystem and the same `fstab` sitting, so it costs one extra
`btrfs subvolume create` at step 2 and step 4 — but the compose side is already written
for `infra-dev` and refuses to start until `DEV_TMP_DIR` names a real directory, which
is deliberate: it cannot half-land.

Three follow-ups it leaves, in order of how much they matter:

- **Emptying it on start** (§4, item 3) — the base image's `entrypoint.sh`, needing
  `make base` and a `BASE_TAG` bump. Until it lands the scratch directories are swept
  by hand, and that is the one respect in which this is worse than the tmpfs it
  replaced. Worth pairing with the `/etc/dev-base-version` marker the phase table has
  wanted since 2d, since it is the same rebuild.
- **`or3-dev`, `dd-dev`, `ds-dev`** — the same two lines, each in its own repo. Same
  rule as the `.bak-token` sweep: *when a finding is about a class of thing, fix every
  one of them.* `dd-dev` and `ds-dev` are down today, so the change costs nothing to
  make now and applies whenever they next come up.
- **Every other container on both hosts** (§4, last part). Immich and `mysql-ionic` are
  the ones that need a recreate on a box that matters, so this waits for a sitting
  where that is already happening.
