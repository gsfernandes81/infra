# Cloudflare

What exists, which parts are load-bearing, and what is safe to delete. Written
2026-08-23, when it turned out the repo recorded **one** of zero's eight public
hostnames and nothing at all about which Cloudflare objects a service depends on.
Rewritten the same day, twice, because most of what it first said stopped being true.

## Where routing lives, per host

| Host | Tunnel | Managed | Routes are in |
|---|---|---|---|
| `zero` | `ce28c17c-a722-4ba1-8e46-21985337f13f` | **locally** | `hosts/zero/system/cloudflared-config.yml` |
| `one` | `1e7fde2e-ac2f-4a5e-8ad4-591208c1e2a6` | **locally** | `hosts/one/system/cloudflared-config.yml` |
| `two` | `bdb4a988-7c8b-4f5f-a2bf-e42464309d64` | remotely | **Cloudflare** — the dashboard is the record |
| `infra-dev` | separate, in the container | locally | `dev/entrypoint.sh` writes it |
| `or3-dev` | separate, in the container | locally | the same `dev/entrypoint.sh`, from the base image |

For zero and one the tracked file **is** the routing: edit it, commit it,
`bin/install-system-file cloudflared-config.yml`, and cycle. For `two` the file carries
only the tunnel id, credentials path and metrics port — its ingress is at Cloudflare and
a local copy would be ignored.

## The rule that makes that distinction matter

**cloudflared prefers a tunnel's REMOTE configuration whenever one exists, and ignores
local ingress silently** — no error, nothing in any log. Established on zero on
2026-08-23 by clearing the remote copy and watching the connector drop from nine rules to
one within fifteen seconds.

Nothing distinguishes an ignored local config from one in force: both report the same
rules at `127.0.0.1:20241/config`. That claim survived a day of work, three documents and
two commit messages before anyone tested it.

**On `two`, therefore: do not clear the remote configuration.** It is not stale, it is
what serves. `PUT .../cfd_tunnel/{id}/configurations` does not touch DNS, and a `GET`
first makes it byte-exactly reversible — but there is no reason to run it.

## Getting routes into git — how it was actually done

`config_src` is **create-time only**. `PATCH .../cfd_tunnel/{id}` with
`{"config_src":"local"}` is rejected (`1002 Tunnel not found`, on a URL where `GET` works
and where `PATCH` with `tunnel_secret` had succeeded an hour earlier). Emptying the remote
config does not work either — an empty remote config still wins over a local one.

So each host gets a **new** tunnel created with `config_src: local`, and its CNAMEs
repointed. Three playbooks, by blast radius:

```
ansible-playbook playbooks/cloudflare-tunnel-new.yml     -e target=<host> -K
ansible-playbook playbooks/cloudflare-tunnel-cutover.yml -e target=<host> -e ansible_host=<host>-two -K
ansible-playbook playbooks/cloudflare-tunnel-retire.yml  -e target=<host> -K
```

**`ansible_host` is not optional on the cutover.** It cycles the target's connector, so a
session arriving through that tunnel severs itself mid-run — which happened on `one`. The
play now refuses when the client address is loopback and names the fix.

Between phase 1 and phase 2 there is a **review step, and it is not a formality.** The
generated config is copied from what the edge serves, which includes rules that should
not survive: `ionic-traces.gsrpi.uk` on one (retired), and on zero a `torrents.gsrpi.uk`
rule that had never routed anything. Carrying that one across would have moved one's
torrent UI onto zero.

**The cutover has an outage in it**, deliberately: roughly two minutes on one, three or
four on zero, almost all of it DNS propagation. Avoiding it means two connectors at once,
which is either a second OpenRC service — the phantom-service trap in CLAUDE.md — or a
detached process Ansible has to babysit.

## Zero's hostnames

Snapshot; the file above is the source of truth. Regenerate with
`curl -s 127.0.0.1:20241/config` on the host.

| Hostname | Origin | |
|---|---|---|
| `ssh-zero.gsrpi.uk` | `ssh://127.0.0.1:22` | **behind Access** |
| `syncthing.gsrpi.uk` | `http://127.0.0.1:8384` | **behind Access** |
| `syncthing-server.gsrpi.uk` | `tcp://127.0.0.1:22000` | the sync protocol, not the UI |
| `immich.gsrpi.uk` | `http://127.0.0.1:2283` | no Access — 200 unauthenticated |
| `ssh-zero-dev-dd.gsrpi.uk` | `ssh://127.0.0.1:2222` | 502 normally; that container is usually down |
| `ssh-zero-dev-ds.gsrpi.uk` | `ssh://127.0.0.1:2223` | 502 normally, same |
| `ssh-zero-dev-or3.gsrpi.uk` | `ssh://127.0.0.1:2224` | **being retired** — or3-dev has its own tunnel and its own name, `or3-dev.gsrpi.uk`. Drop this rule and its DNS record once that is proven, or the container has two public doors and only the new one is behind Access |
| *(catch-all)* | `http_status:404` | |

