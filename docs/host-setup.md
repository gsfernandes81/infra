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
Alpine 3.23 and 3.24: the `newuidmap`/`newgidmap` binaries were in `shadow-uidmap` and
are now in `shadow-subids`. **`shadow-uidmap` has not stopped existing**, which is what
this line used to claim. `shadow-subids` *provides* `shadow-uidmap=4.18.0-r1`, so
`apk add shadow-uidmap` still resolves and installs cleanly; the old name would have
worked. Write `shadow-subids` anyway — it is the real package, and it is what
`apk info -e` answers with — but not because the other name is fatal. It isn't, and an
invented reason is what gets copied into the next box's script. The verified 3.24
`armhf` list is in
[`../hosts/two/setup/README.md`](../hosts/two/setup/README.md) step 1, with the
reasoning for each name.

`smartmontools` is **installed on `zero`** — verified 2026-08-21 by a fleet-wide package
audit. This paragraph previously said it was missing and belonged there; that was already
untrue when written, and `hosts/zero/system/hw-inventory.toml` was the file that gave it
away, recording three real `smartctl -i -d sat` reads on 2026-08-04 which could not have
run without it. `smartctl -d sat` is how you separate a failing disk from a flaky USB
enclosure when btrfs reports corruption.

It is **absent on `two`, and stays that way**: that box's only drive is an SD card, which
reports no SMART at all, so the package would buy nothing and cost writes on the card the
whole lifeboat argument rests on.

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
zram-init -d 0 -p 100 256           # device 0, swap priority 100, 256 MB
```

**There is no `-s`.** This line used to read `zram-init -d 0 -s 1 -p 100 256`, with
`-s 1` glossed as "one compression stream, because there is one core". `-s` is not in
that script's `getopts`: the real `armhf` binary answers `Illegal option -s` and exits,
so every invocation documented here would have failed — while
both files went on to describe `two` as running zram. `-d 0 -p 100 256` is what was
verified to parse and reach `mkswap`/`swapon`. No `-a` either: the kernel default
(lzo-rle on 6.x) is the right pick on a CPU with no NEON, and naming an algorithm this
kernel may not have compiled in turns a cushion into an error.

That does **not** survive a reboot, and persisting it means an OpenRC service — new
boot-path code, which [decisions.md](decisions.md) rejected on `two` for the same
reason it rejected the mount-guard service. `hosts/two/setup/README.md` step 3 does the
live half and says so rather than implying persistence.

The tuning path is `/etc/sysctl.d/*.conf`. The original build note said
`/etc/sysctl.conf.d`, which does not exist on Alpine and silently does nothing — and
`two` has no `/etc/sysctl.d/*zram*` either, so there the tuning has never been applied
anywhere. `hosts/two/setup/README.md` step 3 writes `/etc/sysctl.d/60-zram.conf`.

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
a different operation; apk
resolves the order itself and containerd is never removed alone.

Docker's init declares only `need sysfs cgroups net`, so it starts whether or not
`/media/*` mounted. Put the mount guards in before running any stack that bind-mounts an
array: [recovery.md](recovery.md#-the-trap-that-silently-eats-data--and-the-flag-that-stops-it),
verified by `sudo bin/check-mount-guards`.

**`two` does not run Docker.** It runs rootless podman + podman-compose as `gavin`, and
Docker and containerd are removed from it — see
[decisions.md](decisions.md) and [`../hosts/two/setup/README.md`](../hosts/two/setup/README.md).
Nothing there is in the `docker` group and nothing starts at boot.

## `two` — the whole build

[`hosts/two/setup/README.md`](../hosts/two/setup/README.md) is the build of `two` for the
destiny-director test bot, as a numbered instruction manual: packages, kernel modules,
zram, the unprivileged deploy user, subuid/subgid, runtime directory and OOM priority,
firewall, the shared `/srv/infra` checkout, and SSH access. Follow it top to bottom.

It replaced an 1800-line `root-setup.sh` that did the same work with checks and a change
report. The script also generated a restricted SSH deploy key and installed `dd-ctl` as a
forced command; both are gone — the account that deploys is unprivileged now, so the
boundary is uid separation instead of a shell script, and the key is an ordinary one.

Two things from that script that are still load-bearing and easy to undo by accident:

- **Install `iptables` and `ca-certificates` explicitly**, before any `apk del` of
  Docker or k3s. Both are on `two` only as auto-installed dependencies of
  `docker-engine`/`k3s`, and `apk del` reclaims orphaned dependencies. netavark shells
  out to `iptables` to program the bridge network's rules, including inside a *rootless*
  netns, while **not** depending on the package; the stack would break days later for a
  reason nobody would connect back to a Docker cleanup. `ca-certificates` is worse,
  because it is the trust store `cloudflared` validates Cloudflare's edge against:
  losing it cuts **the only way into the box**. Naming both in an explicit `apk add`
  makes them world members that no reclaim can touch.
- **The `tun` module must be loaded and persisted.** Installing `passt` is not enough,
  and the failure is a long way from the cause: the container is created and then fails
  to start with `Failed to open() /dev/net/tun`.

Two things `/boot` — the red line — needs by hand, not by script:

- `two`'s kernel cmdline carries **both `cgroup_disable=memory` and
  `cgroup_enable=memory`**. The enable is winning — the memory controller is live — but
  a boot line that argues with itself resolves by kernel parsing order rather than by
  intent. Clean it up by hand, on a day you can watch the reboot.
- `/etc/fstab` is tracked read-only and never generated on this fleet.

## cloudflared

**Do not install it by hand any more.** Use
`ansible/playbooks/cloudflared-update.yml`, which picks the asset from the host's own
`uname -m`, verifies a SHA256 you supply, cycles the connector and rolls back a failure.
The reasons are below and they are not theoretical.

> ⚠ **What this section used to say could not work.** It gave
> `.../releases/latest/download/cloudflared-linux-aarch64`. **There is no `aarch64`
> asset** — Cloudflare publishes `arm64`, `arm`, `amd64`, `386`, `armhf`. With `-L` and
> no `-f`, curl follows GitHub's 404 and writes the error page over
> `/usr/bin/cloudflared`. So the documented install was never usable as written, which
> is the likeliest reason one working binary ended up copied to all three hosts instead.

> ⚠ **All three hosts run the 32-bit `arm` build, including the two arm64 ones.**
> Established 2026-08-23: identical SHA256 on `zero`, `one` and `two`, and `two` is
> `armv6l` — nothing but a 32-bit ARM binary executes on all three. `zero` and `one` are
> `aarch64` and have been running it for about six months.
>
> **Autoupdate could never have corrected it.** cloudflared updates itself with a build
> matching *its own* architecture, not the machine's, so the original mistake was
> self-perpetuating. Autoupdate was also demonstrably live — all three binaries were
> rewritten on 14–15 August, the day `2026.8.2` released — which meant a boot-path binary
> on the internet-facing box was being replaced with unverified bytes on a 24-hour cycle.
> It is now `--no-autoupdate` on all three.

The init script is tracked at `hosts/<host>/system/cloudflared` — install it with
`bin/install-system-file cloudflared`. Not reproduced here, because a pasted copy drifts
from the real one.

The token used to be in `command_args`, where `supervise-daemon` logged it to syslog at
every boot. **Fixed on all three, 2026-08-23**: there is no `--token` anywhere now. Each
host reads `/etc/cloudflared/<host>.json` at mode 600, named by a `--config` file that is
tracked. The rule that came out of it stands: **secrets never go in `command_args`.**

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
| cloudflared build | **`arm` — wrong**, should be `arm64` | `arm` ✅ | **`arm` — wrong**, should be `arm64` |
| zram | intended, **unverified** | **no swap at all** (verified Aug 2026) | no |
| container runtime | docker | rootless podman + podman-compose | docker |
| bcache-tools | no | no | yes |
| Target OS | MicroOS | stays Alpine | MicroOS |

`two` is `sys` mode today — root on `/dev/mmcblk0p2`, 29 G with 27 G free, Alpine
3.24.1, ~475 MB usable RAM (all verified Aug 2026). Diskless is [planned, not
done](roadmap.md#5-two--keep-it-as-the-lifeboat), and now has a Postgres data directory
arguing against it; see [`../hosts/two/system/README.md`](../hosts/two/system/README.md).
After that switch every `/etc` change is lost on reboot unless `lbu commit`ed.
