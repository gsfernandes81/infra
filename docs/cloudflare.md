# Cloudflare

What exists, which parts are load-bearing, and what is safe to delete. Written
2026-08-23, when it turned out the repo recorded **one** of zero's eight public
hostnames and nothing at all about which Cloudflare objects a service depends on.

## Zero's tunnel — `9456fbcd-95f6-48a8-9bcd-d6e85bfbfc01`

**It is remotely-managed, and that cannot currently be changed.** The ingress lives in
Cloudflare; the dashboard's Public Hostnames page is the authoritative record of what
this tunnel serves. `cloudflared` prefers a tunnel's remote configuration whenever one
exists and **ignores local ingress silently** — no error, nothing in any log.

Since 2026-08-23 the credentials are a 0600 file at `/etc/cloudflared/zero.json` and
there is no token in argv. `/etc/cloudflared/config.yml` (tracked at
`hosts/zero/system/cloudflared-config.yml`) carries the tunnel id, the credentials path
and the metrics port — **not** the ingress.

An earlier version of this file said the opposite, because an earlier version of
`config.yml` carried the ingress and appeared to work. Nothing distinguished the two:
they were identical in content, so `/config` reported the same eight rules either way.
It was settled by clearing the remote copy, at which point the connector dropped from
nine rules to one in fifteen seconds and was restored automatically. Recorded because
the wrong version was believable for most of a day.

The table below is a **dated snapshot for humans, not a source of truth.** Regenerate it
on the host with:

```sh
curl -s 127.0.0.1:20241/config
```

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

## Do not clear the remote configuration

It was tried on 2026-08-23, reversibly, and it takes the tunnel down: the connector
follows it, dropping to the bare catch-all and 404ing every hostname. Clearing it is not
tidying, it is an outage.

`PUT .../cfd_tunnel/{id}/configurations` is the endpoint, it does **not** touch DNS, and
a `GET` first makes the whole thing byte-exactly reversible — that structure is why the
attempt cost fifteen seconds rather than an evening. But there is no reason to run it.

## Making it locally-managed

Not available in place, tried 2026-08-23. A connector fetches remote config only when the
tunnel's `config_src` is `cloudflare`, so that field is the whole switch — but
`PATCH .../cfd_tunnel/{id}` with `{"config_src":"local"}` is rejected. The error is
`1002 Tunnel not found`, which is misleading rather than informative: a `GET` on that URL
works, and a `PATCH` to it with `tunnel_secret` succeeded an hour earlier with the same
token. Only the body differs. Read it as "not an accepted PATCH field", not as proof.

Emptying the remote configuration does not achieve it either — an empty remote config
still wins over a local one, which is what took the tunnel down for fifteen seconds
earlier the same day.

**So the only known route is a new tunnel**, created with `config_src: local`, followed
by repointing all eight CNAMEs and retiring the old one.

**Decided 2026-08-23 that this happens** — filed as phase 2g in
[`management-plane.md`](management-plane.md), `one` first as a rehearsal. The reason is
not a fault being fixed but a preference that matches everything else here: no more
configuration in a web dashboard than strictly necessary. Method, estimates and the two
open unknowns are in that entry.

A `config.yml` carrying the full ingress was written for the attempt and removed again
when it failed. It is in git history rather than in `HEAD`, because a copy that cannot
take effect reads as authoritative and is worse than none.

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
  UI should not depend on zero. Entirely a Cloudflare-side change, since the ingress is
  not on the host — add the rule to one's tunnel, repoint the CNAME, then delete the
  Public Hostname from zero's tunnel. No repo edit and no restart on zero.
- **Can this tunnel be made locally-managed at all?** Unknown. It would put the routes
  under review in git, which is the direction everything else here is going.
- **`one` and `two`.** One is unrotated, still `--token` in argv. Two has never been
  checked to see whether its token is even inline.
