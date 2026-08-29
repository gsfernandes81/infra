# hosts/two/system

**Raspberry Pi Model B Plus Rev 1.2, `armv6l`, 512 MB** (confirmed Aug 2026) —
single-core ARM1176 at 700 MHz, 100 Mbit ethernet sharing a USB 2.0 bus, no crypto
acceleration. `MemTotal` is 486 272 kB, so **~475 MB usable**, not the ~490 MB an
earlier note here and in `docs/host-setup.md` claimed. Alpine **3.24.1** (not 3.23 —
package names moved between the two; see `hosts/two/setup/README.md` step 1).

`two` does **not** join the MicroOS fleet — its armv6 was the only thing that would
have forced the whole fleet onto Debian, and armv6 also rules out Claude Code (arm64
and x86-64 only). It is kept, powered on, for a different job.

## What changed, Aug 2026

`two` now also runs the **destiny-director test bot** — see
[`deployments/destiny-director/`](../../../deployments/destiny-director/), reachable
here as [`hosts/two/destiny-director`](../destiny-director). That is a real change to
this box's brief, and the tension with the lifeboat role is recorded in
[`docs/decisions.md`](../../../docs/decisions.md).

With it come three host changes:

- **Docker and containerd are removed**, and **rootless podman + podman-compose**
  replace them.
- **`python3` is now installed** as a dependency of `podman-compose` 1.6.0. That
  removes the stated objection to tracking `/etc` files here (see below): the
  interpreter `bin/check-system-drift` needs is no longer a cost this box would pay
  only for the checker's sake.
- **An unprivileged `claude` account** deploys the stack, with an ordinary SSH key and
  plain `podman-compose`. This reverses the "no new user on `two`" decision — see
  [`docs/decisions.md`](../../../docs/decisions.md) and the section below.

The build is [`../setup/README.md`](../setup/README.md), a numbered instruction manual.
It replaced an 1800-line `root-setup.sh`.

> ~~**Status: not applied as of 2026-08-06.**~~ **Applied — the box matches those
> bullets.** Docker and containerd are gone (`ansible/host_vars/two.yml` declares podman,
> crun, conmon, netavark and says docker "must never get back"), `python3` is present and
> pinned fleet-wide in `group_vars/fleet.yml`, and the unprivileged `claude` account is
> the documented way in (`README.md`). Docker removal was opt-in behind
> `DD_REMOVE_DOCKER=1` as a separate second run; it happened.
>
> This banner said "nothing in it has been run on the box" for 23 days after the box
> stopped matching it, on the page that tells you what `two` is.

## Its job: the lifeboat

Five jobs, all tiny, all suited to hardware that cannot do anything demanding:

1. **Serial console** to `zero` and `one` — a login prompt when a box has dropped to
   emergency mode with no network.
2. **Power-cycle authority** via a smart plug.
3. **Dead-man's switch** — reports the other hosts' health outward, because a watchdog
   running on the box being watched is not a watchdog.
4. **Boot-integrity monitoring** — boot time, `/boot` hash, block-device inventory.
   This is what makes remote unlocking of `zero`'s encrypted volume defensible: it
   turns "I have no idea whether anyone touched it" into a decision you can actually
   make.
5. **Independent access path** — Tailscale or WireGuard, separate from cloudflared.

