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
| `fstab` | `/etc/fstab` | All three `/media/*` entries carry `nofail`, so a missing array can never stall boot. A fourth, `/var/lib/docker` on the SSD's `sda2` (btrfs, `compress=zstd:1`), carries it too, and its bare mountpoint is immutable like theirs; installed 2026-10-26 ([`docs/decisions.md`](../../../docs/decisions.md)). No array line carries `autodefrag` since 2026-11-19: it unshares the blocks snapshots share, and btrfs applies it to the whole filesystem, so it leaves every line or none ([`docs/decisions.md`](../../../docs/decisions.md) § The pull, as built). **Installed 2026-11-20** at the move, which also replaced the two Immich lines with one `/media/immich` line, `subvolid=281` ([`plans/visit-runbook.md`](../../../plans/visit-runbook.md) § What the visit did). |
| `bcache-register` | `/etc/init.d/bcache-register` | The array is btrfs RAID1 across **two** bcache devices; both must assemble before it can mount rw. This registers them and waits, bounded to 30s, then **always exits 0** — a failure here must never stop the boot. Since 2026-11-19 in the repo it also runs `before dmcrypt btrfs-scan`, for the encrypted member below; installed 2026-11-20 at the disk swap, with the new disk's UUID in place of `sdb`'s. |
| `dmcrypt` | `/etc/conf.d/dmcrypt` | Opens the array's encrypted member, `data-4`, at boot with the key file `/etc/keys/data.key`, so a boot needs nobody: encryption with protection off ([`docs/decisions.md`](../../../docs/decisions.md) § *`zero`'s encrypted member*). Its `rc_after`/`rc_before` lines put it after `bcache-register` and `modules` and before `btrfs-scan` and `localmount`. **Installed 2026-11-20** at the disk swap ([`docs/decisions.md`](../../../docs/decisions.md) § *`zero`'s encrypted member*), in the boot runlevel; the unattended reboot that day opened `data-4` with nobody there. Needs `cryptsetup cryptsetup-openrc`, installed then. |
| `dm-crypt.conf` | `/etc/modules-load.d/dm-crypt.conf` | Loads `dm-crypt`, and `dm-mod` with it, before `dmcrypt` runs: neither is built into `linux-rpi`. The cipher's modules load by algorithm name. **Installed 2026-11-20**, with `dmcrypt`. |
| `cloudflared` | `/etc/init.d/cloudflared` | The tunnel — the remote way in. Only trackable since Aug 2026: it previously carried the tunnel token inline, so committing it would have committed a secret. **Since 2026-08-23 it carries no secret at all** — `command_args` is `--autoupdate-freq 240h0m0s --config /etc/cloudflared/config.yml tunnel run`, and the tunnel credentials file is 0600. It is hand-written, not packaged: `docs/host-setup.md` installs the binary from GitHub, so Alpine ships no init script for it. It logged nowhere until 2026-08-23: `stdout_log`/`stderr_log` are not variables `supervise-daemon` reads, and it now uses `output_logger`/`error_logger` — see phase 2f. |
| `zram-swap` | `/etc/init.d/zram-swap` | Compressed swap in RAM ahead of the SSD swap partition, 2 GiB zstd at priority 100. **Installed 2026-10-26**: `/proc/swaps` lists `/dev/zram0` at 2 GiB, priority 100, `[zstd]`; in the default runlevel, owner-reported; [`docs/decisions.md`](../../../docs/decisions.md) § *Zram swap on `zero`* says why. Not boot-critical: a failed start leaves the SSD swap as it was. |
| `devpool` | `/etc/init.d/devpool` | The dev containers' one memory limit: cgroup v2 group `/sys/fs/cgroup/devpool`, 2048M soft and 2560M hard RAM, 6G swap (the owner's, 2026-10-27: reclaim early, kill only at the hard line, and let zram and the SSD swap both be used), named by `dev/compose.yaml` as each dev container's `cgroup_parent` once `DEV_CGROUP_PARENT=/devpool`. **Written 2026-10-27, not installed**: install and proof below. Not boot-critical. |
| `cloudflared-config.yml` | `/etc/cloudflared/config.yml` | The tunnel's ingress, moved off Cloudflare on 2026-08-23. Eight hostnames, and **the order is behaviour** — cloudflared matches first-rule-wins. This file is now the authoritative record of what zero serves; the dashboard's copy is ignored. See [`../../../docs/cloudflare.md`](../../../docs/cloudflare.md). |
| `tailscaled` | `/etc/init.d/tailscaled` | zero's second way in, and the backup's path to `three`: Tailscale's static arm64 build in `/usr/local`, since Tailscale's repo has nothing for Alpine and Alpine's package lacked the TS-2026-013 fix on 2026-11-03. Installed and moved by `server-install-tailscale.yml`, with the binaries at the pin in `ansible/group_vars/fleet.yml` (§ Tailscale, below). **Not installed yet.** |
| `snapper-config-immich` | `/etc/snapper/configs/immich` | snapper's config for `/media/immich`: hourly snapshots kept 24 hours, daily ones 7 days, the owner's own kept 10 deep; root alone; no qgroups (§ The backup). **Not installed**: after the move. |
| `snapper-sysconfig` | `/etc/snapper/snapper` | `SNAPPER_CONFIGS=""`, as the package ships it, so the package's own hourly script, which needs D-Bus, does nothing. **Not installed**. |
| `snapper-immich` | `/etc/periodic/hourly/snapper-immich` | The hourly snapshot and its cleanup, `snapper --no-dbus`, under `flock` (BusyBox's applet). **Not installed**: after the move, since it refuses while `/media/immich` is not mounted. |
| `sudoers-backup` | `/etc/sudoers.d/backup` | Lets the `backup` user run, as root, exactly one command: `setpriv` dropping back to `backup` with `CAP_DAC_READ_SEARCH` alone, then rsync's read-only daemon. `install-system-file` runs `visudo -cf` on it before writing. **Not installed**. |
| `rsyncd-backup.conf` | `/etc/rsyncd-backup.conf` | That daemon's one module, `snapshots`, read-only, over `/media/immich/.snapshots`. **Not installed**. |
| `backup-authorized-keys` | `/home/backup/.ssh/authorized_keys` | `three`'s pull key: `restrict`, only from `three`'s tailnet address, forced to the daemon above through sudo. Holds a placeholder until the owner makes the key on `three`. **Not installed**. |
| `backup-age-check` | `/etc/periodic/daily/backup-age-check` | **Not used, and not to be installed.** It read the push's `last-success`, and the push is gone: with the pull, `zero` never learns whether a pull succeeded. The owner deferred the alert to a dead man's switch for the whole fleet, designed separately; this file and `server-store-backup-ntfy-url.yml` stay until that design says whether it reuses them. Named `mirror-backup-age-check` until 2026-11-20; the ntfy URL it reads moves from `/var/lib/mirror-backup` to `/var/lib/backup-alert` (§ The install, below). |

**The mountpoints are `chattr +i`.** That is the actual protection against a failed
mount silently destroying the Immich library, and it is not visible in any file here.
`sudo bin/check-mount-guards` verifies it — including attempting a real write rather
than trusting the flag. Read
[`../../../docs/recovery.md`](../../../docs/recovery.md) before touching a bare
mountpoint, or you will get `Permission denied` as root and not know why.

## The backup

`three` pulls `zero`'s backup ([`docs/decisions.md`](../../../docs/decisions.md)
§ *`zero`'s backup is pulled by rsync from snapshots*).
`zero` takes a read-only snapper snapshot of `/media/immich`, the library in `data/` and
Postgres in `db/`, at the top of each hour, and keeps 24 hourly and 7 daily ones in
`/media/immich/.snapshots/<N>/snapshot`. Daily at 01:00 UTC `three` logs in as `backup`,
with a key that runs nothing but a read-only rsync daemon, and copies the newest finished
one. Nothing on `zero` pushes, and nothing on `zero` runs as root for it but the instant
`setpriv` takes to drop to `backup`.

**snapper is from Alpine's edge/testing**, `snapper-0.13.1-r0`, the only Alpine package of
it, installed once from the file and pinned in apk's world, so no `apk upgrade` moves it. It
is not upgraded until `zero` moves to Leap, where snapper is native and this config carries
over. Revisit at Alpine 3.25: it links Boost 1.84 and other libraries of the release it was
built against, and a release that moves one breaks it. It runs with `--no-dbus` everywhere:
apk installs `dbus` as a dependency, and no runlevel starts it, which is how it stays
(installing a tool is not enabling it, CLAUDE.md § Landmines). `flock` in the hourly script
is BusyBox's applet, in Alpine's BusyBox since long before 3.24 (its `busyboxconfig` sets
`CONFIG_FLOCK=y`). On `zero`, on 2026-11-19, `command -v flock` read `/usr/bin/flock` and
`/bin/setpriv --version` util-linux 2.42.3.

**setpriv is util-linux's**, from Alpine's `setpriv` package, which installs `/bin/setpriv`
over BusyBox's applet of that name. BusyBox's has no `--reuid`, so the forced command would
fail with it, and the pull with it.

`.github/workflows/alpine-sim.yml` runs the install below on Alpine 3.24 arm64, `zero`'s
release and architecture, and `microos-sim.yml`'s `three` job runs `zero`'s side as an
Alpine container for `three` to pull from.

### The install, owner-run

**Done on 2026-11-19:** the packages block and the user block below, by the owner, as
written; the old `mirror` user, made first, removed. **The rest done on 2026-11-20**, after
the move: the restore key, the six files, the first snapshot and the ntfy directory's move,
with `autodefrag` dropped by `sudo mount -o remount,noautodefrag /dev/bcache0 /media/immich`
(BusyBox's `mount`, given the mountpoint alone, does not find it in `/proc/mounts`).

The steps after the move need `/media/immich` and its `.snapshots`, which the move made on
2026-11-20 ([`plans/visit-runbook.md`](../../../plans/visit-runbook.md) § What the visit
did). After `ssh zero`, in fish:

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
# on zero: zero's backup user, its home and .ssh root's; BusyBox locks the account with !, which sshd refuses a key for, so * replaces it: no password, not locked
sudo addgroup -S backup; and sudo adduser -S -D -H -h /home/backup -s /bin/sh -G backup backup
sudo sed -i 's/^backup:![^:]*:/backup:*:/' /etc/shadow; and sudo install -d -m 755 /home/backup /home/backup/.ssh
sudo grep '^backup:' /etc/shadow | cut -d: -f1,2; getent passwd backup
```

The user is `backup`, as on `three`, not `mirror`, which reads as RAID (the owner). The
shadow line reads `backup:*`; the passwd line ends `/home/backup:/bin/sh`. A real shell,
because sshd runs a forced command through the user's shell.

```fish
# on the phone: make zero's restore key if it has none, and print it, zero's address and zero's host key for three's files
cd ~/infra/ansible; and ansible-playbook playbooks/server-create-restore-key.yml -e target=zero -K
```

Send the infra agent what it prints. Then, once `three`'s key is
made and committed into `backup-authorized-keys` (`hosts/three/leap/README.md` § The
backup), and after the move, each file with a dry run first:

```fish
# on zero: install the backup's files; each dry run shows a new file, then --commit writes it
sudo install -d -m 755 /etc/snapper/configs
cd ~/infra; and git pull --ff-only
for f in snapper-sysconfig snapper-config-immich sudoers-backup rsyncd-backup.conf backup-authorized-keys snapper-immich
    bin/install-system-file $f --new; and sudo bin/install-system-file $f --new --commit --allow-content-change; or break
end
```

`sudoers-backup` is checked by `visudo` before it is written: a bad file in `/etc/sudoers.d`
stops sudo altogether. Then the first snapshot, by hand, and the list:

```fish
# on zero: the first snapshot, as the hourly cron will take it, then snapper's list of them
sudo /etc/periodic/hourly/snapper-immich; and sudo snapper --no-dbus -c immich list
```

It lists snapshot 0, `current`, and 1, `timeline`. `three`'s first pull is
`hosts/three/leap/README.md`'s. Once it has worked, the push key goes:
`sudo rm /root/.ssh/mirror-backup /root/.ssh/mirror-backup.pub`, **done on 2026-11-20**, after
the first pull.

The ntfy URL that `server-store-backup-ntfy-url.yml` stored for the push's alert is in
`/var/lib/mirror-backup`, a name from before the rename (`docs/decisions.md` § *The backup's
names and layout on `three`*). It moves to `/var/lib/backup-alert`, where the play and
`backup-age-check` now look, whenever is convenient; nothing reads it until the fleet's
dead man's switch is designed:

```fish
# on zero: move the stored ntfy URL's directory to its new name, only if the old one exists and the new one does not; it lists names and modes, never the URL
sudo test -d /var/lib/mirror-backup; and sudo test ! -e /var/lib/backup-alert; and sudo mv /var/lib/mirror-backup /var/lib/backup-alert; and sudo ls -la /var/lib/backup-alert
```

The listing shows the directory root's at `drwx------` and `ntfy-url` root's at
`-rw-------`. If it prints nothing, one of the two tests failed and nothing moved: `sudo ls
-la /var/lib/mirror-backup /var/lib/backup-alert` says which. Way back: `sudo mv
/var/lib/backup-alert /var/lib/mirror-backup`.

**Checks:** `rc-service crond status` says `started`, and `rc-update show | grep -w crond`
names a runlevel, since every snapshot waits on root's cron; then `sudo snapper --no-dbus -c
immich list` gains one snapshot an hour;
`grep autodefrag /proc/mounts` prints nothing (the move's remount drops it);
`rc-update show | grep -w dbus` prints nothing.

**Way back:** delete the six files the loop installed, zero's backup user (`sudo deluser backup`) and snapper (`sudo apk del snapper`); the snapshots stay until `sudo btrfs
subvolume delete` takes them, and cost only what changed since each.

### A restore

From `zero`, as root, with the restore key, which reads `zero`'s backups on `three` and
writes nothing there. `sudo snapper --no-dbus -c received-immich list` on `three` gives each
of `three`'s snapshots and its date; its description names the `zero` snapshot it pulled.
Into a new directory, never over `/media/immich` itself:

```fish
# on zero: read three's snapshot N of zero's Immich back, with real owners and modes; put the snapshot's number in place of N
sudo rsync -aHAX --no-D --chmod=ug-s --numeric-ids --exclude=/.snapshots -e 'ssh -i /root/.ssh/restore' restore@100.101.45.78::immich/current/.snapshots/N/snapshot/ /media/immich/restore-N/
```

The first connection asks to accept `three`'s host key; its fingerprint is the one
`make-stick` printed for `three`. The module sends the owners and modes the pull kept, and
the symlinks as `zero` had them. It takes no device file and no setuid or setgid bit
(`--no-D --chmod=ug-s`): Immich has none, and the module's `fake super` would make whatever
`three`'s copy records into a real one on `zero`, as root. `data/thumbs` and `data/encoded-video` come back empty:
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
join; installed on 2026-11-18 by that play, from the phone.

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

**By hand, if the play cannot run**, after `ssh zero`, with the version and SHA-256 from
`ansible/group_vars/fleet.yml` in place of the placeholders. Go on past the first block
only if it prints `absent`, and open the URL the last line prints.

```fish
# on zero, by hand: check Alpine's own tailscale is absent; go on only if this prints "absent"
apk info -e tailscale; and echo 'STOP: Alpine tailscale is installed'; or echo absent
```

```fish
# on zero, by hand: install the pinned static build and the tracked service, start it, and join keeping zero's resolver
set v VERSION; set sum PASTE_SHA256_HERE
cd /tmp; curl -fLO https://pkgs.tailscale.com/stable/tailscale_{$v}_arm64.tgz
echo "$sum  tailscale_"$v"_arm64.tgz" | sha256sum -c -; and tar -xzf tailscale_{$v}_arm64.tgz; and sudo install -D -m 755 tailscale_{$v}_arm64/tailscaled /usr/local/sbin/tailscaled; and sudo install -D -m 755 tailscale_{$v}_arm64/tailscale /usr/local/bin/tailscale
rm -rf /tmp/tailscale_{$v}_arm64 /tmp/tailscale_{$v}_arm64.tgz
cd ~/infra; and git pull --ff-only; and sudo bin/install-system-file tailscaled --commit --allow-content-change --new
sudo rc-update add tailscaled default; and sudo rc-service tailscaled start
cat /etc/resolv.conf; sudo tailscale up --advertise-tags=tag:fleet --accept-dns=false; cat /etc/resolv.conf
```

## The encrypted member

From the disk swap on, the array's devid 4 is the new WD Red Plus, layered disk, bcache
backing device, LUKS2 (`data-luks-4`, Adiantum, as on `three`), btrfs. The WD Elements disk,
devid 3, stays plain until it is replaced the same way. `/etc/init.d/dmcrypt` opens
`data-4` at boot with `/etc/keys/data.key`, root's, 0400, on the SD card, in the boot
runlevel after `bcache-register` and before `btrfs-scan`. The disk also opens with the
owner's passphrase, keyslot 1, kept in the password manager.

`install-system-file dmcrypt` checks the entry before it writes: no placeholder, a `key=`
on every entry (one without would make the boot ask at the console and wait), the key
file root's alone, `findfs` resolving the `source=` as dmcrypt does, and `cryptsetup open
--test-passphrase` opening it with the key file. `sim/alpine/run-dmcrypt.sh` calibrates
each of those against a real LUKS2 volume.

**If the array is not mounted after a boot.** The box still boots and ssh answers: no
service needs dmcrypt, the `/media` entries carry `nofail`, and the bare mountpoints are
immutable. If ssh does not answer, the same blocks run at the console. First, what is
there:

```fish
# the array is not mounted: read the bcache devices, the mappings, dmcrypt's state and the kernel's lines
ls /dev/bcache* /dev/mapper; rc-service dmcrypt status
sudo dmesg | grep -iE 'bcache|crypt|btrfs' | tail -n 30
```

Two bcache devices should be listed. If one is missing, offer every disk and partition to
bcache; one without a bcache superblock, or in use, is refused with an error, harmlessly:

```fish
# a bcache device is missing: offer every sd disk and partition to bcache by hand
for x in /dev/(ls /sys/class/block | string match -r '^sd[a-z]+[0-9]*$'); echo $x | sudo tee /sys/fs/bcache/register; end; sleep 3; ls /dev/bcache*
```

If `/dev/mapper/data-4` is missing, open it by hand, with the key file, and with the
passphrase if the key file fails. The source is read from the installed entry:

```fish
# data-4 is not open: open it with the key file, or else with the passphrase
set l (sudo findfs (sed -n "s/^source='\(.*\)'\$/\1/p" /etc/conf.d/dmcrypt)); echo "LUKS device: $l"
test -n "$l"; and begin; sudo cryptsetup open --key-file /etc/keys/data.key $l data-4; or sudo cryptsetup open $l data-4; end
```

Then register both members with btrfs, mount the fstab's entries, and cycle the two
deployments that use the array, so their containers see the mounts rather than the bare
directories:

```fish
# data-4 is open: scan, mount, and cycle immich and syncthing
sudo btrfs device scan; and sudo mount -a; and grep ' btrfs ' /proc/mounts | cut -d' ' -f1,2
cd ~/infra/hosts/zero/immich; and sudo docker compose stop; and sudo docker compose start
cd ~/infra/hosts/zero/syncthing; and sudo docker compose stop; and sudo docker compose start
```

A boot that needed any of this is a fault in the order or in a file, and is filed and fixed
before the next unattended reboot. `mount -o degraded` is the last resort, only when
neither key opens `data-4` and Immich must serve before a fix: the array then runs on the
WD Elements disk alone, what it writes lands in chunks that are not mirrored until a
balance and a scrub after a second device returns, and a degraded mount hides the fault.
`-o degraded,ro` is enough to copy something off.

**Turning protection on** is in the phase table of
[`docs/management-plane.md`](../../../docs/management-plane.md): the entry here comes out
first, then the key file's keyslot is killed, and the unlock becomes the manual one below.

## When `crypttab` lands here

**On Alpine, the encrypted member above is opened by a key file for now**, the owner's
decision of 2026-11-19 to encrypt with protection off; what follows is the design once
protection is on, written for systemd's `crypttab` on the move to Leap.

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
  no keyfile in this design once protection is on; until then `/etc/keys/data.key` lives
  on `zero` alone, and the ignore stays as a backstop.
- Because only the data disk is encrypted and not root, none of this needs initramfs
  networking and `/boot/cmdline.txt` is never touched.
