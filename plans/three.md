# `three` joins the fleet, and `one` becomes the off-site mirror

A proposal from the owner's discussion of 2026-11-02, to be carried out at the November
2026 visit. [`microos-cutover.md`](microos-cutover.md) is how the visit does it; this file
is the end state and why. When the visit has done it, the reasoning moves to
[`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

## The end state

| Host | Board | Where | Runs |
|---|---|---|---|
| `zero` | Pi 5, 4 GB | UK stack | Immich with machine learning, Syncthing, pearl-wallet |
| `three` | Pi 4, 8 GB | UK stack, where `two`'s serial console would reach | the dev hub and every dev container; torrents, calibre-web, send2ereader, garmin-mcp |
| `one` | Pi 4, 1 GB | Argon EON; UK first, Singapore later | the off-site mirror, nothing else |
| `two` | Pi 1 B+ | UK stack | the lifeboat, as roadmap §5 says |

`zero` keeps only the critical services. Today the dev containers share its 4 GB with
Immich's machine learning and fill 41 G of its 64 G Docker partition; on 2026-11-02 it
held 1.1 G in swap. Immich does not move: its library is 104 G of an array with 798 G
free, and moving it is the riskiest migration this fleet could do.

`three` takes the work that needs memory and is not critical. The dev containers want 8 GB
more than a Pi 5's speed. `one`'s apps need no bulk storage, so they move with `one`'s
Sabrent and its 500 G SSD, which carries their data.

`one` is the off-site copy. A mirror needs disks more than memory, and a box that serves
nobody loses little by sitting where `two`'s serial console would not reach. Whether 1 GB
holds Syncthing's index for about 100,000 Immich files is untested; the seeding in the UK
is where the owner finds out. `one` ships to Singapore after the November visit, at a date
the owner picks.

## The Argon EON

Only the two middle bays take 3.5" drives; the two side bays are 2.5" only. The 12 V 5 A
adapter powers the Pi as well. Two 3.5" drives peak at 3.5 A on 12 V at spin-up.

| Bay | Drive | Role |
|---|---|---|
| middle | WD49EFZZ, 4 TB | btrfs RAID1 |
| middle | WD49EFZZ, 4 TB | btrfs RAID1 |
| side | empty | a 2.5" SSD later as a third copy (RAID1C3), which caps the array at the SSD's size |
| side | empty | kept free, so a replacement can be slid in without pulling the dead drive |

The WD49EFZZ is an Amazon-only WD Red Plus 4 TB: CMR, 5400 rpm, rated 24/7. Before
trusting one, the owner checks its serial with WD and reads `smartctl -d sat -i`, `-A` and
`-l scterc`.

## What the mirror carries

Syncthing carries the copy, because the alternative breaks a rule. `btrfs send` needs one
box to ssh into the other, and no box on this fleet holds a key to another
([`decisions.md`](../docs/decisions.md) § *SSH between hosts*). Syncthing pairs devices by
ID and gives neither a shell. Each folder is **send-only** on `zero` and **receive-only**
on `one`, so a change on either side cannot flow back into Immich's library.

- Immich's `library`, `upload`, `backups` and `profile`, about 93 G on 2026-11-02.
  `backups` holds Immich's nightly database dumps, so a restore is the library plus the
  latest dump. `profile` holds users' pictures, which Immich cannot regenerate. `thumbs`
  and `encoded-video` are ignored, because Immich regenerates them.
- `zero`'s Syncthing share, 28 G.
- Never the live Postgres directory, because a copy taken mid-write is inconsistent.

`zero`'s Syncthing reaches Immich's folders only through new bind mounts in
`deployments/syncthing/compose.yaml`, which today mounts `/media/syncthing` alone. The
mounts cannot be read-only: Syncthing writes a `.stfolder` marker into each folder's root
and will not start a folder without one. So the Syncthing container gains write access to
Immich's library on `zero`, and the send-only folder type is what keeps it from using it.

A mirror copies deletions too. `one` takes a daily btrfs snapshot of each folder from a
systemd timer of its own, and the snapshots make it a backup. A monthly scrub and a SMART
check report to the owner, so a dead drive is noticed.

The owner seeds the first copy over the LAN while `one` is still in the UK, and tests a
restore from it there. After the move, Syncthing finds `zero` again through global
discovery or a relay and sends only what changed.

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

## Docs this changes

`README.md`'s host tables, the placement table in
[`docs/management-plane.md`](../docs/management-plane.md), roadmap §5 (the boxes no longer
share one stack), `hosts/three/`, and `hardware.md` for `zero`, `one` and `three`.
