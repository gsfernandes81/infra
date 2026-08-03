# What's left

`one` is fully in this repo and working. `zero` and `two` aren't in it yet — only
placeholder dirs under `hosts/`. None of this is urgent; none of it should be started
remotely except step 1.

## 1. Onboard `zero` into this repo

Same exercise as `one`, but every container is critical and the box is remote. The
brief is in [`../hosts/zero/HANDOFF.md`](../hosts/zero/HANDOFF.md) — inventory and plan
first, no changes.

## 2. Podman on `one`

`one` is the right guinea pig — non-critical and fully described here.

**The one thing not to get wrong:** gluetun and qBittorrent must stay in a shared
network namespace or port forwarding breaks silently. See
[port-forwarding.md](port-forwarding.md). The gluetun stack will likely need to be
rootful.

## 3. openSUSE MicroOS — the target

**Decided.** Transactional/immutable root with btrfs snapshots and automatic rollback
on a failed boot, which is what you want on a box you can't physically reach for
months. Official Pi 5 support since Nov 2025 (SUSE did the U-Boot work). Podman and
Quadlet are the native container story.

`one` (Pi 4) first — prove the Quadlet conversion where breakage costs nothing — then
`zero`.

**`two` doesn't migrate.** Its armv6 was the only thing forcing a Debian fleet: Arch
ARM's `armv6h` froze Feb 2024, Alpine and Void are OpenRC/runit, Pi OS and DietPi are
Debian. Leaving it out removes the constraint. It stays on Alpine with its own job —
see [§5](#5-two--keep-it-as-the-lifeboat).

What's different day-to-day on MicroOS, since it's easy to forget:

- **Root is read-only.** You don't `zypper install`; you run
  `transactional-update pkg install <pkg>` and the change lands in a new btrfs snapshot
  that takes effect **on reboot**. `transactional-update shell` for a throwaway session.
- `/etc` is a writable overlay, so config edits work normally.
- Health-checked boots roll back automatically to the last good snapshot.
- Quadlet units go in `/etc/containers/systemd/`; `systemctl daemon-reload` generates
  the services.

**Check bcache before migrating `zero`.** Its data disk is fronted by an SSD cache, so
the target OS needs `bcache-tools` and must assemble `/dev/bcache0` before the mount
units run. bcache is mainline, so the kernel side is fine; packaging and initramfs
ordering are what to verify.

**Before the first reboot on it:** the `nofail` and `RequiresMountsFor=` items in
[recovery.md](recovery.md). Alpine's OpenRC forgave a missing USB disk; systemd will
not, and that's the failure that strands you.

## 4. Encrypted data volume on `zero`

Threat model: someone may have unsupervised physical access to the stack for weeks
while you are away.

**The policy: Immich serves by default, and a security concern keeps it down.** That
veto is the whole design — everything below exists to give you enough information to
use it, and it is only worth building if you will actually hold the line at week four
of a trip.

### Manual unlock only. No keyfile, no tang, nothing automatic.

Any unlock that survives a reboot without you is a key **at rest on hardware the
attacker holds**. A keyfile on the unencrypted root is readable by anyone who takes the
box. Tang is the same property over a network. Both hand over the volume to whoever
walks off with the stack.

So the unlock is a passphrase you supply over SSH, every boot. Nothing else.

This is a reversal of the earlier "start with a keyfile" plan, and of tang as a later
upgrade. Both were written when unattended reboot was the goal. It isn't — you have
said Immich can stay down — and once availability stops being the constraint, at-rest
keys have nothing left to recommend them.

### Why this is stronger than it looks: a reboot defends itself

Because nothing auto-unlocks, **a reboot re-locks the data.** That closes the obvious
physical attack: booting the machine into a root shell (`init=/bin/sh` in
`cmdline.txt`, the cheapest Pi attack there is) now yields a running system with an
encrypted volume the attacker cannot open. Rebooting destroys the thing they came for.

Their remaining paths are narrow, and each is covered:

| Path | Why it is hard here |
|---|---|
| Read the mounted volume on the running box | Needs code execution without rebooting. Headless, no credentials, no DMA-capable external ports. |
| Modify persistent storage | Requires pulling a device in active use → halts the machine → reboot you can see. |
| Swap `/boot` while running | Only possible if `/boot` is on its own device. On `zero` it is not — `/` and `/boot` share the SD card, confirmed. Run `bin/check-boot-layout` after any change. |
| Tamper, then wait for you to unlock | The real one. This is what `two`'s boot-integrity monitoring exists to catch. |

### Residual risks, stated plainly

- **While the volume is mounted and serving, the data is decrypted.** Encryption
  protects the powered-off box and the locked periods, not the serving ones. Off-site
  backup is what covers the rest.
- **An induced reboot can be disguised as a power cut.** The UPS closes this: with
  mains blips no longer causing reboots, a reboot with no battery-exhaustion event in
  the NUT log means someone rebooted that machine.
- **You unlock without checking.** No technical control helps here.

### Operational gotchas

- On Debian 12 a non-root device with only a crypttab entry **silently fails to unlock
  and never prompts** — it also needs an fstab entry carrying `_netdev`.
- Nothing on the boot path may depend on the encrypted volume. A locked volume must
  leave you a booted box with working SSH — degraded, not unreachable.
- Guard the Immich units with `RequiresMountsFor=`, or a locked volume means Immich
  starts against an empty directory and writes a blank library into it.

### bcache: LUKS goes *above* it, never below

`zero`'s SSD is a **bcache cache** in front of the data disk, which dictates the
layering:

```
correct    filesystem → LUKS → /dev/bcache0 → { cache SSD, backing disk }   both ciphertext
WRONG      filesystem → /dev/bcache0 → { raw cache SSD, LUKS backing disk } cache holds PLAINTEXT
```

Encrypt `/dev/bcache0` — the assembled device. The tempting mistake is to encrypt the
big backing disk and leave bcache on top of it, which caches *decrypted* blocks onto a
bare SSD. Someone walking off with just the cache device then gets every recently
accessed photo, and the disk encryption you paid for protects nothing that was warm.

Two consequences:

- **Wipe the cache when you encrypt.** It currently holds plaintext of today's
  unencrypted data. Detach it and `blkdiscard` before reattaching, or old plaintext
  survives on the SSD indefinitely.
- **Check the cache mode.** In `writeback` the SSD holds dirty blocks not yet on the
  backing disk — so it is not merely a cache, it is live data, and it must be treated
  as sensitive and as something you cannot casually remove.

### Tang — rejected

Decided, not deferred. Tang exists to make an unlock happen **without you**, and that
is precisely what this design does not want.

Three independent reasons, any one sufficient:

1. **It is an at-rest key by another name.** The value of manual unlock is that nothing
   on or near the hardware can open the volume. Tang re-introduces exactly that.
2. **Same-stack tang protects nothing.** All three Pis share one column. "Run away with
   `zero`" becomes "run away with `zero` and `two`" — the same burglary. Only an
   off-site factor (clevis Shamir `t=2`, one share on a VPS over Tailscale) would have
   added anything, and that only mattered while unattended reboot was a goal.
3. **Alpine packages neither `tang` nor `clevis`** — checked Aug 2026 across `main`,
   `community` and `edge`, every architecture including `aarch64`. Only `jose`, their
   dependency. So it was never cheap here either.

Worth keeping in mind if this is ever revisited: the tang server never learns the key
(McCallum–Relyea), so a stolen tang box alone is worthless — the exposure is only ever
*disk + reachable tang*. And tang does not authenticate clients, so it must never face
the internet.

## 5. `two` — keep it as the lifeboat

It doesn't join the MicroOS fleet, but it stays powered on with a defined job — one
that suits a 700 MHz single-core box with 512 MB and no crypto acceleration.

The recurring problem here isn't compute, it's **being months away from a critical box
with no way in when the network path dies** — which is exactly the emergency-mode
failure in [recovery.md](recovery.md). `two` is the way in:

- **Serial console to `zero` and `one`** via USB-serial or GPIO UART (cross TX/RX,
  common ground, 3.3 V both ends; the Pi 5 has a dedicated debug UART connector). Run
  `ser2net` and you can watch `zero` boot and get a login prompt when it has dropped to
  emergency mode with no network. This alone justifies keeping it.
- **Power-cycle authority** — a Tasmota or Zigbee smart plug. Console plus the ability
  to actually reboot turns "bricked until I fly home" into a Tuesday.
- **Dead-man's switch** — pings the other two and reports to ntfy or healthchecks.io.
  A watchdog running on the box being watched is not a watchdog.
- **Boot-integrity monitoring** — the job that makes remote unlock defensible. Poll
  `zero` and `one` for three things and alert on any change:

  | Signal | Why |
  |---|---|
  | boot time (`/proc/uptime`) | a reboot is the cost of tampering with in-use storage — it is the detection channel |
  | hash of `/boot` | catches a modified initramfs or kernel planted for the *next* boot |
  | block devices present | catches a disk added or removed |

  The trust logic, which is why this is worth building rather than assuming: **a system
  that has not rebooted is still running the code you trust, so it can honestly measure
  the storage that would compromise its next boot.** Signal 2 is only meaningful while
  signal 1 says nothing has restarted — but when it does, it closes the swap-and-wait
  attack. Keep the known-good `/boot` manifest off-box; this repo is a fine home for it.

  Corollary: after an *unexplained* reboot none of this can be trusted, because a
  landed payload lies about its own hashes. That is the point at which the honest
  answer is to leave the volume locked until you are physically there.
- **Independent access path** — Tailscale or WireGuard, separate from cloudflared.
  Throughput will be poor (no crypto extensions, NIC shares a USB 2.0 bus) and that is
  irrelevant for a management shell.

**Stay on Alpine, in diskless mode.** Running from RAM with the SD card read-only —
committing only via `lbu commit` — makes the box whose entire purpose is surviving
others' failures immune to SD-card corruption. That matters more than package choice on
hardware whose card has had a decade to wear out. Only switch to Raspberry Pi OS if
tang becomes its job, since Alpine cannot provide it (see above).

**Do not put on it:** DNS/Pi-hole (household-critical on the oldest hardware and the
most worn card, while you are unreachable), backups, a log sink (SD wear), or anything
Node.js-shaped.

All three sit in one stack, so the console and power-cycle roles are viable — a short
UART run and one smart plug. (That same colocation is what breaks the tang plan; see
above.)

## 6. Cloudflare token — in person only

See [recovery.md](recovery.md#dont-break-remote-access).

## Not doing

Generating `/etc/fstab` from the repo (puts a generated file on the boot path) ·
adding `gavin` to `docker` (root-equivalent) · a NOPASSWD sudoers rule ·
switching the torrents stack to WireGuard.