The full case, and the trust logic behind job 4, is in
[`docs/roadmap.md`](../../../docs/roadmap.md#5-two--keep-it-as-the-lifeboat).

**Stays on Alpine. It is a `sys` install today, not diskless** — root on
`/dev/mmcblk0p2`, 29 G with 27 G free (verified over SSH, Aug 2026). This section
previously read as though diskless were already done; it is not, and
[`docs/host-setup.md`](../../../docs/host-setup.md) had it right all along.

Diskless — running from RAM with the SD card read-only, committed via `lbu commit` —
remains the argument for the lifeboat: the box whose purpose is surviving other boxes'
failures should be the one least able to die of SD-card corruption. But it is now in
tension with what else is on here. A 512 MB board cannot hold its OS image in RAM
*and* Postgres's buffers, and an unsynced diskless system loses Postgres's data
directory on power loss. Whichever way that is settled, settle it in
[`docs/decisions.md`](../../../docs/decisions.md) rather than by drifting.

**Swap: there is none.** Verified Aug 2026 — no zram, no swap file, no swap partition.
`docs/host-setup.md` said `two` runs zram; it does not, and Alpine's `zram-init`
package cannot be enabled either of the two ways that doc described. There is no OpenRC
service and no `/etc/conf.d/zram-init` — both are Gentoo's packaging — **and the
invocation it gave would not have run either**: it passed `-s 1`, which is not in that
script's `getopts`. The real `armhf` binary answers `Illegal option -s` and exits, so
the documented command failed while both files went on describing `two` as running zram.
The verified line is `zram-init -d 0 -p 100 256`. `../setup/README.md` step 3 runs that, **live**,
and it does not survive a reboot, because persisting it means boot-path code on the
lifeboat box.

Nothing household-critical goes here: no DNS, no backups, no log sink. A test bot is
not household-critical either — but it does put a continuous Postgres write load on the
SD card, which is the cost worth watching. (The board is a decade old; the card is not —
this line previously said otherwise. See docs/decisions.md.)

## Tang is not currently possible here

Alpine packages **neither `tang` nor `clevis`** — checked Aug 2026 across `main`,
`community` and `edge`, on `armhf`, `armv7` and `aarch64`. Only `jose`, their
dependency, is present. So tang cannot be `apk add`-ed on this box, and it would mean
either building from source on a 700 MHz CPU or switching to Raspberry Pi OS, which
does package both for armhf.

That decision is on hold anyway, and for a better reason: a tang server sitting beside
`zero` doesn't protect against theft, it just means the thief takes two boxes instead
of one. See the roadmap before doing anything here.

## Tracked `/etc` copies

~~**Still none.**~~ **Three, since 2026-08-23**, each carrying an `infra-` header naming
where it installs:

| file | installs at |
|---|---|
| `cloudflared` | `/etc/init.d/cloudflared` |
| `cloudflared-config.yml` | `/etc/cloudflared/config.yml` |
| `sshd-infra.conf` | sshd's drop-in directory |

`bin/install-system-file` writes them and `bin/check-system-drift` reports on them, on
this box as on the others — 2g's cutover runs the former here. This section said
"still none" until 2026-08-29, which would tell a reader nothing on `two` is installable
from the repo.

There is no longer an installed *executable* to track. `/usr/local/bin/dd-ctl` used to be
the obvious candidate; it is gone along with the forced command it implemented.

What is worth checking by hand on this box now is smaller, and none of it is a hash:

```sh
id claude                                  # expect no wheel
# NOTE: /srv/infra does not exist on this box — the clone is ~gavin/infra. The setup
# README documents the intent; the box went the other way. Checked 2026-08-29.
stat -c '%U:%G %a' ~gavin/infra            # the clone, wherever it really is
stat -c '%U:%G %a' ~gavin/infra/deployments/destiny-director/.env   # expect 640
iptables -S OUTPUT | grep -c REJECT        # expect the LAN rules, step 8
cat /etc/local.d/oom.start                 # cloudflared pinned to -1000
```

The files that mattered under the old design — `gavin`'s fish config and the four paths
around it — no longer decide anything. They were in the deploy key's TCB because sshd
runs a forced command as `$SHELL -c`, and `gavin`'s shell is fish; `claude`'s shell is
`/bin/sh` with an empty home, and there is no forced command to subvert.

## The deploy account

Deploys run as **`claude`**, an unprivileged account created for the purpose. Not in
`wheel`, `/bin/sh` login shell, empty home, its own subuid/subgid range. It holds an
ordinary SSH key — no forced command — and deploys with plain `podman-compose`.
[`../setup/README.md`](../setup/README.md) is the build.

**This replaced a restricted forced command** (`dd-ctl`, ~800 lines) that ran as `gavin`.
The reasoning for that design, and for reversing it, is in
[`docs/decisions.md`](../../../docs/decisions.md); the short version is that the
dispatcher was ~800 lines of shell whose correctness *was* the boundary, and only because
`gavin` is in `wheel`. Moving the deploy to an account that cannot become root replaces
all of it with uid separation the kernel enforces.

Three properties that used to be script-enforced are now enforced by the OS:

| Property | Was | Is |
|---|---|---|
| Cannot become root | the dispatcher never ran a shell | `claude` is not in `wheel` |
| Cannot choose the deployed image | verbs took no arguments | `/srv/infra` is operator-owned, group-readable; `claude` cannot write `compose.yaml` |
| The login shell is not in the TCB | it *was* — `gavin`'s fish config ran first | `claude`'s shell is `/bin/sh`, home empty |

The old key lived in the Claude Code cloud environment block as `DD_CTL_KEY_B64`. **That
block is not masked**, which was only acceptable while the key's entire reach was six
argument-less verbs. The current key reaches a shell, so it must **not** go there.

## The checkout is shared, and read-only to the deploy account

One clone, **documented as `/srv/infra` and actually at `~gavin/infra`** (checked 2026-08-29 — the intent below describes how it was meant to be built): `gavin:deploy`, dirs `2750`,
files `0640`. `gavin` pulls and edits; `claude` reads. That is what makes "the deploy
account cannot choose the image" a permission rather than a claim.

`.env` is `0640 gavin:deploy`, so **every member of `deploy` reads the test Discord
tokens, the Postgres password and the Bungie/Sheets keys**. That is `claude`, which needs
them to run the bots. Keep the group to those two.

## What the uid split does not cover

**Resource exhaustion.** Rootless podman under OpenRC has no cgroup delegation, so a
per-container memory limit is not merely unset — it is impossible. On 475 MB the OOM
killer is the only limiter, and the plausible victim is `cloudflared`, which is the only
way into this box. Mitigated from both ends rather than fixed:

- `cloudflared` is pinned to `oom_score_adj -1000` (`/etc/local.d/oom.start`).
- Everything `claude` starts from a login shell inherits `+500`; the bots raise
  themselves to 800 via `OOM_SCORE_ADJ` in `.env`.

Neither is a limit. Two concurrent deploys can still take the box down; do one at a time.

**The LAN.** A container running as `claude` can reach anything the Pi can. Closed with
iptables rather than a VLAN — egress to RFC1918 is rejected except the gateway, ingress
from the LAN is dropped. See [`../setup/README.md`](../setup/README.md) step 8. Note this
is the *only* thing standing between a container and the rest of the network; `two` sits
on the same wire as everything else.

**Prompt injection.** The account exists so an agent can deploy unattended. An agent
processes untrusted text — fetched pages, API responses, repository comments — and a full
shell is a much larger lever for that than six fixed verbs were. The uid split bounds
where a mistake lands; it does not reduce how likely one is.

**Named volumes.** `compose.yaml` uses only named volumes (`pgdata`,
`sshhostkeys_beacon`, `sshhostkeys_anchor`). This used to be enforced twice by the
dispatcher, because a bind mount under `$HOME` writes host files as the deploy user and a
mount over `~/.ssh` would let a container rewrite its own `authorized_keys`. With that
account unprivileged the blast radius is the account itself, so it is a convention again
— but keep it. The check that verified it was calibrated on 2026-08-06 against a running
container, which reported exactly one mount line and none of type `bind`.

**The moving tag, which was never about the dispatcher.** `compose.yaml` names a moving
branch tag, so anyone with push access to that branch decides what code runs on the next
deploy. That is the real trust boundary and it sits upstream of this repo entirely. See
[`docs/decisions.md`](../../../docs/decisions.md).

**Known gap, for when a tracked executable does land here:**
`bin/install-system-file`'s `validators_for()` keys on `live.parent == /etc/init.d` and
on the filename `fstab`, so an executable installing anywhere else would get **no**
post-install check — not even `sh -n`. Widening it is the right fix, but this repo's
own rule is to calibrate a new validator against known-good state first, and there is
currently no tracked file of that shape to calibrate against. Add the file and the
validator together.
