# VPN port forwarding — how it works, and what breaks it

Host: `one`. Stack: `deployments/torrents`.

## There is no script

This was the first thing that had to be established, and it is worth stating plainly
because the natural assumption is wrong: **there is no port-forwarding script.** No
cron entry, no OpenRC service, no file on disk anywhere.

Port forwarding is two inline environment variables on the `gluetun` service in
`deployments/torrents/compose.yaml`:

- `VPN_PORT_FORWARDING_UP_COMMAND`
- `VPN_PORT_FORWARDING_DOWN_COMMAND`

gluetun runs the UP command itself whenever Proton assigns a forwarded port,
substituting `{{PORT}}` and `{{VPN_INTERFACE}}`. The command is a `wget` that POSTs
to qBittorrent's WebUI API to set `listen_port`.

**The precious thing is the shell escaping inside that YAML scalar.** It is a
single-quoted `/bin/sh -c` wrapping a double-quoted `--post-data` containing
backslash-escaped JSON. Reformatting the YAML, re-quoting the scalar, or letting an
editor normalise it will break port forwarding in a way that produces no error at the
time — you find out when torrents stop connecting. If you must edit that line, edit it
byte-for-byte.

## How it authenticates — no credentials, no whitelist

This surprises people, so: it is **neither** stored credentials **nor** an
`AuthSubnetWhitelist`. It is a localhost auth bypass.

`/media/torrents-config/qBittorrent/qBittorrent.conf` contains:

- `WebUI\LocalHostAuth=false`
- **no** `WebUI\AuthSubnetWhitelist` key at all

The chain, in order:

1. `network_mode: service:gluetun` puts the qBittorrent container inside gluetun's
   **network namespace** — they share one loopback interface.
2. gluetun's `wget` to `127.0.0.1:8080` therefore arrives at qBittorrent as genuine
   loopback traffic, not as traffic from another container.
3. `LocalHostAuth=false` skips authentication for loopback. No credentials needed.

Remove any one of those three and the hook starts failing silently.

The `WebUI\Password_PBKDF2` hash in that file is for *your* browser logins. It is not
used by this chain, it stays on the data volume, and it must never be copied into this
repo.

## What breaks it under Podman

**A shared network namespace is load-bearing.** Under Podman this survives only as:

- a **pod** — both containers in one pod, or
- `--network container:gluetun` on the qBittorrent container

In Quadlet that means a `.pod` unit with both containers declaring `Pod=`.

Split them into separate namespaces and `127.0.0.1:8080` no longer reaches
qBittorrent from gluetun. The port-forward hook fails, `listen_port` is never updated,
and **nothing logs an error you would notice**. This is the single highest-risk item
in the eventual Podman migration.

## Verifying it works

The live evidence that the chain is intact is that `qBittorrent.conf` contains a
`Session\Port` matching a Proton-assigned port — not the default, and not `0`:

```sh
grep -E 'Session\\Port|LocalHostAuth|AuthSubnetWhitelist' \
  /media/torrents-config/qBittorrent/qBittorrent.conf
```

After any recreate of the gluetun stack, Proton assigns a **new** port, so this value
should *change*. That is the thing to watch, and it is the actual test that the stack
came back correctly.

If the hook fails, nothing is lost — the same `wget` can be run by hand inside the
gluetun container to set the port.

## Known bug in the DOWN command

`VPN_PORT_FORWARDING_DOWN_COMMAND` had `\"lo"}"` where the UP command correctly has
`false}"`, leaving an unterminated quote. `sh` errors out, so the down-hook never
resets `listen_port` to 0. Cosmetic — the UP path, which is the one that matters, was
unaffected. Fixed in the Phase 2b commit.
