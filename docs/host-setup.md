# Building a host

Alpine on a Raspberry Pi, `sys` disk mode. Verified against `zero` (Alpine 3.24.1) on
2026-08-03. Only the parts you cannot read off the box are written down here.

`one` and `zero` are slated for [MicroOS](roadmap.md#3-opensuse-microos--the-target);
this is what they run today. `two` stays on Alpine.

## Install

`setup-alpine`, `sys` disk mode, headless overlay, **community repo enabled**, reboot.

`authorized_keys` goes in the FAT partition root for headless first boot — and must be
copied onto the installed system afterwards, because the overlay's copy does not
survive the switch to `sys` mode.

| File | What must be in it |
|---|---|
| `/boot/cmdline.txt` | `cgroup_memory=1 cgroup_enable=memory`, or Docker gets no memory limits |
| `/boot/config.txt` | `gpu_mem=16`, pairing with `raspberrypi-bootloader-cutdown` |
| `/etc/ssh/sshd_config` | no root login, no password auth, no empty passwords |
| `/etc/apk/repositories` | community uncommented |

`bin/check-boot-layout` checks the `/boot` question that matters later: whether it sits
on its own device, and so whether it can be swapped while the box runs.

## Packages

```sh
apk add fish htop nano sudo raspberrypi-bootloader-cutdown docs curl lsblk \
        smartmontools docker docker-cli-compose
apk add bcache-tools          # zero only — data array behind an SSD cache
```

**`two` takes the podman list instead**, not this one — and package names moved between
Alpine 3.23 and 3.24 (`shadow-uidmap` no longer exists; the `newuidmap`/`newgidmap`
binaries are in `shadow-subids`). Since `apk add` is atomic, one stale name aborts the
whole install. The verified 3.24 `armhf` list is in
[`../hosts/two/setup/root-setup.sh`](../hosts/two/setup/root-setup.sh) §3, with the
reasoning for each name.

`smartmontools` is **missing on `zero`** and belongs there: `smartctl -d sat` is how you
separate a failing disk from a flaky USB enclosure when btrfs reports corruption.

## sudo

```sh
addgroup gavin wheel          # NOT `addgroup wheel gavin` — busybox takes the user first
visudo                        # uncomment %wheel
```

`visudo` validates before saving. A syntax error written straight into `/etc/sudoers`
locks every account out of `sudo`, on a box you may be months from reaching.

A password is required; NOPASSWD and `gavin` in `docker` are both
[deliberately not done](roadmap.md#not-doing).

## klogd — on every host

```sh
rc-update add klogd boot
rc-service klogd start
grep -c 'kern\.' /var/log/messages     # non-zero = working
```

Alpine enables `syslog` but not `klogd`, and busybox syslogd does not read the kernel
ring buffer. Without klogd **no kernel message is ever written to disk** — it lives in
`dmesg` only, which the reboot you are diagnosing has already wiped. Both bcache boot
failures (January, and 2026-08-03) left no trace for this reason.

`boot`, not `default`: klogd declares `before net` and `networking` is in `boot`, so in
`default` it starts after the whole boot runlevel and misses the bcache, btrfs and USB
messages it exists to capture. `need logger` orders it after syslog. Nothing `need`s
klogd, so it cannot stall a boot.

`libcap` is absent, so the script's `capabilities="^cap_syslog"` is inert — fine while
`kernel.dmesg_restrict = 0`. Set `dmesg_restrict=1` and klogd goes quiet unless you
install `libcap`.

## zram — and what this section got wrong

`zero` has the RAM and does not run it.

**This section previously described Gentoo's packaging, not Alpine's.** Corrected
2026-08-06 against the real `zram-init-13.0.1-r2.apk` for `armhf`. Alpine's package
ships exactly two things — `/usr/sbin/zram-init`, a wrapper script you invoke by hand,
and `/etc/modprobe.d/zram.conf`. There is **no OpenRC service and no
`/etc/conf.d/zram-init`**; both are Gentoo's packaging of the same upstream. So
`rc-update add zram-init` fails with "service does not exist", and the instruction that
used to be here to edit `/etc/conf.d/zram-init` was editing a file nothing reads.

**`two` has no swap at all.** Verified over SSH, Aug 2026: no zram, no swap file, no
swap partition. The per-host table below said `two` runs zram; it does not, and never
did.

**`one` is still unverified** — unreachable on 2026-08-03 and not checked since.
Confirm before trusting anything here about it:

```sh
apk info -e zram-init && cat /proc/swaps && lsblk | grep zram
```

Enabling it is a live one-shot; there is no service to add:

```sh
zram-init -d 0 -s 1 -p 100 256      # 256 MB, one compression stream, priority 100
```

That does **not** survive a reboot, and persisting it means an OpenRC service — new
boot-path code, which [decisions.md](decisions.md) rejected on `two` for the same
reason it rejected the mount-guard service. `hosts/two/setup/root-setup.sh` §9 does the
live half and says so rather than implying persistence.

The tuning path is `/etc/sysctl.d/*.conf`. The original build note said
`/etc/sysctl.conf.d`, which does not exist on Alpine and silently does nothing — and
`two` has no `/etc/sysctl.d/*zram*` either, so there the tuning has never been applied
anywhere. `root-setup.sh` §9 writes `/etc/sysctl.d/60-zram.conf`.

## Docker — `one` and `zero`

```sh
rc-update add docker default
rc-update add cgroups default
service docker start
```

**Never remove `containerd` while a dependent is installed** — `docker-engine` and
`k3s` both hard-depend on the package, so `apk del containerd` on its own kills every
container at the next start. [CLAUDE.md](../CLAUDE.md) has the reasoning. Removing it
*in the same `apk del` transaction as every dependent*, after stopping the services, is
a different operation and is what `hosts/two/setup/root-setup.sh` §12 does; apk
resolves the order itself and containerd is never removed alone.

Docker's init declares only `need sysfs cgroups net`, so it starts whether or not
`/media/*` mounted. Put the mount guards in before running any stack that bind-mounts an
array: [recovery.md](recovery.md#-the-trap-that-silently-eats-data--and-the-flag-that-stops-it),
verified by `sudo bin/check-mount-guards`.

**`two` does not run Docker.** It runs rootless podman + podman-compose as `gavin`, and
Docker and containerd are removed from it — see
[decisions.md](decisions.md) and [`../hosts/two/setup/root-setup.sh`](../hosts/two/setup/root-setup.sh).
Nothing there is in the `docker` group and nothing starts at boot.

## `two` — the whole build, in one reviewable script

[`hosts/two/setup/root-setup.sh`](../hosts/two/setup/root-setup.sh) is the privileged
half of building `two` for the destiny-director test bot: packages, `dd-ctl` install,
the restricted SSH key, subuid/subgid, cgroup and `/boot` **verification only**, live
zram, and the opt-in Docker removal. It is mode 0644 and not in `bin/`, so it must be
invoked as `sh root-setup.sh` — which is also the only way that works, since `gavin`'s
login shell is fish and `ssh two 'snippet'` is executed by fish.

Run it once with no `DD_REMOVE_DOCKER` first and read its `CHANGED:` and `NOTES /
ACTION REQUIRED:` blocks; §12 prints what it *would* remove. Then re-run with
`DD_REMOVE_DOCKER=1`.

Two things in it that are load-bearing and easy to undo by accident:

- **`iptables` is installed in §3, before the removal in §12.** It is currently on `two`
  only as an auto-installed dependency of `docker-engine`/`k3s`, and `apk del` reclaims
  orphaned dependencies — so removing Docker would take `iptables` with it. netavark
  shells out to `iptables` to program the bridge network's rules, including inside a
  *rootless* netns, while **not** depending on the package. The stack would then have
  broken days later for a reason nobody would connect back to a Docker cleanup.
  Installing it first makes it a world member. Do not move §3 below §12.
- **`/usr/local/bin/dd-ctl` must stay a real root-owned file**, 0755, in a directory
  only root can write. See [`../hosts/two/system/README.md`](../hosts/two/system/README.md).

Two things it reports and refuses to fix, because `/boot` is the red line:

- `two`'s kernel cmdline carries **both `cgroup_disable=memory` and
  `cgroup_enable=memory`**. The enable is winning — the memory controller is live — but
  a boot line that argues with itself resolves by kernel parsing order rather than by
  intent. Clean it up by hand, on a day you can watch the reboot.
- `/etc/fstab` is tracked read-only and never generated on this fleet, so §11 prints its
  mount-option recommendation and writes nothing.

## cloudflared

```sh
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-aarch64 \
     -o /usr/bin/cloudflared && chmod +x /usr/bin/cloudflared
```

`aarch64` for `one` and `zero`; **`arm`** for `two`, which is armv6.

The init script is tracked at `hosts/<host>/system/cloudflared` — install it with
`bin/install-system-file cloudflared`. Not reproduced here, because a pasted copy drifts
from the real one.

> ⚠ **The token is in `command_args`, and that leaks it.** `supervise-daemon` logs its
> child's full command line to syslog at every boot, so the live token sits in
> `/var/log/messages` (mode 640 `root:wheel`) and its rotations, readable by anyone in
> `wheel`. Moving it to `/etc/conf.d/cloudflared` at mode 600 protected the file but not
> the argv. Fix is `TUNNEL_TOKEN` in the environment with `--token` dropped, bundled
> with a rotation in one restart. **Not applied on any host yet.** Rule for all three:
> secrets never go in `command_args`.

## Stacks

`deployments/<stack>/` is what a stack is, `hosts/<host>/` is where it runs,
`bin/compose <stack> up -d` starts it — see the [README](../README.md).

The torrents stack on `one` needs `/dev/net/tun` on the host, either via
`mknod /dev/net/tun c 10 200` or by loading `tun` from `/etc/modules-load.d/`. Read
[port-forwarding.md](port-forwarding.md) first: gluetun and qBittorrent must share one
network namespace or port forwarding breaks silently.

## Per host

| | `one` (Pi 4) | `two` (Pi 1 B+, armv6) | `zero` (Pi 5) |
|---|---|---|---|
| cloudflared build | `aarch64` | `arm` | `aarch64` |
| zram | intended, **unverified** | **no swap at all** (verified Aug 2026) | no |
| container runtime | docker | rootless podman + podman-compose | docker |
| bcache-tools | no | no | yes |
| Target OS | MicroOS | stays Alpine | MicroOS |

`two` is `sys` mode today — root on `/dev/mmcblk0p2`, 29 G with 27 G free, Alpine
3.24.1, ~475 MB usable RAM (all verified Aug 2026). Diskless is [planned, not
done](roadmap.md#5-two--keep-it-as-the-lifeboat), and now has a Postgres data directory
arguing against it; see [`../hosts/two/system/README.md`](../hosts/two/system/README.md).
After that switch every `/etc` change is lost on reboot unless `lbu commit`ed.
