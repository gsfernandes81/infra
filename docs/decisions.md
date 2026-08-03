# Decisions

Settled. The reasoning is here so it doesn't get re-derived — argue with the reason,
not from scratch.

| Decision | Because |
|---|---|
| Named `infra`, not `containers` | It holds host system config too. |
| `deployments/` canonical, `hosts/` symlinks in | Lets each host move to a different distro without touching stack definitions. |
| Deploy stubs + `SOURCE`, not submodules | Same benefit, none of the detached-HEAD trap. |
| `SOURCE` records a sha, never pulls | Otherwise a restart at 03:00 silently deploys whatever upstream HEAD is, and you find out from mid-ocean. |
| `${SRC_ROOT:?...}` with `:?`, not `:-` | Unset stops Compose with your error message instead of building from a wrong path. |
| `/etc/fstab` tracked read-only, never generated | Generated files on the boot path are the one red line. |
| esmira, immich-ml dropped | Dead for months; esmira's data dirs were empty. |
| Staying on OpenVPN | Works and is proven. The WireGuard key is unused but still live, so still gitignored. |
| `gavin` not in `docker` group | Root-equivalent. Rootless Podman removes the need. |
| Target OS is **openSUSE MicroOS** | Immutable root with btrfs snapshots and auto-rollback on a failed boot — the right shape for a box you can't reach for months. Official Pi 5 support. |
| `two` leaves the fleet, but is **kept as the lifeboat** | Its armv6 was the *only* thing forcing a Debian fleet, so it doesn't migrate. It stays powered on for serial console, power-cycling, and watchdog duty — the things that help when a critical box won't boot. Stays on Alpine, diskless. |

## `zero`'s encrypted volume

**Immich serves by default; a security concern keeps it down.** That veto is the design
— the monitoring exists to let you use it.

Which settles the unlock: **manual passphrase over SSH, every boot. No keyfile, no
tang, nothing automatic.** Anything that unlocks without you is a key at rest on
hardware an attacker may be holding. The payoff is that a reboot *re-locks* the data,
so rebooting into a root shell — the cheapest Pi attack — gets them a locked volume.

**Tang: rejected**, not deferred. It exists to unlock without you; all three Pis share
one column so a same-stack tang protects nothing; and Alpine packages neither `tang`
nor `clevis` on any architecture (checked Aug 2026). Reasoning in
[roadmap.md](roadmap.md#tang--rejected).

## Two things the original inventory got wrong

Recorded because they're easy to repeat:

- **`send2ereader` was always its own compose project**, not part of `ionic` — its
  compose file declared no `name:`, so Compose derived one from the directory. Six
  containers carried `project=ionic`, not seven.
- **esmira and immich-ml weren't "down with no containers"** — each had an *exited*
  container and a registered project. Deleting their compose files alone would have
  orphaned them permanently; they needed a real `compose down`.

## The lesson worth keeping

**A check that can pass for the wrong reason is worse than no check**, because it stops
you looking. The port-forward check originally asked only "did the port change" and
passed on qBittorrent's own default within seconds. See
[port-forwarding.md](port-forwarding.md#3-the-port-changed-does-not-mean-it-worked).
