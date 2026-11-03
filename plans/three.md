# `three` joins the fleet as the off-site mirror

A proposal from the owner's discussions of 2026-11-02 and 2026-11-03, to be carried out at
the November 2026 visit. [`microos-cutover.md`](microos-cutover.md) is how the visit does
it; this file is the end state and why. When the visit has done it, the reasoning moves to
[`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

## The end state

A host's name follows its SD card, the owner's call of 2026-11-03: `one`'s card goes into
the new 8 GB Pi 4, and the 1 GB Pi 4 that runs `one` today becomes `three`.

| Host | Board | Where | Runs |
|---|---|---|---|
| `zero` | Pi 5, 4 GB | UK stack | Immich with machine learning, Syncthing, pearl-wallet |
| `one` | Pi 4, 8 GB | UK stack | the dev hub and every dev container; torrents, calibre-web, send2ereader, garmin-mcp |
| `three` | Pi 4, 1 GB | Argon EON; UK first, Singapore later | the off-site backup; Syncthing for access from Asia |
| `two` | Pi 1 B+ | UK stack | the lifeboat, as roadmap §5 says |

`zero` keeps only the critical services. Today the dev containers share its 4 GB with
Immich's machine learning and fill 41 G of its 64 G Docker partition; on 2026-11-02 it
held 1.1 G in swap. Immich does not move: its library is 104 G of an array with 798 G
free, and moving it is the riskiest migration this fleet could do. `zero` stays on Alpine
this visit; it changes OS only once the new OS is proven on a Pi 5
([`microos-cutover.md`](microos-cutover.md)).

`one` takes the work that needs memory and is not critical. The dev containers want 8 GB
more than a Pi 5's speed. Its apps need no bulk storage, and they stay on its Sabrent and
500 G SSD, which carry their data. `one` keeps its tunnel, credentials and host keys.

`three` is the off-site copy. A backup target needs disks more than memory, and a box that
serves nobody critical loses little by sitting where `two`'s serial console would not
reach. It ships to Singapore after the November visit, at a date the owner picks. It is
the only new host, so it is the one `server-create-host-tunnel.yml` makes a tunnel for.

## The Argon EON

Only the two middle bays take 3.5" drives; the two side bays are 2.5" only. The 12 V 5 A
adapter powers the Pi as well. Two 3.5" drives peak at 3.5 A on 12 V at spin-up.

`three` starts with **one** WD Red Plus 4 TB (the WD49EFZZ, CMR, 5400 rpm, rated 24/7)
bought in the UK, as a single-disk btrfs. A second, bought in Singapore, joins it there,
and the owner converts the array to RAID1 in place, with the box serving throughout:

```
btrfs device add /dev/sdX /media/mirror
btrfs balance start -dconvert=raid1 -mconvert=raid1 /media/mirror
```

Until then the data has one copy on `three`, which is acceptable because `three` holds the
second copy and `zero` the first. Checksums still find corruption, and a monthly scrub
reports it, but only `zero` can repair it. Two drives from two countries are likely from
two batches. The side bays stay free: a 2.5" SSD there could later make a third copy.

The seeded drive is the one at risk in transit. The owner carries it out of the enclosure,
in an anti-static bag with padding, in hand luggage. If it dies anyway, the backup is
re-seeded from `zero` over the internet.

Before trusting a new drive, the owner checks its serial with WD and reads `smartctl -d
sat -i`, `-A` (power-on hours near zero) and `-l scterc`.

## Encryption: LUKS, unlocked by hand

`three` sits where others can reach it, so its array is encrypted with LUKS, using
Adiantum (`xchacha12,aes-adiantum-plain64`), because a Pi 4 has no AES instructions. It is
unlocked by hand after every boot, as roadmap §4 plans for `zero`; no key file is stored,
because a key on the box protects nothing when the box is taken. This fits the fleet's
manual updates: the owner reboots, then unlocks.

- `crypttab` marks the volume `noauto`, so boot never waits for a passphrase on a console
  nobody watches. The data mount is `noauto` as well.
- Every unit that needs the data declares `RequiresMountsFor=` and is `WantedBy=` the
  mount, so it starts the moment the owner unlocks, as the late-disks simulation proved.
- To unlock, the owner runs one documented command over ssh, which starts
  `systemd-cryptsetup@` for the volume (it asks for the passphrase) and then the mount.
- Syncthing's identity (its config and keys) lives inside the encrypted volume. A copy on
  the SD card would let a thief clone `three`'s device ID, and `zero` would send it
  everything.
- `cloudflared`'s credentials and Tailscale's node key stay outside, because they are how
  the owner reaches the box to unlock it. After a theft the owner revokes three things,
  each a minute from the phone: `three`'s device on `zero`'s Syncthing, its node on the
  tailnet, and its Cloudflare tunnel.
- While unlocked and running, the data is readable on the box. Encryption protects it
  powered off and after a reboot, not while it serves.

## Backups: rsync from `zero`, snapshots on `three`

`zero` pushes the backup to `three` with rsync over Tailscale, which both join for it, by
an exception the owner granted on 2026-11-03 to the rule that no box holds a key to
another ([`decisions.md`](../docs/decisions.md)). The key is made nearly powerless:

- A `backup` user on `three` with no shell and no sudo. Its one `authorized_keys` line is
  `restrict,from="<zero's tailnet address>",command="rrsync -wo /media/mirror/incoming"`:
  write-only, one directory, no forwarding, no terminal, only from `zero`.
- `three` takes its own daily snapshots of that directory, as root, read-only. The backup
  user cannot touch them. A compromised `zero` could at worst overwrite the current copy;
  every earlier snapshot survives.
- On `zero` the key is a root-only file used by one nightly cron job (`zero` stays on
  Alpine): `rsync -aHAX --numeric-ids --delete --delete-delay --delay-updates`. Files
  appear in place only at the end of a run, deletions mirror, and the snapshots keep
  history.
- `three`'s snapshot timer skips its turn while the backup user's rsync is running, so no
  snapshot catches half a run.
- Against a locked `three`, a run fails and the next one retries. A check on `zero` tells
  the owner (ntfy) when the last good run is older than a few days, which also covers a
  forgotten unlock.

What is backed up: Immich's `library`, `upload`, `backups` (its nightly database dumps)
and `profile`, about 93 G on 2026-11-02, and `zero`'s Syncthing share, 28 G. Never the
live Postgres directory, which a copy mid-write leaves inconsistent; a restore is the
library plus the latest dump. `thumbs` and `encoded-video` are left out, because Immich
regenerates them.

Push, not pull: pulling would put a key that reads `zero`'s data on the box that sits
unattended in Singapore. Syncthing's encrypted untrusted-device mode was considered and
set aside: still labelled beta, about twenty open issues specific to it, among them a
share that never reaches 100 % after deletes (#8914, open since 2023) and deletes that do
not propagate (#10528).

The owner seeds the first backup over the LAN while `three` is still in the UK, and tests
a restore from a snapshot there.

## Syncthing on `three`, for access from Asia

`three` also runs Syncthing, in a container, for devices in Asia, separate from the
backup. It is deferred if memory proves a problem: Syncthing 2.1.5 to 2.1.7 can run out of
memory on a small box (#10913, open), so `three` pins a 2.0.x release as `one` does today,
with zram swap, and the owner watches its memory during the UK seeding. Its identity lives
inside the encrypted volume, as above.

## The drives

They keep spinning: Syncthing and the backup reach them at random times, and a few dozen
spin-ups a day wear a disk faster than spinning, which NAS drives are rated for. For the
first week the owner reads `Load_Cycle_Count` daily; a count climbing by hundreds a day
means the heads park too eagerly, which wore `zero`'s laptop disks out, and the idle timer
is lengthened while the drives are new. Syncthing's full rescan runs daily, not hourly
(`rescanIntervalS`). The array is scrubbed monthly.

## `zero`'s disk swap

`zero`'s `sdb`, a WD10SPZX, is SMR and the most worn drive on the fleet. On 2026-11-02 it
read 6 reported-uncorrectable reads, 8 command timeouts and 1.22 million load cycles,
about twice its design figure. btrfs's error counters were all zero, and the last scrub,
on 2026-08-03, found no errors. A new WD49EFZZ replaces it in the same Sabrent bay.

`zero` keeps bcache. On 2026-11-02 both devices read `writethrough`, with a hit ratio of
89 and 91 % since boot and 97 % over the last day. Without the cache those reads would go
to two hard disks behind one USB bridge on the critical box. The question is reopened once
the dev hub has left `zero` and its page cache has room.

The swap borrows `one`'s Sabrent for its free bay, so the array keeps both copies while it
copies. `zero`'s two fast ports already hold its Sabrent and the WD Elements disk, so the
borrowed Sabrent goes on a USB 2 port, and 131 G copies at 30 to 40 MB/s, about an hour. A
duty must not cut the slice between steps 4 and 6. The owner:

1. Powers `one` off and takes its SSD out of its Sabrent, so `zero` never sees `one`'s
   filesystem.
2. Connects that Sabrent to a USB 2 port on `zero`, with the new drive in it.
3. Reads the cache set's block size with `bcache-super-show` on the cache partition, runs
   `make-bcache -B` with a matching `--block`, attaches the new device to the cache set,
   and checks `dmesg` for a refused attach before going on.
4. Runs `btrfs replace` from `sdb`'s bcache device to the new one. Immich keeps running.
5. Waits until `btrfs replace status` reads *finished* and `btrfs device usage` shows the
   new device and not the old. **Nothing reboots or shuts down before this.** An
   interrupted replace leaves one full copy, on the worn WD Elements disk, and one
   partial.
6. Sends the new member's UUID to the infra agent, which commits `bcache-register` with it
   in place of `sdb`'s, not beside it. The owner pulls on `zero` and installs it with
   `install-system-file --allow-content-change`. The script names each member by UUID, so
   a reboot before this leaves the array unmountable without `degraded`.
7. Detaches `sdb`'s bcache device, shuts `zero` down, moves the new drive into `sdb`'s
   bay, boots, and runs `check-mount-guards`.
8. Puts `one`'s SSD back in its Sabrent, returns the Sabrent to `one`, and boots `one`, so
   the slice ends with every box serving.
9. Runs `btrfs filesystem resize <devid>:max` on the new member. The array stays at 1 TB
   until the WD Elements disk is replaced as well.
10. Wipes `sdb` on another machine, never `zero`, where its old bcache superblock could be
    registered again. It holds Immich's photos, unencrypted.

## Deferred, each until its trigger

- The WD Elements disk and an enclosure for `zero`'s SSD: when the Elements disk shows
  errors or the array passes about 60 %.
- A cache SSD per hard disk: when the data passes about 200 G and the hit ratio falls.
- An SSD in the Argon's side bay: when SSD prices fall.

## Rejected

- **ZFS**, for being out of tree on MicroOS, slow at encryption on a Pi 4, and not what
  the repo's tools read.
- **bcachefs**, which left the mainline kernel in 6.18.
- **btrfs RAID5**, whose write hole is still open in kernel 7.3.
- **Immich on the Argon, or split across boxes.** Immich's server needs more than 1 GB,
  and a split puts the critical service on three boxes with Postgres on the network.
- **Syncthing's encrypted untrusted device as the backup**, for the reasons in *Backups*.
- **A key file for `three`'s LUKS**, which protects nothing when the whole box is taken.

## Docs this changes

`README.md`'s host tables, the placement table in
[`docs/management-plane.md`](../docs/management-plane.md), roadmap §5 (the boxes no longer
share one stack), `hosts/three/` and `hosts/one/` (the new board), `hardware.md` for
`zero`, `one` and `three`, and `decisions.md` § *SSH between hosts* for the backup key.
