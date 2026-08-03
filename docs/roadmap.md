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

**`two` is retired, not migrated.** Its armv6 was the only thing forcing a Debian
fleet: Arch ARM's `armv6h` froze Feb 2024, Alpine and Void are OpenRC/runit, Pi OS and
DietPi are Debian. Dropping it removes the constraint entirely. If tang is ever wanted,
run it in a container on `one`, or add a Pi Zero 2 W (aarch64, ~£15) later.

What's different day-to-day on MicroOS, since it's easy to forget:

- **Root is read-only.** You don't `zypper install`; you run
  `transactional-update pkg install <pkg>` and the change lands in a new btrfs snapshot
  that takes effect **on reboot**. `transactional-update shell` for a throwaway session.
- `/etc` is a writable overlay, so config edits work normally.
- Health-checked boots roll back automatically to the last good snapshot.
- Quadlet units go in `/etc/containers/systemd/`; `systemctl daemon-reload` generates
  the services.

**Before the first reboot on it:** the `nofail` and `RequiresMountsFor=` items in
[recovery.md](recovery.md). Alpine's OpenRC forgave a missing USB disk; systemd will
not, and that's the failure that strands you.

## 4. Encrypted data volume on `zero`

Detail in [`../hosts/zero/system/README.md`](../hosts/zero/system/README.md). In order:

1. The unlock **must be non-interactive** — a passphrase prompt on a headless remote
   box is fatal.
2. Start with a keyfile on the unencrypted root. Clevis + Tang is a later upgrade.
3. Nothing on the boot path may depend on it — a failed unlock should leave you a
   booted box with SSH, degraded not unreachable.
4. Guard containers with `RequiresMountsFor=` or Immich writes a blank library into an
   empty mountpoint.

Gotcha worth an evening: on Debian 12 a non-root device with only a crypttab entry
**silently fails to unlock and never prompts** — it also needs an fstab entry with
`_netdev`.

### Tang — still undecided, and there is an unresolved problem

**Do not deploy tang until the question below is answered.**

Tang buys unattended reboot: `zero` comes back on its own so long as a tang host is up
— the common case (kernel update, crash, OOM). A power cut still costs one SSH unlock.

**The problem: a tang host in the same house doesn't stop theft, it just widens what
has to be stolen.** The point of encrypting the disk is that walking off with it gets
you nothing. If the unlock server sits on the same shelf, the thief takes both and is
back where they started. "Run away with `zero`" becomes "run away with `zero` and
`two`" — which is the same burglary.

What is actually true about tang, and what it means:

- The tang server **never learns the encryption key** (McCallum–Relyea exchange), so a
  stolen tang box on its own is worthless. The exposure is only ever *disk + reachable
  tang*.
- So the mitigations are: make tang unreachable to the thief, or be able to **revoke**.
  Revocation means removing the old key from the tang server's key directory — which
  you cannot do to a server that has been stolen.
- Tang does not authenticate clients. Anyone who can reach it can use it. **It must
  never be exposed to the internet** — LAN or Tailscale only. A publicly reachable tang
  server means the stolen disk unlocks from anywhere.

Three ways out, to be chosen deliberately:

1. **Accept it: tang is for availability, not anti-theft.** Same-house tang, and the
   honest statement is that the encryption protects against a disposed or RMA'd drive,
   not a burglary. Cheapest, and possibly correct — but then say so out loud rather
   than believing in protection that isn't there.
2. **One factor off-site.** Clevis supports Shamir secret sharing: a `t=2` policy over
   two tang servers, one at home and one off-site (a friend's house, or a VPS reachable
   only over Tailscale). Stealing the house yields one share, which unlocks nothing.
   Cost: unlock now depends on the off-site host and the internet being up. Since this
   is a late unlock of a data volume — not root, no initramfs networking — the network
   *is* up by then, so this is more workable here than it usually is.
3. **Physical separation only.** Tang hidden elsewhere in the building. Better than the
   same shelf, worse than off-site, and it fails against anyone who searches properly.

Whatever is chosen, two things must exist before the disk is encrypted: a written
**rotation/revocation procedure** that can be run from wherever you are, and a
confirmation that the tang host has **no boot dependency on `zero`** — or the two
deadlock waiting for each other.

**Packaging constraint, checked Aug 2026:** Alpine does not package `tang` or `clevis`
at all — not in `main`, `community` or `edge`, on any architecture including `aarch64`.
Only `jose`, their dependency, is present. So tang cannot be `apk add`-ed on `two`, and
`clevis` is unavailable on `zero` for as long as it runs Alpine. That pushes any tang
plan onto Raspberry Pi OS (Debian packages both for armhf), a container on `one`, or
`zero`'s move to MicroOS. Verify openSUSE's packaging before relying on it.

## 5. `two` — keep it as the lifeboat

Not joining the MicroOS fleet, but no longer being retired: it gets a defined job that
suits a 700 MHz single-core box with 512 MB and no crypto acceleration.

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

Caveat: the console role assumes `two` sits physically beside the others. If it does
not, that half evaporates and the case narrows to watchdog and alerting.

## 6. Cloudflare token — in person only

See [recovery.md](recovery.md#dont-break-remote-access).

## Not doing

Generating `/etc/fstab` from the repo (puts a generated file on the boot path) ·
adding `gavin` to `docker` (root-equivalent) · a NOPASSWD sudoers rule ·
switching the torrents stack to WireGuard.
