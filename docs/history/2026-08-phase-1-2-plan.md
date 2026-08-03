# Container/infra repo consolidation — host `one`

> **Historical record, August 2026. Do not follow as instructions.**
>
> This is the plan as written *before* Phase 2 was carried out, kept because it shows
> how the design was arrived at and what alternatives were weighed. It is not
> maintained and it is wrong in places:
>
> - It says seven containers carried `com.docker.compose.project=ionic`. Six did —
>   `send2ereader` was always its own project.
> - It says esmira and immich-ml had no containers at all. Both had exited containers
>   and registered compose projects, which had to be torn down properly.
> - It references `bin/migrate-project-names.sh` and
>   `docs/torrents-wireguard-reference.yml`. Both have since been removed — the first
>   was a completed one-shot, the second a stale WireGuard-era backup.
>
> For what is actually true now, read `../decisions.md` and `../roadmap.md`.

## Context

Config for this host's Docker stacks lives loose under `~/docker-compose/`, owned by
root, with real secrets in untracked `.env` files and no version control except two
nested third-party repos. The owner is remote for months at a time on ship internet
and needs this in git so changes are reviewable and recoverable. The repo also has to
survive two migrations: Docker → Podman on this host, then all three hosts (`zero`,
`one`, `two`) → Debian + Podman Quadlet in autumn.

Phase 1 (inventory) is complete. Findings and the agreed Phase 2 follow.

---

## Phase 1 findings

### What's running

Seven containers, confirmed by seven `containerd-shim` processes matching seven
identified workloads:

| Stack | Containers | Ports |
|---|---|---|
| **torrents** | gluetun, torrent (qBittorrent), syncthing | 8080; 8384/22000 host-net |
| **ionic-traces** | mysql-ionic, bot, web | 7777 |
| **send2ereader** | send2ereader | 3001 |

**`esmira` and `immich-ml` have no containers at all** — no shim, no process, ports 80
and 3003 unbound. Confirmed down and unused; both are dropped per the owner.

### Volumes — where they actually point

All bind mounts land on `/dev/sdb1`, a USB SSD with four btrfs subvolumes:

- `torrents`: `/media/torrents-config:/config`, `/media/torrents:/downloads`; syncthing
  `/media/torrents:/var/syncthing`, `/media/syncthing-config:/var/syncthing/config`
- `ionic-traces`: `/media/ionic-mysql:/var/lib/mysql`
- `send2ereader`: none

