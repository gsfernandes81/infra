# hosts/zero/system

Tracked reference copies of `zero`'s `/etc` files. `bin/check-system-drift` reports
differences and never writes; `bin/install-system-file` installs one of these onto the
host, and never restarts anything. See [`../../../CLAUDE.md`](../../../CLAUDE.md).

`zero` is the mission-critical box (Immich + Syncthing) and it is remote.

## Where each file installs is declared in the file

Every file here carries an `infra-` header, and **the same header is present in the
live file** — it is a comment, so it changes no behaviour, and keeping both copies
byte-identical means `md5sum <tracked> <live>` stays a valid check:

```
# infra-os:   alpine          distro it was written for
# infra-init: openrc          init system — the binding constraint for a service
#                             file, and it changes fstab semantics too
# infra-path: /etc/init.d     directory it installs into
# infra-name: bcache-register filename there (split from the repo filename so a
#                             MicroOS variant can install under the same name)
# infra-mode: 0755            catches a wrong-mode install, which a diff cannot see
```

The table below is a summary for humans. **The header is what the checker reads** — a
missing or malformed one is a hard failure, never a guess at the path. The previous
checker inferred `/etc/<filename>`, so it looked for `/etc/bcache-register` and
`/etc/cloudflared`, found neither, and reported three failures out of four tracked
files; it passed on `one` only because `one` tracks nothing but `fstab`.

`check-system-drift` is Python, so a host with tracked files needs `python3`.
`zero` has it. **`one` has not been verified** — check before relying on the result
there. `two` tracks no `/etc` files yet; when it does, it needs an interpreter or an
exemption, which is a real cost on a 512 MB armv6 box running diskless.

| File | Live path | Why it's tracked |
|---|---|---|
| `fstab` | `/etc/fstab` | All three `/media/*` entries carry `nofail`, so a missing array can never stall boot. |
| `bcache-register` | `/etc/init.d/bcache-register` | The array is btrfs RAID1 across **two** bcache devices; both must assemble before it can mount rw. This registers them and waits, bounded to 30s, then **always exits 0** — a failure here must never stop the boot. |
| `cloudflared` | `/etc/init.d/cloudflared` | The tunnel — the remote way in. Only trackable since Aug 2026: it previously carried the tunnel token inline, so committing it would have committed a secret. The token now lives in `/etc/conf.d/cloudflared` (mode 600, **not** tracked) and this file references `${CF_TUNNEL_TOKEN}`. |

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