`infra-dev.gsrpi.uk` is **not** here — it has its own tunnel, run by a connector inside
the container, which is the pattern *management-plane.md* § *Addressing* chose.
`or3-dev.gsrpi.uk` joined it on 2026-08-24. `dd-dev` and `ds-dev` are still on the host
tunnel; finishing that is Phase 5.

## One's hostnames

| Hostname | Origin | |
|---|---|---|
| `ssh-one.gsrpi.uk` | `ssh://127.0.0.1:22` | |
| `bookit.gsrpi.uk` | `http://127.0.0.1:3001` | this is `send2ereader`'s public name |
| `syncthing-torrents.gsrpi.uk` | `http://127.0.0.1:8384` | **behind Access**; origin down, 2c |
| `torrents.gsrpi.uk` | `http://127.0.0.1:8080` | **behind Access** |
| *(catch-all)* | `http_status:404` | |

`ionic-traces.gsrpi.uk` was retired 2026-08-23. Its DNS record still exists and points at
a deleted tunnel, so it resolves and fails; delete the record if you want the name gone.

## A tunnel is more objects than the dashboard's front page shows

This cost the most and was found by accident. Deleting zero's old tunnel returned
`1023: This tunnel has private network routes` — **WARP private-network routes**, a
separate object from public hostnames, invisible under Public Hostnames, and something
the migration knew nothing about.

Zero's old tunnel carried `192.168.86.20/32`. The cutover moved every hostname and left
that behind pointing at a tunnel with no connector, so WARP access to that address was
broken from the moment of the cycle — and **no check we had would ever have shown it**,
because everything we verified asked about hostnames.

It was only found because we tried to *delete* the tunnel, which is not a step a
migration necessarily takes. Had we left the old tunnel in place as harmless, the break
would still be there and unexplained.

WARP is not used on this fleet — that route was left from an experiment with WARP VPN to
zero and/or WARP-based Access auth — so it was dropped rather than moved. If WARP is ever
wanted, a route is one API call.

**The general form, which is the part worth keeping: enumerate a tunnel's objects before
believing a migration is complete.** At minimum the public hostnames
(`/cfd_tunnel/{id}/configurations`), the DNS records aimed at it, and the private network
routes (`/teamnet/routes?tunnel_id=`). The retire play now checks all three and refuses
on any of them.

## Landmines

- **A tunnel with private network routes cannot be deleted** (`1023`), and those routes
  are not shown anywhere you would look. `./2g retire <host> drop` deletes them; it is
  opt-in because dropping a route someone relies on is not undone by re-running.
- **Deleting a Public Hostname in the UI deletes its DNS record.** The CNAMEs are
  load-bearing; the dashboard's ingress entries are not, for the two locally-managed
  hosts. Clearing the dashboard "tidily" takes services down and presents as a broken
  tunnel.
- **A deleted tunnel cannot be recreated with the same UUID.** A DNS record aimed at one
  does not degrade, it breaks permanently. The retire play refuses unless every straggler
  is named with `-e abandon=`.
- **Never delete a tunnel that still has a CNAME aimed at it.** Check DNS first; the play
  does.
- **Leave infra-dev's Access application, policy and service token alone.** They are the
  way into the container. Different tunnel; confirm which you are looking at.
- **An Access service token is not an API token is not a tunnel token.** Three unrelated
  credentials sharing a word. `cloudflare-dev-tunnel.yml` prompts for the right one by
  saying which it is not.
- **`no_log` on a `uri` task hides the response as well as the headers.** It cost the only
  copy of a service token secret in August, and hid a `400` from the retire play in
  the same way. Register the result, let the task not fail, and print the API's own
  error list separately.

## Safe to delete

- **API tokens after use.** Rotation and migration need `Account -> Cloudflare Tunnel ->
  Edit` and `Zone -> DNS -> Edit` on `gsrpi.uk`, and nothing else.
- **Orphaned Access service tokens.** At least one is expected: created 2026-08-22, its
  secret censored by `no_log` before it was printed and unrecoverable. Identify the live
  one by the `client_id` in the phone's `~/.config/infra-dev/token`.
- **Duplicate Access applications** from the same failed runs.

## Open

- **`two` has not been migrated** — deferred deliberately, a week or so out. It is the
  smallest job (two hostnames) on the box with the least margin, and it is the lifeboat.
- **The fleet ssh hostnames have no service token.** `ssh-zero.gsrpi.uk` is behind Access
  and relies on a browser-obtained JWT that expires — it broke `ssh zero` from the phone
  on 2026-08-23 with `websocket: bad handshake`. Refresh with
  `cloudflared access login https://ssh-zero.gsrpi.uk`. A service token would end the
  recurrence, at the cost of a policy change per hostname.
- **The three `ssh-zero-dev-*` hostnames** have not been checked for Access.
