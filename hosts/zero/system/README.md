# hosts/zero/system

Tracked reference copies of `zero`'s `/etc` files. Nothing here is applied to the
host — `bin/check-system-drift zero` only reports differences.

`zero` is the mission-critical box (Immich + Syncthing) and it is remote. Empty for
now; it gets populated when `zero` is brought into this repo.

When `crypttab` lands here, four things matter, in order:

1. **The unlock must be non-interactive.** A crypttab entry with no keyfile makes
   systemd wait on `systemd-ask-password` indefinitely, on a box with no console you
   can reach. This is the failure that strands you.
2. **Start with a keyfile on the unencrypted root.** It protects against the disk
   walking out of the house, which is the actual threat model for a home server. The
   Pi has no TPM. Clevis + Tang (unlock only while on your LAN) is a later upgrade,
   and it costs a boot-time dependency on a second host being up.
3. **Nothing on the boot path may depend on it.** `nofail` +
   `x-systemd.device-timeout=10`, and not `RequiredBy=local-fs.target`, so a failed
   unlock leaves you a booted box with working SSH — degraded, not unreachable.
4. **Guard the containers with `RequiresMountsFor=`.** Otherwise Immich starts against
   an empty directory and writes a blank library into it.

Two gotchas that cost an evening each:

- On Debian 12, a non-root encrypted device with **only** a crypttab entry silently
  fails to unlock and never prompts. It needs an `/etc/fstab` entry carrying `_netdev`
  **as well**. That "both" is not optional.
- **The keyfile is never committed.** `*.key`/`*.keyfile` are gitignored; reference it
  by path in the tracked crypttab and back it up out of band. Losing it loses the
  volume.

Because only the data disk is encrypted and not the root filesystem, none of this
needs initramfs networking and `/boot/cmdline.txt` is never touched.
