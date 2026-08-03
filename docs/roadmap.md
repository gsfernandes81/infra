# What's left

`one` is fully in this repo and working. `zero` and `two` aren't in it yet — only
placeholder dirs under `hosts/`. None of this is urgent; none of it should be started
remotely except step 1.

## 1. Confirm `two`'s hardware — one command

```sh
uname -m; grep -m1 Model /proc/cpuinfo
```

It reports `armv6l` + 512 MB, which is **not** a Pi 2 (that's `armv7l`, 1 GB) — so
it's a **Pi 1 B+ or a Zero**. That matters because armv6 means Raspberry Pi OS 32-bit
only, which constrains the distro choice for the *whole fleet*.

## 2. Podman on `one`

`one` is the right guinea pig — non-critical and fully described here.

**The one thing not to get wrong:** gluetun and qBittorrent must stay in a shared
network namespace or port forwarding breaks silently. See
[port-forwarding.md](port-forwarding.md). The gluetun stack will likely need to be
rootful.

## 3. Distro migration

`two`'s armv6 is the blocker, not preference — there's essentially no non-Debian
systemd distro for it. Arch ARM's `armv6h` froze Feb 2024; Alpine and Void are
OpenRC/runit; Pi OS and DietPi are Debian.

**Best value: replace `two` with a Pi Zero 2 W (~£15).** Quad-core, aarch64, same
512 MB — ample for tang, and it makes all three hosts one architecture. Otherwise:
leave it on Alpine (it's idle, and tang doesn't need systemd), or retire it and run
tang in a container on `one`.

For `zero` (Pi 5) and `one` (Pi 4):

| Distro | Pi 5 support | Note |
|---|---|---|
| **openSUSE MicroOS** | official, Nov 2025 | Transactional/immutable, btrfs + snapper rollback — good for a box you can't touch for months. Leap Micro 6.3 expected late 2026. |
| **AlmaLinux 10** | official since 9.4 | ~10-year support. Podman/Quadlet are Red Hat tech, so first-class. arm64 only. |
| Arch ARM | unofficial | Rolling release on a box you visit twice a year. No. |
| Fedora IoT | **no** | Best Quadlet story, but mainline Pi 5 RP1 ethernet is incomplete. |
| NixOS | possible | Big pivot; Pi 5 needs `raspberry-pi-nix`. |

**Plan:** `one` → MicroOS first (prove Quadlet where breakage is free), then `zero` →
AlmaLinux 10 (lower risk today), then `two`.

**Before any systemd box reboots:** the `nofail` and `RequiresMountsFor=` items in
[recovery.md](recovery.md). That's the one that could actually strand you.

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

Tang buys one thing: `zero` reboots unattended so long as `two` is up. A power cut
still costs one SSH unlock, it just moves to `two`. Tang doesn't authenticate clients —
it protects against the disk leaving the network, not an intruder on the LAN. Make sure
`two` has no boot dependency on `zero`, or they deadlock.

## 5. Cloudflare token — in person only

See [recovery.md](recovery.md#dont-break-remote-access).

## Not doing

Generating `/etc/fstab` from the repo (puts a generated file on the boot path) ·
adding `gavin` to `docker` (root-equivalent) · a NOPASSWD sudoers rule ·
switching the torrents stack to WireGuard.