No bind-mount source path needs to move. (`esmira` was the only stack with
repo-relative volumes, and it's being dropped.)

### The port-forwarding "script"

**There is no script.** No cron entry, no OpenRC service, no file on disk. Port
forwarding is two inline environment variables on the gluetun service in
`~/docker-compose/torrents/docker-compose.yml`:

```
VPN_PORT_FORWARDING_UP_COMMAND=/bin/sh -c 'wget -O- --retry-connrefused --post-data "json={\"listen_port\":{{PORT}},...}" http://127.0.0.1:8080/api/v2/app/setPreferences 2>&1'
```

gluetun runs this itself when Proton assigns a port. The precious thing is the shell
escaping inside that YAML scalar. Confirmed working: `qBittorrent.conf` has
`Session\Port=43318`, a Proton-assigned port the hook wrote.

### How it authenticates to qBittorrent — definite answer

**Neither credentials nor a subnet whitelist. It's a localhost auth bypass.**

`/media/torrents-config/qBittorrent/qBittorrent.conf` has `WebUI\LocalHostAuth=false`
and **no `WebUI\AuthSubnetWhitelist` key at all**. The chain:

1. `network_mode: service:gluetun` puts qBittorrent in gluetun's network namespace
2. gluetun's `wget` to `127.0.0.1:8080` therefore arrives as loopback
3. `LocalHostAuth=false` skips auth for loopback → no credentials needed

**Podman implication:** this survives *only* with a shared network namespace — a
Podman **pod**, or `--network container:gluetun`. In Quadlet that's a `.pod` unit with
both containers declaring `Pod=`. Split them into separate namespaces and port
forwarding breaks silently. The `WebUI\Password_PBKDF2` hash stays in
`qBittorrent.conf` on the data volume; it is never needed by, and must never be copied
into, the repo.

### `/etc/fstab` — the boot-safety check

**Decision: report only. Phase 2 does not touch `/etc/fstab`.**

The four `/media/*` btrfs entries have **no `nofail`**, but on this host that is
**safe today**:

- `/etc/conf.d/localmount` leaves `critical_mounts` commented out, and
  `/etc/init.d/localmount` forces `rc=0` when it's empty — a failed `mount -a` logs an
  error and boot continues
- all four `/media/*` entries are **passno 0**, so `fsck` never touches them
- only `/` and `/boot` are fsck'd, both on the SD card, not the USB SSD
- swap is on `sdb2` (same USB disk); a failed `swapon` is non-fatal under OpenRC

**This is exactly what breaks on Debian.** Under systemd an entry without `nofail`
becomes a `local-fs.target` dependency: if `/dev/sdb1` is missing, boot stalls ~90 s
then drops to emergency mode — no network, no SSH, owner on a ship. Recorded as a
blocking pre-Debian-boot checklist item in `docs/recovery.md`.

**No crypttab exists** — no `/etc/crypttab`, no `/dev/mapper`, no LUKS anywhere. Nothing
to track.

### Nested repo state (owner's item 7)

| Repo | Branch | Clean? | Unpushed? |
|---|---|---|---|
| `ionic-traces` | main | clean | none |
| **`send2ereader`** | master | **DIRTY — `M Dockerfile`** | none |
| `hikari` | master | clean | none |
| `hikari-lightbulb` | master | clean | none |

**`send2ereader/Dockerfile` has an uncommitted fix** that the running image was built
from — it adds `clang-dev musl-dev` to the build-stage `apk add`, on top of the commit
that already added a compiler for `pdfcropmargins`. If this is lost, the image stops
rebuilding. **It must be committed to its own repo before anything moves.**

### Things to flag

1. **Compose project-name collision.** `torrents/` and `ionic-traces/` both declare
   `name: ionic`; all seven containers carry `com.docker.compose.project=ionic`. A
   `docker compose up --remove-orphans` in either directory would remove the other
   stack's containers. **Being fixed** — see Phase 2c.
2. **`VPN_PORT_FORWARDING_DOWN_COMMAND` escaping bug.** It has `\"lo"}"` where the UP
   command correctly has `false}"`, leaving an unterminated quote, so `sh` errors and
   the down-hook never resets `listen_port` to 0. Cosmetic; UP path unaffected.
   **Being fixed** — Phase 2b.
3. **Cloudflare tunnel token in plaintext** in `/etc/init.d/cloudflared`, a
   world-readable 755 file — a fourth secret beyond the three expected. cloudflared is
   the owner's remote-access path, so **Phase 2 does not touch it**. Documented only,
   with a note that moving the token to `/etc/conf.d/cloudflared` is a future job to do
   while physically present.
4. **Live stack is OpenVPN.** `VPN_TYPE=openvpn`; `.env` carries both OpenVPN
   credentials and an unused `WIREGUARD_PRIVATE_KEY`. Per the owner, **staying on
   OpenVPN**. The WireGuard key is still a live secret and stays gitignored.

---

## Answers to the owner's advisory questions

### (2) Repo name — recommend `infra`

Since item 12 puts host system config (fstab reference, docs) in the repo alongside
containers, `containers` would become a misnomer within a week. `infra` stays accurate
across compose → Quadlet → three hosts, and is short to type.

Alternatives if you'd rather: `stacks` (compose-flavoured, goes stale after Quadlet),
`fleet` (nice for three hosts), `rack`, or `containers` as you suggested. **Going with
`~/infra` unless you say otherwise.**

### (8) How `SOURCE` is wired — documentation, not automation

**`SOURCE` records; it never triggers a `git pull`.** One line per stack:
`<upstream-url> <deployed-sha>`.

(Correction to an earlier draft: the *server* is on stable home internet — only the
owner's SSH link is ship-limited. Bandwidth during builds is a non-issue.)

The argument that survives is about **unattended change while your ability to debug is
degraded**. An auto-pull at build time means a rebuild silently picks up whatever
upstream HEAD is, so a restart at 03:00 can deploy a broken upstream commit — and you
find out over a laggy SSH link from mid-ocean. Pinning means a rebuild reproduces
exactly what was running. So:

- `compose.yaml` points `build.context` at an **absolute** path (`/home/gavin/src/<name>`)
- `bin/check-sources` compares each `SOURCE` sha against the checkout's real HEAD and
  reports drift. Read-only.
- Updating is deliberate: `git -C ~/src/<name> pull` → rebuild → update `SOURCE` → commit.

If you later want one-command reproducibility, `bin/sync-sources` can read `SOURCE` and
`git fetch && git checkout <sha>` — explicitly invoked, never during a build. That's the
useful half of submodules without the detached-HEAD trap.

### (9) chown — yes, safe, and it removes the sudo problem

**`sudo chown -R gavin:gavin ~/docker-compose` is safe.** These are config files read by
the `docker compose` CLI as the invoking user; the daemon runs as root and reads them
regardless of owner. Nothing under `/media` or `/var/lib/docker` is touched. As a bonus
it fixes the `detected dubious ownership` errors on the two nested repos. It is also
consistent with what's already there — `/media/torrents-config` is already `gavin:gavin`
and the containers run `PUID=1000`.

**Do not chown anything under `/media` or `/var/lib/docker`.**

**On sudo and safety, the recommended split:**

- You run **one** command up front: `sudo chown -R gavin:gavin ~/docker-compose`. After
  that the *entire* file restructure is unprivileged — I need no sudo at all. This is the
  single highest-value thing for keeping the blast radius small.
- Don't add a NOPASSWD sudoers rule. It outlives the session and this doesn't need it.
- Adding `gavin` to the `docker` group would let me run compose directly, but membership
  is **root-equivalent** (anyone in it can bind-mount `/` into a container). Your call,
  not mine to assume. Rootless Podman later removes the need entirely.
- **My recommendation:** you keep the docker socket. The file moves are mine; the one
  irreversible step — recreating the gluetun stack in Phase 2c — you run in your own
  terminal from a script I've committed and you've reviewed. The dangerous action stays
  under your hand, and I verify from the output you paste back rather than assuming.

### (12) Tracking fstab — and the real fix is on Debian

You're right that there's no `fstab.d`. Three options, in increasing order of what I'd
actually do:

1. **Now (recommended):** track a read-only copy at `hosts/one/system/fstab`, with
   `bin/check-system-drift` diffing tracked copies against live `/etc`. Honest, safe,
   zero boot risk. It documents rather than controls.
2. **Generate fstab from repo fragments** — a real `fstab.d`. I'd advise against it: it
   puts a generated file directly on the boot path, which is the one red line.
3. **On Debian, systemd `.mount` units *are* `fstab.d`.**
   `/etc/systemd/system/media-torrents.mount` is one file per mount, individually
   trackable, and lives naturally beside Quadlet units. They also express
   `After=`/`Requires=` ordering against containers, which fstab cannot. That's the
   migration target — and it's where `nofail` becomes
   `x-systemd.device-timeout=10` plus simply not being `RequiredBy=local-fs.target`.

**Crypttab — nothing on `one`, but `zero` is where this gets dangerous.**

`zero` is the mission-critical box (Immich + Syncthing) and it's remote. Four things
matter, in order:

1. **A passphrase prompt at boot is fatal.** A default `/etc/crypttab` entry with no
   keyfile makes systemd wait on `systemd-ask-password` — indefinitely, on a box with no
   console you can reach. Whatever else you do, the unlock must be **non-interactive**.
2. **Pick an unlock method that suits the real threat model.** The Pi has no TPM, so:
   - *Keyfile on the unencrypted root* — protects against someone walking off with the
     external disk, which is usually the actual threat for a home server. Simple,
     no dependencies, survives a reboot with nothing else up.
   - *Clevis + Tang* — `one` or `two` runs the tang server and `zero` unlocks
     automatically only while on your LAN. A genuinely good fit for a three-host homelab,
     and it fails closed if the disk leaves the house. Costs a boot-time dependency on a
     second box being up, which is a real availability trade.

   I'd start with the keyfile and treat tang as a later upgrade.
3. **Nothing on the boot path may depend on it.** The encrypted volume must not be
   `RequiredBy=local-fs.target`. Use `nofail` + `x-systemd.device-timeout=10` on the mount
   and `noauto` semantics where possible, so that a failed unlock leaves you with a booted
   box and working SSH — degraded, not unreachable. That's the same principle as the
   `nofail` finding on `one`, and it matters far more here.
4. **The silent-corruption trap.** If the volume fails to mount, a container with a bind
   mount to that path will happily start against an **empty directory** — Immich would come
   up with a blank library and start writing there. Guard every such unit with
   `RequiresMountsFor=/path` in its Quadlet file (or `After=`/`Requires=` the `.mount`
   unit). This is the single most valuable line to remember from this section.

**Tracking:** `hosts/zero/system/crypttab` as a tracked copy, same drift check as fstab.
**The keyfile itself is never committed** — add `*.key`/`*.keyfile` to `.gitignore`
(already there), reference it by path in the tracked crypttab, and back it up out of band.
Losing it loses the volume.

### (12b) Feasibility of tang on `two` — researched

**Verdict: workable, with one hardware correction and one caveat.**

**Hardware correction.** `armv6l` + 512 MB is **not** a Pi 2 Model B — that's quad-core
Cortex-A7 `armv7l` with 1 GB. `armv6l` + 512 MB means a **Pi 1 Model B+** (or a Zero):
single-core ARM1176 @ 700 MHz, 100 Mbit Ethernet over USB. Worth confirming with
`uname -m; grep -m1 Model /proc/cpuinfo` on `two`, because it decides which OS can run
there — armv6 means Raspberry Pi OS **32-bit only**, no Debian arm64, no 64-bit anything.

**Does tang run on it?** Yes, in principle. `tangd` is a tiny stateless C HTTP server
(depends on `jose`), socket-activated — it uses single-digit MB and only while serving a
request, which happens once per unlock. 512 MB and 700 MHz are irrelevant to a workload
this small. `tang`/`clevis` are packaged for Debian armhf, and Raspberry Pi OS 32-bit
rebuilds the archive for ARMv6.

**The caveat:** Debian dropped ARMv6 armhf long ago, so Pi OS armv6 is a rebuild that
RPi Ltd maintains, and individual packages do occasionally break or go missing. **Verify
before committing** with `apt-cache policy tang clevis jose` on `two`. If it's not there,
the fallback is running tang in a container on `one` — you keep the "second host" property
that makes the design worthwhile.

**The good news about zero:** because only the *data* disk is encrypted and not the root
filesystem, none of this needs initramfs networking, and `/boot/cmdline.txt` is never
touched. Unlock happens late, after the network is up:

```
systemctl enable clevis-luks-askpass.path
```

with the volume listed in **both** `/etc/crypttab` and `/etc/fstab` carrying `_netdev`.
That "both" is not optional — on Debian 12, a non-root device with only a crypttab entry
**silently fails to unlock and never prompts**; adding the fstab entry is what makes it
work. Exactly the sort of thing that eats an evening.

**Does the design pay off?** Honestly: it buys you one specific, valuable property —
**`zero` can reboot unattended so long as `two` is up.** That's the common case (kernel
update, crash, OOM). A site-wide power cut still costs you one SSH unlock; it just moves
from `zero` to `two`. So it's not fewer interventions in the worst case, but far fewer in
the ordinary one. Make sure `two` has no boot-time dependency on `zero`, or you've built a
deadlock.

**Security model, stated plainly:** tang does not authenticate its clients. Anyone who can
reach it on your LAN can use it to unlock. The protection it provides is against the disk
*leaving the network* — theft, or an RMA'd drive. That is usually the real threat model
for a home server, but it is not "encrypted against an intruder on your LAN."

### Your stated intent on unit ordering — confirmed, with one sharpening

You said the container unit should wait for the drive via `Requires`/`Wants`. Correct
instinct; the sharpening is **use `RequiresMountsFor=/path`** in the Quadlet unit. It
derives the right `.mount` dependency automatically, so you can't get the unit name wrong.

And `Wants=` is **not** sufficient — it's advisory, so the container starts anyway if the
mount fails, straight into the empty-directory trap. It needs `Requires=` + `After=`, or
just `RequiresMountsFor=`.

### (10) immich-ml — confirmed down

No container, no shim, no process, port 3003 unbound. Your understanding is correct.
Dropped, along with esmira.

---

### (14) Distro options — Debian is not required, but `two` is the constraint

Researched Aug 2026. **The blocker is `two`'s armv6, not preference.**

**`two` (armv6l, 512 MB) cannot join a non-Debian systemd fleet.** There is essentially
no such distro:

| Option | systemd? | armv6? | Verdict |
|---|---|---|---|
| Raspberry Pi OS | yes | yes | works — but Debian |
| DietPi | yes | yes | Debian-based, so also out |
| Arch Linux ARM `armv6h` | yes | **froze Feb 2024** | effectively dead |
| Alpine (current) | **no** (OpenRC) | yes | works, wrong init |
| Void | no (runit) | yes | wrong init |
| Gentoo | optional | yes | brutal on 700 MHz / 512 MB |

Three honest ways out, and I'd take the second:

1. **Leave `two` on Alpine.** It's idle and non-critical, and tang doesn't need systemd.
   Costs you a heterogeneous fleet, and you'd need to confirm Alpine packages `tang`.
2. **Replace it with a Pi Zero 2 W (~£15).** Quad-core A53, **aarch64**, same 512 MB —
   which is ample for tang. One cheap purchase makes all three hosts the same
   architecture and unlocks every option below. Best value by a distance.
3. **Retire it** and put tang in a container on `one`.

**For `zero` (Pi 5) and `one` (Pi 4), what actually works:**

| Distro | Pi 5 | Notes |
|---|---|---|
| **openSUSE MicroOS / Tumbleweed** | **official since Nov 2025** | SUSE engineers did the Pi 5 U-Boot work. Btrfs + snapper rollback native — matches your existing btrfs subvolumes. MicroOS is transactional/immutable: ideal for a box you can't touch for months. Leap Micro 6.3 (stable cadence) expected late 2026. |
| **AlmaLinux 9 / 10** | **official since 9.4** | EL: ~10-year support, boring, stable. Podman + Quadlet are Red Hat technologies — native, first-class. arm64 only. |
| Arch Linux ARM | works, unofficially | needs U-Boot removed + `linux-rpi` kernel; rolling release on a box you visit twice a year is asking for it. |
| Fedora IoT / Server | **not supported** | best Quadlet story of any distro, but mainline Pi 5 (RP1 ethernet) is still incomplete. Rules it out. |
| NixOS | possible | systemd, declarative — would make "the repo defines the host" literal. But a large pivot away from the compose→Quadlet plan, and Pi 5 needs `raspberry-pi-nix`. |

**Recommended shape — use `one` as the guinea pig,** which fits your own risk split:

- **`one` (non-critical, Pi 4): openSUSE MicroOS now.** Prove the Quadlet conversion on the
  box where breakage costs nothing.
- **`zero` (critical, Pi 5): AlmaLinux 10**, or **Leap Micro 6.3** if it ships before you
  migrate. Alma is the lower-risk pick today: official Pi 5 support, long support window,
  Podman/Quadlet native.
- **`two`: Pi Zero 2 W**, then whatever `one` settled on.

Timing note: you're home end of September 2026; Leap Micro 6.3 is expected "late 2026", so
it may or may not land inside your window. Alma is available now.

Sources: [openSUSE Pi 5 support](https://news.opensuse.org/2025/11/04/raspberrypi5-opensuse/) ·
[AlmaLinux Pi 5](https://almalinux.org/blog/2024-06-11-almalinux-support-for-raspberry-pi-5/) ·
[Fedora Pi 5 status](https://discussion.fedoraproject.org/t/raspberry-pi-5-status/131251) ·
[ALARM Pi 5](https://archlinuxarm.org/forum/viewtopic.php?f=67&t=16869) ·
[clevis non-root unlock](https://github.com/latchset/clevis/issues/457)

**This changes nothing in Phase 2.** Compose files are distro-agnostic, and the
`deployments/` + `hosts/` split is what makes the eventual per-host distro choice
independent of the stacks.

---

## Phase 2 — restructure

### Prerequisite (you run this in your own terminal)

```
sudo chown -R gavin:gavin ~/docker-compose
```

Everything after this is unprivileged except Phase 2c.

**Working agreement on privileged commands:** the owner does not use `!` from inside the
session. Any command needing `sudo` or the Docker socket is **handed over as a copy-paste
block to run in a separate terminal**, and the owner pastes the output back. I never
assume a privileged command has run — I verify from its output, or by re-reading state
with unprivileged tools, before continuing. That applies to the `chown` above and to all
of Phase 2c.

### Layout — with the deployments/hosts split (item 11)

```
~/infra/
├── .gitignore
├── README.md
├── bin/
│   ├── compose               # optional wrapper: bin/compose torrents up -d
│   ├── check-sources         # SOURCE sha vs real checkout HEAD
│   ├── check-system-drift    # tracked /etc copies vs live
│   └── migrate-project-names.sh   # one-shot, Phase 2c
├── deployments/              # canonical, host-agnostic. Run compose from here.
│   ├── torrents/             compose.yaml .env(ignored) .env.example README.md
│   ├── ionic-traces/         compose.yaml .env(ignored) .env.example SOURCE README.md
│   └── send2ereader/         compose.yaml .env.example SOURCE README.md
├── hosts/                    # assignment map — symlinks only
│   ├── one/
│   │   ├── torrents      -> ../../deployments/torrents
│   │   ├── ionic-traces  -> ../../deployments/ionic-traces
│   │   ├── send2ereader  -> ../../deployments/send2ereader
│   │   └── system/fstab      # tracked reference copy
│   ├── zero/system/          # Immich + Syncthing land here later; crypttab too
│   └── two/system/
└── docs/
    ├── recovery.md           # boot model, fstab checklist, cloudflared, sudo
    ├── port-forwarding.md    # the localhost-auth chain and what breaks it
    └── torrents-wireguard-reference.yml   # the old .bak, kept for reference
```

### (11) The symlink caveat — narrower than I first said

**Background: the "project directory".** When you run `docker compose -f <file>`, Compose
picks a *project directory* — by default the folder containing the compose file. That
folder is the anchor every relative path in the file is measured from:

| in compose.yaml | resolves to |
|---|---|
| `env_file: .env` | `<project dir>/.env` |
| `context: ./app` | `<project dir>/app` |
| `- ./data:/data` | `<project dir>/data` |

**Where the symlink comes in.** With `hosts/one/torrents -> ../../deployments/torrents`,
the same compose file is reachable two ways, so the project directory is either
`hosts/one/torrents` or `deployments/torrents` depending on which path you used and
whether Compose resolves symlinks first.

**But this only matters for paths containing `..`.** I overstated it earlier. Work it
through:

- `./data` — under `hosts/one/torrents/data`, the lookup passes *through* the symlink and
  lands on `deployments/torrents/data`. **Same file. Safe either way.** Same for `.env`.
- `../../src/foo` — this climbs *out* of the stack directory, and that's where the two
  paths diverge:
  - from `deployments/torrents/` → `infra/src/foo`
  - from `hosts/one/torrents/` unresolved → `hosts/src/foo` ✗
  - from `hosts/one/torrents/` resolved → `infra/src/foo`
- absolute paths (`/media/torrents`) — **always safe**, no anchor involved.

**So the whole mitigation is one rule: never use `..` in a compose file.** Anything
outside the stack directory gets an absolute path.

In practice that's nearly free here, because all bind mounts are *already* absolute
(`/media/...`). The only paths pointing outside a stack dir are the two build contexts.

**No hardcoded username.** The idiomatic Compose answer is that host-specific values live
in `.env` — which is exactly what `.env` is for, and it's gitignored, so no path to any
particular user's home ever reaches git:

```yaml
build:
  context: ${SRC_ROOT:?set SRC_ROOT in .env, e.g. /home/gavin/src}/send2ereader
```

```ini
# .env.example  (committed)
SRC_ROOT=
# .env          (gitignored, per host)
SRC_ROOT=/home/gavin/src
```

Two deliberate choices there:

- **`:?` rather than `:-`.** With no default, an unset `SRC_ROOT` makes Compose stop with
  the message you wrote, instead of silently building from a wrong path. Fail loud, fail
  immediately. This is the mandatory-variable form and it's the right one for something
  that would otherwise fail mysteriously months later on a different host.
- **Not `$HOME/src`.** Compose *would* interpolate it, but `HOME` is unset or root's when
  Compose runs from cron, OpenRC, or a systemd unit — so it would work by hand and break
  when automated, which is the worst kind of bug. (Compose also never expands `~`, so
  `~/src` in a compose file is a literal directory named `~`.)

`send2ereader` gains a `.env` purely for this; `torrents` and `ionic-traces` already have
one. With that, the symlink layout is safe with no tooling at all.

**Optional convenience, not a requirement:** `bin/compose`, a five-line wrapper so you can
type `bin/compose torrents up -d` instead of the full `-f` path. It also pins
`--project-directory` explicitly, which makes the `..` question moot even if someone later
adds a relative path by accident:

```sh
#!/bin/sh
# usage: bin/compose <stack> <args...>    e.g.  bin/compose torrents up -d
set -eu
stack=$1; shift
dir="$(CDPATH= cd -- "$(dirname -- "$0")/../deployments/$stack" && pwd -P)"
exec docker compose --project-directory "$dir" -f "$dir/compose.yaml" "$@"
```

(`pwd -P` resolves symlinks; `--project-directory` pins the answer.) Take it or leave it —
the `no ..` rule is what actually closes the hole.

**Prove it rather than trust it**, once, after the symlinks exist:

```sh
diff <(docker compose -f deployments/torrents/compose.yaml config) \
     <(docker compose -f hosts/one/torrents/compose.yaml config) && echo symlink-safe
```

Keeping an explicit `name:` in every compose file matters here too — it stops Compose
deriving a project name from whichever directory you entered through, which is the same
class of bug that produced the current `ionic` collision.

### Home directory, after

```
~/
├── infra/   # this repo — config only
└── src/     # source checkouts, each its own git repo
    ├── hikari/  hikari-lightbulb/  ionic-traces/  send2ereader/
```

`~/docker-compose/` is gone. Moving a build context is safe — Compose reads it at *build*
time only, and all seven containers are already built and running.

### Phase 2a — commit first, then move verbatim (item 3)

1. **Commit the pending `send2ereader` Dockerfile fix in its own repo**, before anything
   moves. Nothing else is dirty.
2. `git init ~/infra`; write `.gitignore` **before any content**: `.env`, `.env.*`,
   `!.env.example`, `*.key`, `qBittorrent.conf`, `*.sql`
3. Capture pre-move state: `docker compose config` for the torrents stack, plus
   `Status`/`StartedAt` for all seven containers.
4. `mkdir ~/src`; move the four checkouts there.
5. Move `torrents` → `deployments/torrents/` (`docker-compose.yml` → `compose.yaml`, `.env`
   alongside). **The gluetun `VPN_PORT_FORWARDING_*` scalars are copied byte-for-byte — no
   reformatting, no YAML re-quoting.** `.bak` → `docs/torrents-wireguard-reference.yml`.
6. Create deploy stubs for `ionic-traces` and `send2ereader` (absolute `build.context`,
   `SOURCE`, `.env.example`). Compose files are *copied* out of the checkouts, not moved, so
   each still builds standalone.
7. Create the `hosts/` symlink tree and `hosts/one/system/fstab` reference copy.
8. Delete `~/tmp-stress-ng-*` and `~/uv.lock`. Drop `esmira` and `immich-ml` — their compose
   files go nowhere; `esmira`'s two empty data dirs are removed.
9. **Secret scan** (see Verification), then **commit 1: verbatim move, zero behaviour change.**

### Phase 2b — fixes, committed separately

10. Fix the `DOWN_COMMAND` escaping: `\"lo"}"` → `\"lo\"}"`.
11. Rename project names to break the collision: torrents `name: ionic` → `name: torrents`;
    ionic-traces keeps `name: ionic` (it's genuinely the Ionic project).
12. **Commit 2.** Still nothing restarted — these files aren't live until 2c.

### Phase 2c — the recreate (item 13)

Renaming the project means the running containers are no longer associated with the compose
file, so they must be replaced. Downtime on `one` is acceptable per the owner; all state is
on `/media` bind mounts, so nothing is lost — gluetun holds none, and qBittorrent's config
lives on `/media/torrents-config`.

Since full downtime is authorised, this is a straightforward down/up of **both** projects,
which also clears the `ionic` collision in one pass. Delivered as a reviewable script,
`bin/migrate-project-names.sh`, so it's one command and the output lands in the session
for verification:

```sh
docker compose -p ionic -f deployments/torrents/compose.yaml     down
docker compose -p ionic -f deployments/ionic-traces/compose.yaml down
docker compose -f deployments/torrents/compose.yaml     up -d   # now project "torrents"
docker compose -f deployments/ionic-traces/compose.yaml up -d   # stays project "ionic"
```

Order matters: both `down`s run before either `up`, because while the old project label is
still shared, a `down` after a fresh `up` could remove the newly created containers.

**The one thing to watch:** gluetun reconnects and Proton assigns a *new* forwarded port,
the UP hook fires, and it lands in `qBittorrent.conf`. That's the whole point of the
exercise. If the hook fails, the fallback is running the same `wget` by hand inside
gluetun — nothing is lost either way.

**Socket access:** this is the only step needing Docker. I write and commit
`bin/migrate-project-names.sh`, you review it, then run
`bash ~/infra/bin/migrate-project-names.sh` in your own terminal and paste the output
back. I verify from that output plus unprivileged checks (`netstat`, `qBittorrent.conf`)
before declaring it done.

---

## Verification

1. **Secret scan before first commit** — must return nothing:
   ```
   git -C ~/infra ls-files -z | xargs -0 grep -nEI \
     'PRIVATE_KEY|DISCORD_TOKEN|OPENVPN_PASSWORD|ROOT_PASSWORD|PBKDF2|eyJhIjoi'
   git -C ~/infra status --porcelain --ignored | grep '\.env$'   # expect: ignored
   ```
2. **Config equivalence after 2a** — `docker compose config` for torrents byte-identical to
   the pre-move capture. Proves the port-forward scalars survived. Needs the Docker socket,
   so it's part of the copy-paste block you run; I diff the output you paste back.
   (Unprivileged fallback if you'd rather not: `diff` the old and new compose files
   directly — weaker, since it doesn't prove Compose *parses* them identically.)
3. **Nothing changed state after 2a/2b** — `Status`/`StartedAt` for all seven containers
   identical to the pre-move capture.
4. **Checkouts survived** — `git -C ~/src/<repo> status` clean, same branch and SHA, no
   dubious-ownership error, `bin/check-sources` reports no drift.
5. **Symlinks resolve** — `readlink -f hosts/one/*` lands in `~/infra/deployments/`.
6. **Ports unchanged** — `netstat -tln` still shows 8080, 3001, 7777, 8384, 22000.
7. **After 2c only:** new forwarded port visible in gluetun's log, matching `Session\Port`
   in `qBittorrent.conf`; qBittorrent reachable on 8080; `com.docker.compose.project` is
   `torrents` for the three containers and `ionic` for the other four.
