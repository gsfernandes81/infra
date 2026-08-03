# hosts/zero/system

Tracked reference copies of `zero`'s `/etc` files. Nothing here is applied to the host
— `bin/check-system-drift zero` only reports differences. Empty until `zero` is brought
into this repo.

`zero` is the mission-critical box (Immich + Syncthing) and it is remote.

## When `crypttab` lands here

The design is decided; full reasoning in
[`docs/roadmap.md`](../../../docs/roadmap.md#4-encrypted-data-volume-on-zero).

1. **The unlock is manual and interactive, on purpose.** A passphrase over SSH, every
   boot. No keyfile, no tang, nothing automatic — anything that unlocks without you is
   a key at rest on hardware someone may be holding. The payoff: a reboot re-locks the
   data, so booting into a root shell gets an attacker a volume they cannot open.
2. **Therefore the entry must be `noauto`.** This is the trap: a crypttab entry with no
   keyfile makes systemd wait on `systemd-ask-password` **indefinitely**, on a box with
   no console you can reach. `noauto` on both the crypttab and fstab entries, unlocked
   by hand after boot, is what keeps a locked volume from becoming an unreachable box.
3. **Nothing on the boot path may depend on it.** `nofail` +
   `x-systemd.device-timeout=10`, never `RequiredBy=local-fs.target`. A locked volume
   must leave you a booted box with working SSH — degraded, not unreachable.
4. **Guard the Immich units with `RequiresMountsFor=`.** Otherwise a locked volume means
   Immich starts against an empty directory and writes a blank library into it. `Wants=`
   is not enough.

**LUKS goes on `/dev/bcache0`**, above the cache — not on the backing disk. Encrypting
below bcache leaves the cache SSD holding plaintext of everything recently accessed.

Gotchas:

- On Debian 12 a non-root encrypted device with **only** a crypttab entry silently fails
  to unlock and never prompts; it needs an fstab entry carrying `_netdev` as well.
- **No key material in this repo, ever.** `*.key`/`*.keyfile` are gitignored. There is
  no keyfile in this design, but the ignore stays as a backstop.
- Because only the data disk is encrypted and not root, none of this needs initramfs
  networking and `/boot/cmdline.txt` is never touched.
