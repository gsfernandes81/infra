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

## zram — `one` and `two` only

`zero` has the RAM and does not run it. Config lives in `/etc/conf.d/zram-init` (all
`blck*` 4096, `blck0` swap at 75% of RAM) and `/etc/sysctl.d/zram.conf`.

**Unverified as of 2026-08-03** — both hosts were unreachable. Confirm before trusting:

```sh
apk info -e zram-init && cat /etc/conf.d/zram-init && lsblk | grep zram
```

The tuning path is `/etc/sysctl.d/*.conf`. The original build note said
`/etc/sysctl.conf.d`, which does not exist on Alpine and silently does nothing — worth
checking whether the tuning was ever actually applied.

## Docker

```sh
rc-update add docker default
rc-update add cgroups default
service docker start
```

**Never `apk del containerd`** — [CLAUDE.md](../CLAUDE.md) explains why the service is
removable but the package is not.

Docker's init declares only `need sysfs cgroups net`, so it starts whether or not
`/media/*` mounted. Put the mount guards in before running any stack that bind-mounts an
array: [recovery.md](recovery.md#-the-trap-that-silently-eats-data--and-the-flag-that-stops-it),
verified by `sudo bin/check-mount-guards`.

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
| zram | yes | yes | no |
| bcache-tools | no | no | yes |
| Target OS | MicroOS | stays Alpine | MicroOS |

`two` is `sys` mode today; diskless is [planned, not
done](roadmap.md#5-two--keep-it-as-the-lifeboat). After that switch every `/etc` change
is lost on reboot unless `lbu commit`ed.
