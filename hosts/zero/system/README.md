# hosts/zero/system

Tracked reference copies of `zero`'s `/etc` files. Nothing here is applied to the host
— `bin/check-system-drift zero` only reports differences.

`zero` is the mission-critical box (Immich + Syncthing) and it is remote.

| File | Live path | Why it's tracked |
|---|---|---|
| `fstab` | `/etc/fstab` | All three `/media/*` entries carry `nofail`, so a missing array can never stall boot. |
| `bcache-register` | `/etc/init.d/bcache-register` | The array is btrfs RAID1 across **two** bcache devices; both must assemble before it can mount rw. This registers them and waits, bounded to 30s, then **always exits 0** — a failure here must never stop the boot. |

**The mountpoints are `chattr +i`.** That is the actual protection against a failed
mount silently destroying the Immich library, and it is not visible in any file here.
`sudo bin/check-mount-guards` verifies it — including attempting a real write rather
than trusting the flag. Read
[`../../../docs/recovery.md`](../../../docs/recovery.md) before touching a bare
mountpoint, or you will get `Permission denied` as root and not know why.

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

**Cache mode checked Aug 2026: `writethrough` on both devices, 0.0k dirty.** So the
cache currently holds nothing the backing disks don't, and is a disposable accelerator
rather than live data. That is a *setting*, not a guarantee — `writeback` would make the
SSD hold dirty blocks and turn it into sensitive, non-removable state. Re-check with
`cat /sys/block/bcache0/bcache/cache_mode` before relying on it.

Gotchas:

- On Debian 12 a non-root encrypted device with **only** a crypttab entry silently fails
  to unlock and never prompts; it needs an fstab entry carrying `_netdev` as well.
- **No key material in this repo, ever.** `*.key`/`*.keyfile` are gitignored. There is
  no keyfile in this design, but the ignore stays as a backstop.
- Because only the data disk is encrypted and not root, none of this needs initramfs
  networking and `/boot/cmdline.txt` is never touched.
