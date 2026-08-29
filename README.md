# infra

Container and system config for `zero`, `one`, `two`. Config only — no source, no
secrets, no data.

## Run a stack

```sh
bin/compose torrents up -d          # one:  torrents | send2ereader  (ionic-traces stopped)
bin/compose immich   up -d          # zero: immich | syncthing
bin/check-sources                   # is the deployed sha still the pinned one?
bin/check-system-drift              # do tracked /etc copies still match live?
bin/install-system-file <name>      # install one of them (dry run without --commit)
bin/check-boot-layout               # can /boot be tampered with without a reboot?
sudo bin/check-mount-guards         # can a failed mount still eat the data? (any host)
```

**`two` is the exception.** Its one stack, `destiny-director`, cannot be driven by
`bin/compose` on any host — its images are `linux/arm/v6` and its `.env` exists only on
that box — so `bin/compose destiny-director` refuses by name and says where to go.

It is deployed with plain `podman-compose`, in an unprivileged deploy account's shell:

```sh
ssh claude@ssh-two.gsrpi.uk
cd ~gavin/infra/deployments/destiny-director   # NOT /srv/infra — see hosts/two/setup/README.md
podman-compose pull
podman-compose up -d postgres
podman-compose up -d --no-deps --force-recreate beacon
podman-compose up -d --no-deps --force-recreate anchor
```

`--no-deps` is required — see [`hosts/two/setup/README.md`](hosts/two/setup/README.md),
which is the whole build of that box.

There used to be a restricted SSH forced command here (`dd-ctl`) and a 1800-line
`root-setup.sh`. Both are gone. `dd-ctl` existed to stop a deploy key escaping into
`gavin`, who is in `wheel`; the account that deploys is now an unprivileged user of its
own, so the boundary is uid separation rather than a script that had to be kept correct.

Nothing on `two` starts at boot, by decision: after a power cut it runs nothing until
someone deploys.

## Layout

```
deployments/<stack>/   what a stack is — compose.yaml, .env (ignored), SOURCE
hosts/<host>/          where it runs — symlinks into deployments/, tracked /etc copies
hosts/two/setup/       how `two` was built — one reviewed root script, not on any PATH
bin/                   the scripts above (_infra.py is their shared header parser)
ansible/               the management plane — inventory, playbooks, the audit
dev/                   the infra-dev container on zero: work on this repo, from a phone
docs/                  read these
```

## Fleet

| Host | Hardware | Runs | In repo |
|---|---|---|---|
| `one` | Pi 4 | torrents, send2ereader; ionic-traces **stopped by decision** | yes |
| `zero` | Pi 5 | Immich (+ db, ml, redis), Syncthing — **all critical, remote** | yes |
| `two` | Pi 1 B+, armv6, ~475 MB | destiny-director (**test** bot + its Postgres); lifeboat duties **planned, not built** | stays on Alpine |

Target OS for `one` and `zero`: **openSUSE MicroOS** (see [roadmap](docs/roadmap.md)).

