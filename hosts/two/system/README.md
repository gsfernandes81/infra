# hosts/two/system

Tracked reference copies of `two`'s `/etc` files. Nothing here is applied to the host
— `bin/check-system-drift two` only reports differences. Empty for now.

## Hardware — confirm before planning anything

`two` reports `armv6l` with 512 MB. That is **not** a Pi 2 Model B (which is `armv7l`,
quad-core Cortex-A7, 1 GB). `armv6l` + 512 MB means a **Pi 1 Model B+** or a Pi Zero:
single-core ARM1176 at 700 MHz, 100 Mbit ethernet over USB.

Confirm on the box:

```sh
uname -m; grep -m1 Model /proc/cpuinfo
```

This decides which OS can run there, so it is worth being sure: armv6 means Raspberry
Pi OS **32-bit only** — no arm64, no 64-bit anything.

## Why this host constrains the whole fleet

`two`'s armv6 is the blocker on a non-Debian systemd fleet, not preference. Arch Linux
ARM's `armv6h` port froze in Feb 2024; Alpine and Void run there but are OpenRC and
runit; Debian itself dropped ARMv6 armhf long ago, so Pi OS armv6 is a rebuild that
RPi Ltd maintains — and individual packages do occasionally go missing.

If tang ends up here, verify availability first rather than assuming:

```sh
apt-cache policy tang clevis jose
```

`tangd` itself is a tiny socket-activated C server — 512 MB and 700 MHz are irrelevant
to a workload that runs for a few milliseconds per unlock. The risk is packaging, not
capacity.

Options, in the order they were judged: leave `two` on Alpine (it is idle and
non-critical, and tang does not need systemd); replace it with a **Pi Zero 2 W**
(~£15, quad-core, aarch64, same 512 MB) which makes all three hosts one architecture;
or retire it and run tang in a container on `one`.

**If tang lands here, `two` must have no boot-time dependency on `zero`,** or the two
hosts deadlock waiting for each other.
