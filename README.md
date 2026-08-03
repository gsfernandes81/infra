# infra

Container and system config for `zero`, `one`, `two`. Config only — no source, no
secrets, no data.

## Run a stack

```sh
bin/compose torrents up -d          # torrents | ionic-traces | send2ereader
bin/check-sources                   # is the deployed sha still the pinned one?
bin/check-system-drift              # do tracked /etc copies still match live?
```

## Layout

```
deployments/<stack>/   what a stack is — compose.yaml, .env (ignored), SOURCE
hosts/<host>/          where it runs — symlinks into deployments/, tracked /etc copies
bin/                   the three scripts above
docs/                  read these
```

## Fleet

| Host | Hardware | Runs | In repo |
|---|---|---|---|
| `one` | Pi 4 | torrents, ionic-traces, send2ereader | yes |
| `zero` | Pi 5 | Immich (+ db, ml), Syncthing, 2× Claude dev — **all critical, remote** | not yet |
| `two` | Pi 1 B+, armv6, 512 MB | lifeboat: serial console, power-cycle, watchdog | stays on Alpine |

Target OS for `one` and `zero`: **openSUSE MicroOS** (see [roadmap](docs/roadmap.md)).

Ports on `one`: **8080** qBittorrent · **7777** ionic-traces · **3001** send2ereader ·
**8384/22000** syncthing.

## Secrets

None are in git. `.gitignore` covers `.env`, `*.key`, `qBittorrent.conf`, `*.sql`.

| Secret | Lives in |
|---|---|
| ProtonVPN creds, WireGuard key (unused) | `deployments/torrents/.env` |
| Discord token, MySQL root password | `deployments/ionic-traces/.env` |
| qBittorrent `Password_PBKDF2` | `/media/torrents-config/` — data volume, never here |
| Cloudflare tunnel token | `/etc/init.d/cloudflared` — plaintext, world-readable |

## Docs

| | |
|---|---|
| [recovery.md](docs/recovery.md) | It broke, or it rebooted. Start here. |
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
