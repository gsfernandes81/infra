# Plan — Docker's storage onto the SSDs

**A proposal, not a decision.** It needs four measurements nobody has taken (§7) and one
decision only the owner can make (§5). Nothing here has been run on any host.

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

This is the part the ask assumed wrong, and it is good news on one host and worse news
on the other.

**`one`: nothing to repartition.** `sda` *is* the 500 G MX500, and `sda1` is already the
btrfs array — `/media/torrents`, `/media/ionic-mysql` and the rest are subvolumes of an
SSD today. A docker directory there is `btrfs subvolume create` plus one `fstab` line.
Space comes out of the shared pool on demand, so "8 G, or more if really needed" is not
a number that has to be committed to in advance, and no partition moves.

The one thing a subvolume does not give you is a **wall**: a runaway build cache or an
unrotated container log can fill the array and take `mysql-ionic` and the torrents down
with it. Two answers, and the cheap one is probably right — cap the logs and prune
(§4), rather than reach for btrfs qgroups, whose cost and bug history are not worth
buying here for one directory.

**`zero`: this is where space genuinely has to be found.** The array is the two 1 T
spinning disks in btrfs RAID1; the SSD is the **bcache cache** in front of them. A
subvolume on the array is an HDD subvolume that happens to be read-cached. Three
candidates for real SSD space, in increasing order of what they cost:

| Candidate | Cost | Note |
|---|---|---|
| **`sda2`, recorded as unused** | none, if it is big enough | `hw-inventory.toml` says `sda2 unused` and nothing says how large. **Measure it first** — if it is ≥64 G this whole section is a non-problem. |
| Shrink swap (`sda3`) | a reboot's worth | `swapoff`, repartition, `mkswap`, new UUID into `fstab`. Easy, but its size is also unrecorded. |
| Shrink the bcache cache (`sda1`) | the array runs uncached for the duration | **bcache cannot shrink a cache device in place.** Detach the cache from both backing devices, repartition, `make-bcache -C` a new one, reattach. Safe *only* while the mode is `writethrough` with 0 dirty — re-check, do not trust the Aug 2026 reading. |

**If it comes to the third, do it once and not twice.** Detach-wipe-remake is precisely
the operation [roadmap §4](../docs/roadmap.md#4-encrypted-data-volume-on-zero) already
requires when the array is encrypted ("Wipe the cache when you encrypt"). Carving the
SSD now and encrypting later means opening the critical box's cache twice.

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

## 4. Sizing

Neither host has been measured, so these are builds of materials, not readings. §7 is
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
faster than one run near the line. If `sda2` turns out to hold 64 G, take all of it.

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

## 5. `zero` only — this weakens the physical-access story, and that is a decision

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

## 6. Two mechanics worth knowing before writing anything

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

## 7. What has to be measured before this is a decision

Four unknowns, all read-only. Per [`CLAUDE.md`](../CLAUDE.md) this is a handover block,
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

`docker system df -v` is the one that settles §4 — it breaks out images, containers,
build cache and every volume by size. Read it, then delete the file: it names containers
and volumes, and this repo does not keep host state lying around.

The four answers wanted: **how big is `zero`'s `sda2`**, **how big is `sda3`**, **what
does `/var/lib/docker` actually weigh on each host**, and **is the bcache still
`writethrough` with 0 dirty**.

## 8. Suggested sequencing

1. Take the measurements. If `zero`'s `sda2` is ≥64 G, §2's hard case disappears.
2. **`one` first** — it is the non-critical box, it needs no repartition, and it is the
   whole procedure end to end on something whose outage is a book arriving later.
   Subvolume → `/media/docker` in `fstab` → `chattr +i` the bare mountpoint → stop
   docker → `rsync -aHAX` → `DOCKER_OPTS` → start → verify by **container ID**, not by
   "is it running".
3. **Decide §5 for `zero`** before anything is carved. If option 3, the model-cache and
   dev-cache move is small and can happen immediately.
4. **`zero`'s data-root** goes with roadmap §4, or on its own if §5 resolves to 1.
