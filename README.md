# infra

Container and system configuration for the three-host fleet: `zero`, `one`, `two`.

Config only. No source code, no secrets, no data.

## Layout

```
deployments/<stack>/    canonical stack definition — host-agnostic. Run compose from here.
hosts/<host>/           assignment map: symlinks into deployments/, plus tracked /etc copies
bin/                    helper scripts, all read-only except the one-shot migrations
docs/                   how this host boots, and what breaks it
```

`deployments/` says *what a stack is*. `hosts/` says *where it runs*. Keeping them
apart is what lets each host move to a different distro later without touching the
stack definitions.

## Running a stack

```sh
bin/compose torrents up -d
```

That wrapper pins `--project-directory`, which makes the symlink question moot. The
equivalent by hand:

```sh
docker compose -f deployments/torrents/compose.yaml up -d
```

## Rules that are not style preferences

- **Never use `..` in a compose file.** Anything outside a stack directory gets an
  absolute path. Because each stack is reachable both as `deployments/<stack>` and as
  `hosts/one/<stack>`, a relative path that climbs out resolves differently depending
  on which way you came in. Paths that stay inside the directory are safe either way.
- **Every compose file declares an explicit `name:`.** Without it Compose derives the
  project name from whichever directory you entered through. That is exactly the bug
  that let `torrents` and `ionic-traces` both become project `ionic`, where a
  `docker compose up --remove-orphans` in one would delete the other.
- **Host-specific values live in `.env`,** which is gitignored. `SRC_ROOT` is the
  only one so far. It uses `${SRC_ROOT:?...}` rather than a default so that an unset
  value stops Compose with a readable error instead of silently building from the
  wrong path.
- **Not `$HOME`.** `HOME` is unset, or root's, when Compose runs from cron or an init
  system — so `$HOME/src` works by hand and breaks when automated. Compose never
  expands `~` at all; `~/src` in a compose file means a literal directory named `~`.

## Source checkouts

Stacks that build from source do not vendor it. Each has a `SOURCE` file:

```
<upstream-url> <deployed-sha>
```

`SOURCE` **records; it never pulls.** An auto-pull at build time means a restart at
03:00 can deploy whatever upstream HEAD happens to be, and you find out over a laggy
link from mid-ocean. Pinning means a rebuild reproduces what was running.

`bin/check-sources` reports drift between each `SOURCE` and the real checkout HEAD.
Updating is deliberate:

```sh
git -C ~/src/<name> pull && bin/compose <stack> build && $EDITOR deployments/<stack>/SOURCE
```

Checkouts live in `~/src/`, pointed at by `SRC_ROOT` in each stack's `.env`.

## Secrets

Never committed. `.gitignore` covers `.env`, key material, `qBittorrent.conf` and
`*.sql`. What exists on this fleet, and where it actually lives:

| Secret | Location | In repo? |
|---|---|---|
| ProtonVPN OpenVPN credentials | `deployments/torrents/.env` | ignored |
| WireGuard private key (unused — stack is OpenVPN) | `deployments/torrents/.env` | ignored |
| Discord token, MySQL root password | `deployments/ionic-traces/.env` | ignored |
| qBittorrent `WebUI\Password_PBKDF2` | `/media/torrents-config/` | never — data volume |
| Cloudflare tunnel token | `/etc/init.d/cloudflared` | never — see `docs/recovery.md` |

## Reading order

- `docs/recovery.md` — how `one` boots, what would stop it, and the remote-access path
- `docs/port-forwarding.md` — the VPN port-forward chain and the one change that
  silently breaks it
