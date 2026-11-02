# `three` joins the fleet, and `one` becomes the off-site mirror

A proposal from the owner's discussion of 2026-11-02, to be carried out at the November
2026 visit. [`microos-cutover.md`](microos-cutover.md) is how the visit does it; this file
is the end state and why. When the visit has done it, the reasoning moves to
[`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

## The end state

| Host | Board | Where | Runs |
|---|---|---|---|
| `zero` | Pi 5, 4 GB | UK stack | Immich with machine learning, Syncthing, pearl-wallet |
| `three` | Pi 4, 8 GB | UK stack, in `two`'s serial reach | the dev hub and every dev container; torrents, calibre-web, send2ereader, garmin-mcp |
| `one` | Pi 4, 1 GB | Argon EON; UK first, Singapore later | the off-site mirror, nothing else |
| `two` | Pi 1 B+ | UK stack | the lifeboat, as roadmap §5 says |

`zero` keeps only the critical services. Today the dev containers share its 4 GB with
Immich's machine learning and fill 41 G of its 64 G Docker partition; on 2026-11-02 it
held 1.1 G in swap. Immich does not move: its library is 104 G of an array with 798 G
free, and moving it is the riskiest migration this fleet could do.

`three` takes the work that needs memory and is not critical. The dev containers want 8 GB
more than a Pi 5's speed. `one`'s apps need no bulk storage, so they move with `one`'s
Sabrent and its 500 G SSD, which carries their data.

`one` is the off-site copy. A mirror needs disks and little memory, and a box that serves
nobody loses nothing by sitting outside `two`'s serial reach. It ships to Singapore after
the November visit, at a date the owner picks.

## The Argon EON

Only the two middle bays take 3.5" drives; the two side bays are 2.5" only. The 12 V 5 A
adapter powers the Pi as well. Two 3.5" drives peak at 3.5 A on 12 V at spin-up.

| Bay | Drive | Role |
|---|---|---|
| middle | WD49EFZZ, 4 TB | btrfs RAID1 |
| middle | WD49EFZZ, 4 TB | btrfs RAID1 |
| side | empty | a 2.5" SSD later, which makes the array RAID1C3 |
| side | empty | kept free, so a replacement can be slid in without pulling the dead drive |

The WD49EFZZ is an Amazon-only WD Red Plus 4 TB: CMR, 5400 rpm, rated 24/7. Before
trusting one, the owner checks its serial with WD and reads `smartctl -d sat -i`, `-A` and
`-l scterc`.

## What the mirror carries

Syncthing carries the copy, in **receive-only** folders, because the alternative breaks a
rule. `btrfs send` needs one box to ssh into the other, and no box on this fleet holds a
key to another ([`decisions.md`](../docs/decisions.md) § *SSH between hosts*). Syncthing
pairs devices by ID and gives neither a shell.

- Immich's `library`, `upload` and `backups`, about 93 G on 2026-11-02. `backups` holds
  Immich's nightly database dumps, so a restore is the library plus the latest dump.
  `thumbs` and `encoded-video` are ignored, because Immich regenerates them.
- `zero`'s Syncthing share, 28 G.
- Never the live Postgres directory, because a copy taken mid-write is inconsistent.

A mirror copies deletions too. `one` takes a daily btrfs snapshot of each folder from its
own cron, and the snapshots make it a backup. A monthly scrub and a SMART check report to
the owner, so a dead drive is noticed.

The first copy is seeded over the LAN while `one` is still in the UK, and a restore is
tested from it there. After the move, Syncthing finds `zero` again through global
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
copies:

1. With `one` powered off, take its SSD out of its Sabrent, so `zero` never sees `one`'s
   filesystem.
2. Connect that Sabrent to a free port on `zero`, with the new drive in it.
3. Run `make-bcache -B` on the new drive and attach it to `zero`'s cache set.
4. Run `btrfs replace` from `sdb`'s bcache device to the new one. Immich keeps running.
5. Commit `bcache-register` with the new UUID, and install it with `install-system-file
   --allow-content-change`, **before any reboot**. The script names each member by UUID,
   so a reboot before this leaves the array unmountable without `degraded`.
6. Shut `zero` down, move the new drive into `sdb`'s bay, boot, and run
   `check-mount-guards`.
7. Put `one`'s SSD back in its Sabrent, return the Sabrent to `one`, and boot `one`, so
   the slice ends with every box serving.
8. Run `btrfs filesystem resize <devid>:max` on the new member. The array stays at 1 TB
   until the WD Elements disk is replaced as well.
9. Wipe `sdb`. It holds Immich's photos, unencrypted.

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
