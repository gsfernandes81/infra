# hosts/two/system

**Raspberry Pi Model B Plus Rev 1.2, `armv6l`, 512 MB** (confirmed Aug 2026) —
single-core ARM1176 at 700 MHz, 100 Mbit ethernet sharing a USB 2.0 bus, no crypto
acceleration.

`two` does **not** join the MicroOS fleet — its armv6 was the only thing that would
have forced the whole fleet onto Debian, and armv6 also rules out Claude Code (arm64
and x86-64 only). It is kept, powered on, for a different job.

## Its job: the lifeboat

Five jobs, all tiny, all suited to hardware that cannot do anything demanding:

1. **Serial console** to `zero` and `one` — a login prompt when a box has dropped to
   emergency mode with no network.
2. **Power-cycle authority** via a smart plug.
3. **Dead-man's switch** — reports the other hosts' health outward, because a watchdog
   running on the box being watched is not a watchdog.
4. **Boot-integrity monitoring** — boot time, `/boot` hash, block-device inventory.
   This is what makes remote unlocking of `zero`'s encrypted volume defensible: it
   turns "I have no idea whether anyone touched it" into a decision you can actually
   make.
5. **Independent access path** — Tailscale or WireGuard, separate from cloudflared.

The full case, and the trust logic behind job 4, is in
[`docs/roadmap.md`](../../../docs/roadmap.md#5-two--keep-it-as-the-lifeboat).

**Stays on Alpine, in diskless mode** — running from RAM with the SD card read-only,
committed via `lbu commit`. The box whose purpose is surviving other boxes' failures
should be the one least able to die of SD-card corruption.

Nothing household-critical goes here: no DNS, no backups, no log sink.

## Tang is not currently possible here

Alpine packages **neither `tang` nor `clevis`** — checked Aug 2026 across `main`,
`community` and `edge`, on `armhf`, `armv7` and `aarch64`. Only `jose`, their
dependency, is present. So tang cannot be `apk add`-ed on this box, and it would mean
either building from source on a 700 MHz CPU or switching to Raspberry Pi OS, which
does package both for armhf.

That decision is on hold anyway, and for a better reason: a tang server sitting beside
`zero` doesn't protect against theft, it just means the thief takes two boxes instead
of one. See the roadmap before doing anything here.

## Tracked `/etc` copies

None yet, and there may never be — this is a reference directory, and
`bin/check-system-drift two` only reports differences. Nothing here is applied to the
host.
