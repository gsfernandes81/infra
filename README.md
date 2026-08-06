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

**`two` is the exception, and its tool is deliberately not in `bin/`.** Its one stack,
`destiny-director`, cannot be driven by `bin/compose` on any host — its compose file
needs two variables `bin/compose` does not supply, and `two` has no docker at all —
so `bin/compose destiny-director` refuses by name and says where to go. It is deployed
over SSH by a restricted forced command whose single copy lives beside the stack, at
[`deployments/destiny-director/dd-ctl`](deployments/destiny-director/dd-ctl):

```sh
ssh -i ~/.ssh/dd-ctl gavin@ssh-two.gsrpi.uk status
ssh -i ~/.ssh/dd-ctl gavin@ssh-two.gsrpi.uk deploy-beacon
ssh -i ~/.ssh/dd-ctl gavin@ssh-two.gsrpi.uk logs
```

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

Ports on `one`: **8080** qBittorrent · **7777** ionic-traces · **3001** send2ereader ·
**8384/22000** syncthing.

Ports on `zero`: **2283** Immich · **8384/22000** syncthing · **2222/2223** dev containers.

Ports on `two`: **none published.** The bot's web UI (8080) and its break-glass sshd
(2222) exist inside the container and are deliberately not mapped — see the commented
`ports:` block in `deployments/destiny-director/compose.yaml` for why.

`zero` also runs two **Claude dev containers** (`dd-dev` + `dd-mysql`, `ds-dev`). They are
deliberately **not** in this repo — they belong to their own application repos and are
driven by `make dev` there. They are `restart=no` and hold live sessions. See
[decisions.md](docs/decisions.md).

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
| `dd-ctl` deploy key (private half) | your workstation only. The public half is in `~gavin/.ssh/authorized_keys` on `two`, behind `command="/usr/local/bin/dd-ctl",restrict` |

## Docs

| | |
|---|---|
| [recovery.md](docs/recovery.md) | It broke, or it rebooted. Start here. |
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
