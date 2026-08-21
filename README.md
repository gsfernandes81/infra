# infra

Container and system config for `zero`, `one`, `two`. Config only — no source, no
secrets, no data.

## Run a stack

```sh
bin/compose torrents up -d          # one:  torrents | ionic-traces | send2ereader
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
cd /srv/infra/deployments/destiny-director
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
docs/                  read these
```

## Fleet

| Host | Hardware | Runs | In repo |
|---|---|---|---|
| `one` | Pi 4 | torrents, ionic-traces, send2ereader | yes |
| `zero` | Pi 5 | Immich (+ db, ml, redis), Syncthing — **all critical, remote** | yes |
| `two` | Pi 1 B+, armv6, ~475 MB | destiny-director (**test** bot + its Postgres); lifeboat duties **planned, not built** | stays on Alpine |

Target OS for `one` and `zero`: **openSUSE MicroOS** (see [roadmap](docs/roadmap.md)).

`two`'s lifeboat jobs — serial console, power-cycle, dead-man's switch, boot-integrity
monitoring — are the [roadmap's §5](docs/roadmap.md#5-two--keep-it-as-the-lifeboat) and
**none of them exist yet**. What actually runs there today is `cloudflared`, `crond`,
`sshd`, and now this stack. It is also the only host on **rootless podman**; docker and
containerd are removed from it. See [decisions.md](docs/decisions.md).

### Ports

**These are what the compose files ask for. What is actually listening is
[fleet-inventory.md](docs/fleet-inventory.md), generated from the boxes.** Where the two
disagree, the inventory is right and something is down — that is the whole reason it
exists, and the first run of it found exactly that on `one`.

| Host | |
|---|---|
| `one` | **8080** qBittorrent (via gluetun) · **7777** ionic-traces · **3001** send2ereader · **8384/22000** syncthing |
| `zero` | **2283** Immich · **8384/22000** syncthing · **127.0.0.1:2224** the `or3-dev` container |
| `two` | **none published** — the bot's web UI (8080) and break-glass sshd (2222) exist inside the container and are deliberately not mapped. See the commented `ports:` block in `deployments/destiny-director/compose.yaml` |

Both Syncthings and `torrent` are on **host or shared networking**, so `docker ps` shows
them publishing nothing. They are still reachable; the inventory's Published column says
which case each is, and its Listening section is the answer that covers all of them.

### Dev containers on `zero`

Three, in their own application repos and **deliberately not in this one** — they are
driven by `make dev` there, are `restart=no`, and hold live sessions and uncommitted
worktrees. See [decisions.md](docs/decisions.md).

| Container | Repo | SSH |
|---|---|---|
| `or3-dev` | `or3` | `127.0.0.1:2224` |
| `dd-dev` (+ `dd-mysql`) | `destiny-director` | 2222 |
| `ds-dev` | `dossier` | 2223 |

**Only `or3-dev` was up at the last audit**, and only its port was listening. The other
two being down is the normal resting state, not a fault: nothing starts them but a person.
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
| [host-setup.md](docs/host-setup.md) | Building one of these boxes from bare Alpine. |
| [port-forwarding.md](docs/port-forwarding.md) | The fragile bit. Read before touching the torrents stack. |
| [roadmap.md](docs/roadmap.md) | What's next, and the traps waiting in it. |
| [decisions.md](docs/decisions.md) | Why it looks like this. Don't relitigate. |

## Three rules

- **No `..` in a compose file.** Each stack is reachable via `deployments/` *and*
  `hosts/one/`; a path climbing out resolves differently. Absolute paths outside a
  stack dir.
- **Every compose file declares `name:`.** Without it Compose invents one from the
  directory — that's what made `torrents` and `ionic-traces` collide as `ionic`.
- **`SRC_ROOT` goes in `.env`, never `$HOME`.** `HOME` is unset or root's under
  cron/init, so `$HOME/src` works by hand and breaks when automated.
