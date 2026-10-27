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
`zero` has it, and **`one` was verified 2026-08-23** — it runs there and reports
correctly. `two` tracks no `/etc` files yet; when it does, it needs an interpreter or an
exemption, which is a real cost on a 512 MB armv6 box running diskless.

| File | Live path | Why it's tracked |
|---|---|---|
| `fstab` | `/etc/fstab` | All three `/media/*` entries carry `nofail`, so a missing array can never stall boot. A fourth, `/var/lib/docker` on the SSD's `sda2` (btrfs, `compress=zstd:1`), carries it too, and its bare mountpoint is immutable like theirs; installed 2026-10-26 ([`docs/decisions.md`](../../../docs/decisions.md)). |
| `bcache-register` | `/etc/init.d/bcache-register` | The array is btrfs RAID1 across **two** bcache devices; both must assemble before it can mount rw. This registers them and waits, bounded to 30s, then **always exits 0** — a failure here must never stop the boot. |
| `cloudflared` | `/etc/init.d/cloudflared` | The tunnel — the remote way in. Only trackable since Aug 2026: it previously carried the tunnel token inline, so committing it would have committed a secret. **Since 2026-08-23 it carries no secret at all** — `command_args` is `--autoupdate-freq 240h0m0s --config /etc/cloudflared/config.yml tunnel run`, and the tunnel credentials file is 0600. It is hand-written, not packaged: `docs/host-setup.md` installs the binary from GitHub, so Alpine ships no init script for it. It logged nowhere until 2026-08-23: `stdout_log`/`stderr_log` are not variables `supervise-daemon` reads, and it now uses `output_logger`/`error_logger` — see phase 2f. |
| `zram-swap` | `/etc/init.d/zram-swap` | Compressed swap in RAM ahead of the SSD swap partition, 2 GiB zstd at priority 100. **Installed 2026-10-26**: `/proc/swaps` lists `/dev/zram0` at 2 GiB, priority 100, `[zstd]`; in the default runlevel, owner-reported; [`docs/decisions.md`](../../../docs/decisions.md) § *Zram swap on `zero`* says why. Not boot-critical: a failed start leaves the SSD swap as it was. |
| `devpool` | `/etc/init.d/devpool` | The dev containers' one memory limit: cgroup v2 group `/sys/fs/cgroup/devpool`, 2560M RAM and 6G swap (the owner's, 2026-10-27, so zram and the SSD swap can both be used), named by `dev/compose.yaml` as each dev container's `cgroup_parent` once `DEV_CGROUP_PARENT=/devpool`. **Written 2026-10-27, not installed**: install and proof below. Not boot-critical. |
| `cloudflared-config.yml` | `/etc/cloudflared/config.yml` | The tunnel's ingress, moved off Cloudflare on 2026-08-23. Eight hostnames, and **the order is behaviour** — cloudflared matches first-rule-wins. This file is now the authoritative record of what zero serves; the dashboard's copy is ignored. See [`../../../docs/cloudflare.md`](../../../docs/cloudflare.md). |

**The mountpoints are `chattr +i`.** That is the actual protection against a failed
mount silently destroying the Immich library, and it is not visible in any file here.
`sudo bin/check-mount-guards` verifies it — including attempting a real write rather
than trusting the flag. Read
[`../../../docs/recovery.md`](../../../docs/recovery.md) before touching a bare
mountpoint, or you will get `Permission denied` as root and not know why.

## `devpool`: install, then prove the kill lands inside it

Owner-run, from `ssh zero`, fish. The proof runs **with no dev container in the pool**, on a
limit lowered for the test, so it never pushes zero anywhere near full; the last step puts
the real limits back.

```fish
cd ~/infra
sudo docker info --format '{{.CgroupDriver}} cgroup v{{.CgroupVersion}}'   # expect: cgroupfs cgroup v2
bin/install-system-file devpool --new                                       # dry run: the new file
sudo bin/install-system-file devpool --new --commit
sudo rc-update add devpool default
sudo rc-service devpool start; and sudo rc-service devpool show

# the test: 256M, no swap, and the kill counter before
echo 256M | sudo tee /sys/fs/cgroup/devpool/memory.max
echo 0 | sudo tee /sys/fs/cgroup/devpool/memory.swap.max
set before (sudo sed -n 's/^oom_kill //p' /sys/fs/cgroup/devpool/memory.events)
set img python:3.13-slim-trixie@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c

# calibrate first: 128 MB inside the pool must SURVIVE
sudo docker run --rm --cgroup-parent=/devpool $img python3 -c "b=b'x'*(128<<20); print('kept 128M')"
# then 512 MB must be KILLED, and counted by the POOL
sudo docker run --rm --cgroup-parent=/devpool $img python3 -c "b=b'x'*(512<<20); print('NOT KILLED')"; echo "exit $status"
echo "kills: $before -> "(sudo sed -n 's/^oom_kill //p' /sys/fs/cgroup/devpool/memory.events)
sudo dmesg | grep -i 'killed process' | tail -1

sudo rc-service devpool restart; and sudo rc-service devpool show            # the real limits back
```

Passing reads: `kept 128M`; then no `NOT KILLED`, `exit 137`, the kill count one higher,
and a kernel line for the python process. **Read the counter and the kernel, not Docker's
`OOMKilled`**, which the 2026-10-25 test showed reporting true for a container that was not
killed. If the first run is killed too, the test is wrong (the pool is not where Docker put
the container, or the limit did not take), not the pool: stop there. Once it passes, set
`DEV_CGROUP_PARENT=/devpool` in `dev/.env`, and `make up` places every dev container in it.

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
