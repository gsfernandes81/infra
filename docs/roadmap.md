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

Tang buys one thing: `zero` reboots unattended so long as the tang host is up — the
common case (kernel update, crash, OOM). A power cut still costs one SSH unlock, it
just moves hosts. Tang doesn't authenticate clients: it protects against the disk
leaving the network, not an intruder on the LAN.

With `two` retired the tang host would be `one` (in a container) or a new Pi Zero 2 W.
Whichever it is, it must have **no boot dependency on `zero`**, or the two deadlock.

## 5. Cloudflare token — in person only

See [recovery.md](recovery.md#dont-break-remote-access).

## Not doing

Generating `/etc/fstab` from the repo (puts a generated file on the boot path) ·
adding `gavin` to `docker` (root-equivalent) · a NOPASSWD sudoers rule ·
switching the torrents stack to WireGuard.
