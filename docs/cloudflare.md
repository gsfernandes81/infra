# Cloudflare

What exists, which parts are load-bearing, and what is safe to delete. Written
2026-08-23, when it turned out the repo recorded **one** of zero's eight public
hostnames and nothing at all about which Cloudflare objects a service depends on.

## Zero's tunnel — `9456fbcd-95f6-48a8-9bcd-d6e85bfbfc01`

Since 2026-08-23 it runs **locally-managed**: `/etc/cloudflared/config.yml` holds the
ingress, `/etc/cloudflared/zero.json` (0600) holds the credentials, and there is no
token in argv. `config.yml` is tracked at `hosts/zero/system/cloudflared-config.yml`
and is the authoritative record of what this tunnel serves.

| Hostname | Origin | Note |
|---|---|---|
| `ssh-zero.gsrpi.uk` | `ssh://localhost:22` | check whether Access fronts this |
| `syncthing.gsrpi.uk` | `http://localhost:8384` | |
| `syncthing-server.gsrpi.uk` | `tcp://localhost:22000` | the sync protocol, not the UI |
| `immich.gsrpi.uk` | `http://localhost:2283` | no Access — 200 unauthenticated |
| `torrents.gsrpi.uk` | `http://192.168.86.101:8080` | **crosses to `one`** — moving, see below |
| `ssh-zero-dev-dd.gsrpi.uk` | `ssh://localhost:2222` | |
| `ssh-zero-dev-ds.gsrpi.uk` | `ssh://localhost:2223` | |
| `ssh-zero-dev-or3.gsrpi.uk` | `ssh://localhost:2224` | |
| *(catch-all)* | `http_status:404` | |

Order is behaviour: cloudflared matches first-rule-wins.

`infra-dev.gsrpi.uk` is **not** here. It has its own tunnel, run by a connector inside
the container, which is the pattern *management-plane.md* § *Addressing* chose. The
three older dev containers are still on the host tunnel — the fleet is mid-migration
between the two designs, and finishing it is Phase 5.

## The dashboard is now stale, and that is not a fault

Zero's tunnel still has a remote configuration listing the same hostnames. **The
connector ignores it.** Editing Public Hostnames in the dashboard changes nothing.

It is deliberately left in place as a fallback: if anyone ever drops `--config` from
`command_args`, the connector falls back to remote config and keeps serving. Clearing it
would turn that slip into 404s for everything. `PUT .../cfd_tunnel/{id}/configurations`
with an empty ingress would clear it without touching DNS, if that trade is ever
wanted — it has not been taken.

## Landmines

- **Deleting a Public Hostname deletes its DNS record.** The CNAMEs are load-bearing;
  the dashboard ingress entries are not. All eight point at
  `9456fbcd-…cfargotunnel.com`, and the local config is useless without them. Clearing
  the dashboard "tidily" takes down every service on zero and presents as a broken
  tunnel.
- **Never delete the tunnel.** Its UUID is in all eight CNAMEs and in `config.yml`.
  Recreating mints a new one.
- **Never delete a tunnel with a CNAME still aimed at it.** Check DNS first.
- **Leave infra-dev's Access application, policy and service token alone.** They are the
  way into the container. Different tunnel; confirm which one you are looking at.
- **An Access service token is not an API token is not a tunnel token.** Three unrelated
  credentials sharing a word. `ansible/playbooks/cloudflare-dev-tunnel.yml` prompts for
  the right one by saying which it is not.

## Safe to delete

- **API tokens after use.** Rotation needs `Account -> Cloudflare Tunnel -> Edit` and
  nothing else; mint it, use it, delete it. The 2026-08-22 one was All accounts / All
  zones, which is the mistake to not repeat.
- **Orphaned Access service tokens.** At least one is expected: a token created
  2026-08-22 whose secret was censored by `no_log` before it was printed and is
  unrecoverable. Identify the live one by the `client_id` in the phone's
  `~/.config/infra-dev/token`; anything else is dead weight.
- **Duplicate Access applications** from the same failed runs.

## Open

- **Is `ssh-zero.gsrpi.uk` behind an Access policy?** It maps to zero's sshd. If nothing
  fronts it, that sshd is reachable from the internet — key-only, so not urgent, but it
  should be a decision. Same for the three `ssh-zero-dev-*` hostnames.
- **Immich has no Access policy** — verified indirectly, an unauthenticated fetch
  returns 200. Probably intentional, since Immich has its own login. Worth confirming
  rather than inheriting.
- **`torrents.gsrpi.uk` moves to `one`'s own tunnel.** Decided 2026-08-23: one's torrent
  UI should not depend on zero. Ordered — add the rule to one's tunnel and repoint the
  CNAME first, *then* remove the two lines from zero's `config.yml` and cycle.
- **`one` and `two`.** One is unrotated, still `--token` in argv. Two has never been
  checked to see whether its token is even inline.
