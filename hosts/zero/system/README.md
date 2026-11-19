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

On a filesystem that keeps no Unix modes, such as the Pi's FAT boot partition at
`/boot/efi` on Leap (`three`'s `extraconfig.txt`), the mount decides every file's mode:
`infra-mode` is then neither set nor checked, and `install-system-file` writes the file
without a chmod, which FAT refuses.

The table below is a summary for humans. **The header is what the checker reads** — a
missing or malformed one is a hard failure, never a guess at the path. The previous
checker inferred `/etc/<filename>`, so it looked for `/etc/bcache-register` and
`/etc/cloudflared`, found neither, and reported three failures out of four tracked
files; it passed on `one` only because `one` tracks nothing but `fstab`.

**Which directory is a host's** is one rule, `system_dir()` in `bin/_infra.py`: a host's
copies are in `hosts/<host>/system/`, or in `hosts/<host>/leap/system/` once
`hosts/<host>/leap/MOVED` records that it runs Leap ([`leap/README.md`](../../../leap/README.md)).
`zero` has no `MOVED`, so its copies are these. `server-install-system-files.yml` asks
`install-system-file --list` on the host for the files rather than finding them itself,
so the play and the tools always read the same directory.

`check-system-drift` is Python, so a host with tracked files needs `python3`.
`zero` has it, and **`one` was verified 2026-08-23** — it runs there and reports
correctly. `two` tracks no `/etc` files yet; when it does, it needs an interpreter or an
exemption, which is a real cost on a 512 MB armv6 box running diskless.

| File | Live path | Why it's tracked |
|---|---|---|
| `fstab` | `/etc/fstab` | All three `/media/*` entries carry `nofail`, so a missing array can never stall boot. A fourth, `/var/lib/docker` on the SSD's `sda2` (btrfs, `compress=zstd:1`), carries it too, and its bare mountpoint is immutable like theirs; installed 2026-10-26 ([`docs/decisions.md`](../../../docs/decisions.md)). No array line carries `autodefrag` since 2026-11-19: it unshares the blocks snapshots share, and btrfs applies it to the whole filesystem, so it leaves every line or none (§ The backup). **Not installed yet**: the move installs it. The move also replaces the two Immich lines with one `/media/immich` line, whose `subvolid` only the move learns ([`plans/visit-runbook.md`](../../../plans/visit-runbook.md) § The move on `zero`). |
| `bcache-register` | `/etc/init.d/bcache-register` | The array is btrfs RAID1 across **two** bcache devices; both must assemble before it can mount rw. This registers them and waits, bounded to 30s, then **always exits 0** — a failure here must never stop the boot. |
| `cloudflared` | `/etc/init.d/cloudflared` | The tunnel — the remote way in. Only trackable since Aug 2026: it previously carried the tunnel token inline, so committing it would have committed a secret. **Since 2026-08-23 it carries no secret at all** — `command_args` is `--autoupdate-freq 240h0m0s --config /etc/cloudflared/config.yml tunnel run`, and the tunnel credentials file is 0600. It is hand-written, not packaged: `docs/host-setup.md` installs the binary from GitHub, so Alpine ships no init script for it. It logged nowhere until 2026-08-23: `stdout_log`/`stderr_log` are not variables `supervise-daemon` reads, and it now uses `output_logger`/`error_logger` — see phase 2f. |
| `zram-swap` | `/etc/init.d/zram-swap` | Compressed swap in RAM ahead of the SSD swap partition, 2 GiB zstd at priority 100. **Installed 2026-10-26**: `/proc/swaps` lists `/dev/zram0` at 2 GiB, priority 100, `[zstd]`; in the default runlevel, owner-reported; [`docs/decisions.md`](../../../docs/decisions.md) § *Zram swap on `zero`* says why. Not boot-critical: a failed start leaves the SSD swap as it was. |
| `devpool` | `/etc/init.d/devpool` | The dev containers' one memory limit: cgroup v2 group `/sys/fs/cgroup/devpool`, 2048M soft and 2560M hard RAM, 6G swap (the owner's, 2026-10-27: reclaim early, kill only at the hard line, and let zram and the SSD swap both be used), named by `dev/compose.yaml` as each dev container's `cgroup_parent` once `DEV_CGROUP_PARENT=/devpool`. **Written 2026-10-27, not installed**: install and proof below. Not boot-critical. |
| `cloudflared-config.yml` | `/etc/cloudflared/config.yml` | The tunnel's ingress, moved off Cloudflare on 2026-08-23. Eight hostnames, and **the order is behaviour** — cloudflared matches first-rule-wins. This file is now the authoritative record of what zero serves; the dashboard's copy is ignored. See [`../../../docs/cloudflare.md`](../../../docs/cloudflare.md). |
| `tailscaled` | `/etc/init.d/tailscaled` | zero's second way in, and the backup's path to `three`: Tailscale's static arm64 build in `/usr/local`, since Tailscale's repo has nothing for Alpine and Alpine's package lacked the TS-2026-013 fix on 2026-11-03. Installed and moved by `server-install-tailscale.yml`, with the binaries at the pin in `ansible/group_vars/fleet.yml` (§ Tailscale, below). **Not installed yet.** |
| `snapper-config-immich` | `/etc/snapper/configs/immich` | snapper's config for `/media/immich`: hourly snapshots kept 24 hours, daily ones 7 days, the owner's own kept 10 deep; root alone; no qgroups (§ The backup). **Not installed**: after the move. |
| `snapper-sysconfig` | `/etc/snapper/snapper` | `SNAPPER_CONFIGS=""`, as the package ships it, so the package's own hourly script, which needs D-Bus, does nothing. **Not installed**. |
| `snapper-immich` | `/etc/periodic/hourly/snapper-immich` | The hourly snapshot and its cleanup, `snapper --no-dbus`, under `flock` (BusyBox's applet). **Not installed**: after the move, since it refuses while `/media/immich` is not mounted. |
| `sudoers-mirror` | `/etc/sudoers.d/mirror` | Lets the `mirror` user run, as root, exactly one command: `setpriv` dropping back to `mirror` with `CAP_DAC_READ_SEARCH` alone, then rsync's read-only daemon. `install-system-file` runs `visudo -cf` on it before writing. **Not installed**. |
| `rsyncd-mirror.conf` | `/etc/rsyncd-mirror.conf` | That daemon's one module, `snapshots`, read-only, over `/media/immich/.snapshots`. **Not installed**. |
| `mirror-authorized-keys` | `/home/mirror/.ssh/authorized_keys` | `three`'s pull key: `restrict`, only from `three`'s tailnet address, forced to the daemon above through sudo. Holds a placeholder until the owner makes the key on `three`. **Not installed**. |
| `mirror-backup-age-check` | `/etc/periodic/daily/mirror-backup-age-check` | **Not used, and not to be installed.** It read the push's `last-success`, and the push is gone: with the pull, `zero` never learns whether a pull succeeded. The owner deferred the alert to a dead man's switch for the whole fleet, designed separately; this file and `server-store-backup-ntfy-url.yml` stay until that design says whether it reuses them. |

**The mountpoints are `chattr +i`.** That is the actual protection against a failed
mount silently destroying the Immich library, and it is not visible in any file here.
`sudo bin/check-mount-guards` verifies it — including attempting a real write rather
than trusting the flag. Read
[`../../../docs/recovery.md`](../../../docs/recovery.md) before touching a bare
mountpoint, or you will get `Permission denied` as root and not know why.

## The backup

`three` pulls `zero`'s backup ([`plans/three-backup-pull.md`](../../../plans/three-backup-pull.md)).
`zero` takes a read-only snapper snapshot of `/media/immich`, the library in `data/` and
Postgres in `db/`, at the top of each hour, and keeps 24 hourly and 7 daily ones in
`/media/immich/.snapshots/<N>/snapshot`. Daily at 01:00 UTC `three` logs in as `mirror`,
with a key that runs nothing but a read-only rsync daemon, and copies the newest finished
one. Nothing on `zero` pushes, and nothing on `zero` runs as root for it but the instant
`setpriv` takes to drop to `mirror`.

**snapper is from Alpine's edge/testing**, `snapper-0.13.1-r0`, the only Alpine package of
it, installed once from the file and pinned in apk's world, so no `apk upgrade` moves it. It
is not upgraded until `zero` moves to Leap, where snapper is native and this config carries
over. Revisit at Alpine 3.25: it links Boost 1.84 and other libraries of the release it was
built against, and a release that moves one breaks it. It runs with `--no-dbus` everywhere:
apk installs `dbus` as a dependency, and no runlevel starts it, which is how it stays
(installing a tool is not enabling it, CLAUDE.md § Landmines). `flock` in the hourly script
is BusyBox's applet, in Alpine's BusyBox since long before 3.24 (its `busyboxconfig` sets
`CONFIG_FLOCK=y`); `command -v flock` on `zero` confirms it before the script is installed.

**setpriv is util-linux's**, from Alpine's `setpriv` package, which installs `/bin/setpriv`
over BusyBox's applet of that name. BusyBox's has no `--reuid`, so the forced command would
fail with it, and the pull with it.

`.github/workflows/alpine-sim.yml` runs the install below on Alpine 3.24 arm64, `zero`'s
release and architecture, and `microos-sim.yml`'s `three` job runs `zero`'s side as an
Alpine container for `three` to pull from.

### The install, owner-run

The steps after the move need `/media/immich` and its `.snapshots`, which the move makes
([`plans/visit-runbook.md`](../../../plans/visit-runbook.md) § The move on `zero`). After
`ssh zero`, in fish:

```fish
# on zero: the packages; check BusyBox gives flock, then util-linux's setpriv and the pinned snapper, its SHA-256 checked here and its signature by apk
command -v flock; and sudo apk add setpriv rsync sudo; and /bin/setpriv --version
cd /tmp; and wget https://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64/snapper-0.13.1-r0.apk
echo '8f62f6f5b8c603abf553711f02128ee98272253bf0fc8068aa74b74c13a120d9  snapper-0.13.1-r0.apk' | sha256sum -c -
sudo apk add ./snapper-0.13.1-r0.apk; and sudo apk add snapper=0.13.1-r0; and grep '^snapper' /etc/apk/world
sudo install -m 600 snapper-0.13.1-r0.apk /root/; and rm snapper-0.13.1-r0.apk; and snapper --version
```

`setpriv --version` names util-linux. `sha256sum` prints `OK`; anything else, stop. `apk add`
refuses a file whose signature no key in `/etc/apk/keys` made; never pass it
`--allow-untrusted`. The world line reads `snapper=0.13.1-r0`. The copy in `/root` is for a
reinstall: edge drops a version when it builds the next.

```fish
# on zero: the mirror user, its home and .ssh root's; BusyBox locks the account with !, which sshd refuses a key for, so * replaces it: no password, not locked
sudo addgroup -S mirror; and sudo adduser -S -D -H -h /home/mirror -s /bin/sh -G mirror mirror
sudo sed -i 's/^mirror:![^:]*:/mirror:*:/' /etc/shadow; and sudo install -d -m 755 /home/mirror /home/mirror/.ssh
sudo grep '^mirror:' /etc/shadow | cut -d: -f1,2; getent passwd mirror
```

The shadow line reads `mirror:*`; the passwd line ends `/home/mirror:/bin/sh`. A real shell,
because sshd runs a forced command through the user's shell.

```fish
# on the phone: make zero's restore key if it has none, and print it, zero's address and zero's host key for three's files
cd ~/infra/ansible; and ansible-playbook playbooks/server-create-restore-key.yml -e target=zero -K
```

Send the infra agent what it prints. Then, once `three`'s key is
made and committed into `mirror-authorized-keys` (`hosts/three/leap/README.md` § The
backup), and after the move, each file with a dry run first:

```fish
# on zero: install the backup's files; each dry run shows a new file, then --commit writes it
sudo install -d -m 755 /etc/snapper/configs
cd ~/infra; and git pull --ff-only
for f in snapper-sysconfig snapper-config-immich sudoers-mirror rsyncd-mirror.conf mirror-authorized-keys snapper-immich
    bin/install-system-file $f --new; and sudo bin/install-system-file $f --new --commit --allow-content-change; or break
end
```

`sudoers-mirror` is checked by `visudo` before it is written: a bad file in `/etc/sudoers.d`
stops sudo altogether. Then the first snapshot, by hand, and the list:

```fish
# on zero: the first snapshot, as the hourly cron will take it, then snapper's list of them
sudo /etc/periodic/hourly/snapper-immich; and sudo snapper --no-dbus -c immich list
```

It lists snapshot 0, `current`, and 1, `timeline`. `three`'s first pull is
`hosts/three/leap/README.md`'s. Once it has worked, the push key goes:
`sudo rm /root/.ssh/mirror-backup /root/.ssh/mirror-backup.pub`.

**Checks:** `sudo snapper --no-dbus -c immich list` gains one snapshot an hour;
`grep autodefrag /proc/mounts` prints nothing (the move's remount drops it);
`rc-update show | grep -w dbus` prints nothing.

**Way back:** delete the six files the loop installed, the mirror user (`sudo deluser
mirror`) and snapper (`sudo apk del snapper`); the snapshots stay until `sudo btrfs
subvolume delete` takes them, and cost only what changed since each.

### A restore

From `zero`, as root, with the restore key, which reads `zero`'s backups on `three` and
writes nothing there. `sudo snapper --no-dbus -c received-immich list` on `three` gives each
of `three`'s snapshots and its date; its description names the `zero` snapshot it pulled.
Into a new directory, never over `/media/immich` itself:

```fish
# on zero: read three's snapshot N of zero's Immich back, with real owners and modes; put the snapshot's number in place of N
sudo rsync -aHAX --numeric-ids --exclude=/.snapshots -e 'ssh -i /root/.ssh/restore' restore@100.101.45.78::backups/immich/current/.snapshots/N/snapshot/ /media/immich/restore-N/
```

The first connection asks to accept `three`'s host key; its fingerprint is the one
`make-stick` printed for `three`. The module sends the owners and modes the pull kept, and
the symlinks as `zero` had them. `data/thumbs` and `data/encoded-video` come back empty:
Immich regenerates them, after an empty `.immich` file is put in each (its folder check).
A single file is the same command with its path after `snapshot/`.

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

# the test: 256M, no swap, no soft limit in the way, and the kill counter before
echo max | sudo tee /sys/fs/cgroup/devpool/memory.high
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

## Tailscale

zero's second way in, Tailscale's own static arm64 build: `tailscaled` in
`/usr/local/sbin`, `tailscale` in `/usr/local/bin`, run by the tracked service
`tailscaled`. It joins with `--accept-dns=false`, so zero keeps its own resolver
(`docs/decisions.md`). **The pin, the version and its SHA-256, is `tailscale_static_*` in
[`ansible/group_vars/fleet.yml`](../../../ansible/group_vars/fleet.yml)**, and nowhere
else. `ansible/playbooks/server-install-tailscale.yml` installs it, this service and the
join; **not installed yet**, the first run is
[`plans/visit-runbook.md`](../../../plans/visit-runbook.md) § Before the visit, step 3.

Moving it, at the monthly update and sooner for a security fix in a Tailscale bulletin,
is a commit to that file, the version and the SHA-256 from the `.sha256` beside the
tarball on `https://pkgs.tailscale.com/stable/`, then the same play from the phone:

```fish
# on the phone: move zero to the Tailscale pin in group_vars, keeping the previous binaries, and restart tailscaled
cd ~/infra/ansible; and ansible-playbook playbooks/server-install-tailscale.yml -e target=zero -K
```

It keeps the binaries it replaces as `tailscaled.previous` and `tailscale.previous` beside
them, and restarts `tailscaled` only when the binary moved. It reaches zero through the
tunnel, never the tailnet it restarts, and refuses to restart when it came in over the
tailnet. Going back is the previous binaries by hand, then the pin moved back in a commit,
or the next run moves forward again:

```fish
# on zero: go back to the previous Tailscale binaries and start tailscaled on them
sudo rc-service tailscaled stop; and sudo cp -p /usr/local/sbin/tailscaled.previous /usr/local/sbin/tailscaled; and sudo cp -p /usr/local/bin/tailscale.previous /usr/local/bin/tailscale; and sudo rc-service tailscaled start; and tailscale version
```

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