`two`'s lifeboat jobs — serial console, power-cycle, dead-man's switch, boot-integrity
monitoring — are the [roadmap's §5](docs/roadmap.md#5-two--keep-it-as-the-lifeboat) and
**none of them exist yet**. What actually runs there today is `cloudflared`, `crond`,
`sshd`, and now this stack. It is also the only host on **rootless podman**; docker and
containerd are removed from it. See [decisions.md](docs/decisions.md).

### Public hostnames

Zero's tunnel serves eight, and **only one of them was recorded anywhere in this repo
before 2026-08-23**. Since 2g finished on 2026-08-29 the authoritative record for every
host is `hosts/<host>/system/cloudflared-config.yml` — all three tunnels are
locally-managed, so that tracked file **is** the routing rather than a snapshot of
Cloudflare's. [cloudflare.md](docs/cloudflare.md) keeps per-host hostname tables for
reading at a glance; regenerate either on the host with
`curl -s 127.0.0.1:20241/config`.

Worth knowing without opening either: `ssh-zero.gsrpi.uk` reaches zero's sshd, which is
why restarting that tunnel from a session that arrived through it would strand you. And
zero's ingress carries a rule for `torrents.gsrpi.uk` that has never served anything —
that hostname's CNAME points at **one**'s tunnel, and always has.

### Ports

**These are what the compose files ask for. What is actually listening is
[fleet-inventory.md](docs/fleet-inventory.md), generated from the boxes.** Where the two
disagree, the inventory is right and something is down — that is the whole reason it
exists, and the first run of it found exactly that on `one`.

| Host | |
|---|---|
| `one` | **8080** qBittorrent (via gluetun) · ~~**7777** ionic-traces~~ — **stopped**, see [2c](docs/management-plane.md#sequencing-and-where-podman-fits) · **3001** send2ereader · **8384/22000** syncthing |
| `zero` | **2283** Immich · **8384/22000** syncthing · **127.0.0.1:2224-2225** the `or3-dev` and `infra-dev` containers |
| `two` | **none published** — the bot's web UI (8080) and break-glass sshd (2222) exist inside the container and are deliberately not mapped. See the commented `ports:` block in `deployments/destiny-director/compose.yaml` |

Both Syncthings and `torrent` are on **host or shared networking**, so `docker ps` shows
them publishing nothing. They are still reachable; the inventory's Published column says
which case each is, and its Listening section is the answer that covers all of them.

### Dev containers on `zero`

Four. Each is driven by `make dev` **in the repo it belongs to**, each is `restart=no`,
and each holds live sessions and uncommitted worktrees. See
[decisions.md](docs/decisions.md).

| Container | Repo | SSH | Defined in |
|---|---|---|---|
| `dd-dev` (+ `dd-mysql`) | `destiny-director` | 2222 | that repo |
| `ds-dev` | `dossier` | 2223 | that repo |
| `or3-dev` | `or3` | `127.0.0.1:2224` | that repo |
| `infra-dev` | **this one** | `127.0.0.1:2225` | [`dev/`](dev/README.md) |

**`infra-dev` is the exception to "dev containers stay in their own repo", and it is not
one.** That rule says a dev container belongs to the repo it develops; this one develops
*this* repo, so `dev/` is exactly where it belongs. What it is not is a host service —
nothing in `deployments/` or `hosts/` refers to it, and `bin/compose` cannot drive it.

It also carries `ansible-core` and the collections, which makes it a **second control
node** and a cheaper one than the phone: an audit run from Termux crosses metered mobile
data to reach boxes that are on zero's own LAN, and the same run from inside the
container crosses nothing that costs anything. [`dev/README.md`](dev/README.md).

**Only `or3-dev` was up at the last audit**, and only its port was listening. The others
being down is the normal resting state, not a fault: nothing starts them but a person.
Their named volumes survive regardless, and those volumes are the thing that matters —
`or3-dev_or3-claude` is 22 MB of login and session history, and a dev container that
moves hosts without its volume arrives logged out and empty. The inventory lists every
volume on both hosts for that reason.

## Secrets

None are in git. `.gitignore` covers `.env`, `*.key`, `qBittorrent.conf`, `*.sql`.

| Secret | Lives in |
|---|---|
| ProtonVPN creds, WireGuard key (unused) | `deployments/torrents/.env` |
| Discord token, MySQL root password | `deployments/ionic-traces/.env` |
| Immich Postgres password | `deployments/immich/.env` |
| qBittorrent `Password_PBKDF2` | `/media/torrents-config/` — data volume, never here |
| Cloudflare tunnel token | `/etc/init.d/cloudflared` — plaintext, world-readable, **on both hosts** |
| Discord tokens, Bungie + Sheets keys | `~/destiny-director/.env` on `zero` — app repo, not here |
| **Test** Discord tokens, Postgres password, Bungie keys | `deployments/destiny-director/.env` on `two` |
| `two` deploy key (private half) | wherever you deploy from. It reaches an unprivileged account with a normal shell, so it does **not** belong in the Claude Code cloud environment block, whose values are not masked. Public half in `~claude/.ssh/authorized_keys` on `two`. See [`hosts/two/system/README.md`](hosts/two/system/README.md) |

## Docs

| | |
|---|---|
| [recovery.md](docs/recovery.md) | It broke, or it rebooted. Start here. |
| [fleet-inventory.md](docs/fleet-inventory.md) | What is *actually* running, read off the boxes. Generated — never hand-edited. |
| [management-plane.md](docs/management-plane.md) | How the fleet is managed, and why it is Ansible. |
| [ssh-clients.md](docs/ssh-clients.md) | Reaching the fleet and the dev containers from a laptop or a phone. The generated `~/.ssh/config` blocks point here. |
| [host-setup.md](docs/host-setup.md) | Building one of these boxes from bare Alpine. |
| [port-forwarding.md](docs/port-forwarding.md) | The fragile bit. Read before touching the torrents stack. |
| [roadmap.md](docs/roadmap.md) | What's next, and the traps waiting in it. |
| [decisions.md](docs/decisions.md) | Why it looks like this. Don't relitigate. |
| [plans/](plans/) | Deferred plans, one per topic. Deleted once executed. |
| [docs/handoff/](docs/handoff/) | Session handoff notes. Deleted once their open items close. |
| [dev/README.md](dev/README.md) | The `infra-dev` container — working on this repo without paying for it. |
| [ansible/README.md](ansible/README.md) | Running the management plane. |

## Three rules

- **No `..` in a compose file.** Each stack is reachable via `deployments/` *and*
  `hosts/one/`; a path climbing out resolves differently. Absolute paths outside a
  stack dir.
- **Every compose file declares `name:`.** Without it Compose invents one from the
  directory — that's what made `torrents` and `ionic-traces` collide as `ionic`.
- **`SRC_ROOT` goes in `.env`, never `$HOME`.** `HOME` is unset or root's under
  cron/init, so `$HOME/src` works by hand and breaks when automated.
