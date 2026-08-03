# hosts/two/system

**`two` is being retired.** Nothing here will be populated.

**Raspberry Pi Model B Plus Rev 1.2, `armv6l`, 512 MB** (confirmed Aug 2026) —
single-core ARM1176 at 700 MHz, 100 Mbit ethernet over USB. Not a Pi 2.

That architecture was the only thing forcing the fleet onto Debian: Arch ARM's `armv6h`
port froze Feb 2024, Alpine and Void are OpenRC/runit, and Pi OS and DietPi are Debian.
armv6 also rules out Claude Code, whose native build is arm64/x86-64 only. Retiring one
idle box removes the constraint and lets `one` and `zero` go to openSUSE MicroOS.

If a second host is ever wanted — for tang, so `zero` can reboot unattended — either
run tang in a container on `one`, or add a **Pi Zero 2 W** (~£15, quad-core, aarch64,
same 512 MB, which is ample for a socket-activated service that runs for milliseconds
per unlock).
