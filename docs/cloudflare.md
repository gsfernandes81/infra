# Cloudflare

What exists, which parts are load-bearing, and what is safe to delete. Written
2026-08-23, when it turned out the repo recorded **one** of zero's eight public
hostnames and nothing at all about which Cloudflare objects a service depends on.
Rewritten the same day, twice, because most of what it first said stopped being true.

## Where routing lives, per host

| Host | Tunnel | Managed | Ingress rules are in |
|---|---|---|---|
| `zero` | `ce28c17c-a722-4ba1-8e46-21985337f13f` | **locally** | `hosts/zero/system/cloudflared-config.yml` |
| `one` | `1e7fde2e-ac2f-4a5e-8ad4-591208c1e2a6` | **locally** | `hosts/one/system/cloudflared-config.yml` |
| `two` | `f9407a5c-9361-4b59-85ab-a1f61811fb37` | **locally** | `hosts/two/system/cloudflared-config.yml` |
| `infra-dev` | separate, in the container | locally | `dev/entrypoint.sh` writes it |
| `or3-dev` | separate, in the container | locally | the same `dev/entrypoint.sh`, from the base image |

**All three now work the same way**, since 2026-08-29: the tracked file **is** the
routing — edit it, commit it, `bin/install-system-file cloudflared-config.yml`, and
cycle. `two` was the last holdout and carried only a tunnel id, credentials path and
metrics port while its ingress lived at Cloudflare; the paragraph below about not
clearing its remote configuration described that state and no longer applies to any host
here. It is kept because the RULE it states is still true of any remotely-managed tunnel.

## The rule that makes that distinction matter

**cloudflared prefers a tunnel's REMOTE configuration whenever one exists, and ignores
local ingress silently** — no error, nothing in any log. Established on zero on
2026-08-23 by clearing the remote copy and watching the connector drop from nine rules to
one within fifteen seconds.

Nothing distinguishes an ignored local config from one in force: both report the same
rules at `127.0.0.1:20241/config`. That claim survived a day of work, three documents and
two commit messages before anyone tested it.

**⚠︎ HISTORICAL — `two` was migrated on 2026-08-29 and has no remote configuration any
more.** While it did: do not clear the remote configuration; it was not stale, it was what
served. `PUT .../cfd_tunnel/{id}/configurations` does not touch DNS, and a `GET`
first makes it byte-exactly reversible — but there is no reason to run it.

## Getting ingress rules into git — how it was actually done

`config_src` is **create-time only**. `PATCH .../cfd_tunnel/{id}` with
`{"config_src":"local"}` is rejected (`1002 Tunnel not found`, on a URL where `GET` works
and where `PATCH` with `tunnel_secret` had succeeded an hour earlier). Emptying the remote
config does not work either — an empty remote config still wins over a local one.

So each host gets a **new** tunnel created with `config_src: local`, and its CNAMEs
repointed. Three playbooks, by blast radius:

```
ansible-playbook playbooks/server-create-tunnel.yml     -e target=<host> -K
ansible-playbook playbooks/server-cutover-tunnel.yml -e target=<host> -e ansible_host=<host>-two -K
ansible-playbook playbooks/server-delete-tunnel.yml  -e target=<host> -K
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

## Two's hostnames

Snapshot; `hosts/two/system/cloudflared-config.yml` is the source of truth. Regenerate
with `curl -s 127.0.0.1:20241/config` on the host.

| Hostname | Origin | |
|---|---|---|
| `ssh-two.gsrpi.uk` | `ssh://127.0.0.1:22` | the lifeboat's own door; **behind Access**, per-client service tokens |
| ~~`anchor-two.gsrpi.uk`~~ | ~~`http://127.0.0.1:8080`~~ | **removed 2026-08-29.** It served destiny-director's anchor bot while that was trialled on `two`; the experiment ended and nothing has listened on 8080 since. It was **502 always**, not "502 when the bot is down" — `deployments/destiny-director/compose.yaml` has its `ports:` block commented out. Its CNAME was deleted in 2i, 2026-10-25 |

Both carried identical `originRequest` settings, equal to the tunnel default, so nothing
was lost in the rewrite — the assert that would have caught a `noTLSVerify` or
`httpHostHeader` on the one tunnel nobody had inspected did not fire.

## Zero's hostnames

Snapshot; the file above is the source of truth. Regenerate with
`curl -s 127.0.0.1:20241/config` on the host.

| Hostname | Origin | |
|---|---|---|
| `ssh-zero.gsrpi.uk` | `ssh://127.0.0.1:22` | **behind Access**, per-client service tokens |
| `syncthing.gsrpi.uk` | `http://127.0.0.1:8384` | **behind Access** |
| `syncthing-server.gsrpi.uk` | `tcp://127.0.0.1:22000` | the sync protocol, not the UI |
| `immich.gsrpi.uk` | `http://127.0.0.1:2283` | no Access — 200 unauthenticated |
| *(catch-all)* | `http_status:404` | |

`ssh-zero-dev-dd`, `-ds` and `-or3` are gone from zero's ingress: or3's in `7bb2075` once it
had its own tunnel, `dd` and `ds` under 2i on 2026-08-29. They were
doors zero opened on a container's behalf, and each was a second way in beside that
container's own connector.

**Removing a rule does not remove its CNAME.** A record still pointing at zero's tunnel
now gets the catch-all 404, which reads like a container that is merely down. All four —
`ssh-zero-dev-dd`, `-ds`, `-or3` and `anchor-two` — were deleted on 2026-10-25, verified
NXDOMAIN on two resolvers.

`infra-dev.gsrpi.uk` is **not** here — it has its own tunnel, run by a connector inside
the container, which is the pattern *management-plane.md* § *Addressing* chose.
`or3-dev.gsrpi.uk` joined it on 2026-08-24. **`dd-dev` and `ds-dev` have no tunnel of
their own yet** — that is Phase 5 — and they are not running; until then they are reached
through `ssh zero` and the published loopback ports 2222/2223.

## One's hostnames

| Hostname | Origin | |
|---|---|---|
| `ssh-one.gsrpi.uk` | `ssh://127.0.0.1:22` | **behind Access**, per-client service tokens |
| `syncthing-torrents.gsrpi.uk` | `http://127.0.0.1:8384` | **behind Access**; origin down, 2c |
| `torrents.gsrpi.uk` | `http://127.0.0.1:8080` | **behind Access** |
| *(catch-all)* | `http_status:404` | |

`calibre-web.gsrpi.uk` is **not** here, though it is placed on `one` (committed 2026-10-24;
the tunnel and hostname exist once its setup's step 4 has run): it has its own tunnel,
served by a `cloudflared` sidecar in its compose project, and its routing is
[`deployments/calibre-web/cloudflared.yml`](../deployments/calibre-web/cloudflared.yml).
**Behind Access**, except `/kobo/`, which a second, more specific application bypasses for
the Kobo's sync. One **Request Header Transform Rule** sets `X-Scheme: https` on requests to
it — Calibre-Web needs it to build the Kobo's download links (its `edge.yml` says why); the
rule's `ref` is `infra_calibre_web_request_headers`, and it is the only object in the zone's
transform rules this repo manages. Made by `ansible/playbooks/server-create-deployment-tunnel.yml`; the pattern is
[`decisions.md`](decisions.md) § *Sidecar, not baked-in*.

`garmin-mcp.gsrpi.uk` is not here either (deployed 2026-10-24, tunnel `efa6e10e`): its own tunnel and sidecar, the
same play underneath, routing in
[`deployments/garmin-mcp/cloudflared.yml`](../deployments/garmin-mcp/cloudflared.yml). **No
Access, by design**: its only client is claude.ai's custom connector, which cannot pass Access,
and the gate is the OAuth shim inside the deployment. It makes no Access objects and no
transform rules.

`bookit.gsrpi.uk` left this table on 2026-10-25. It is `send2ereader`'s public name, now
served by that deployment's own sidecar, with the routing in
[`deployments/send2ereader/cloudflared.yml`](../deployments/send2ereader/cloudflared.yml).
It keeps the name `bookit` through `subdomain:` in its `edge.yml`. No Access, because an
e-reader's browser is the client. The cutover in
[its README](../deployments/send2ereader/README.md) was run by the owner, who reported the
whole of it done on 2026-10-25.

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
routes (`/teamnet/routes?tunnel_id=`). The delete play now checks all three and refuses
on any of them.

## Landmines

- **A tunnel with private network routes cannot be deleted** (`1023`), and those routes
  are not shown anywhere you would look. `server-delete-tunnel.yml -e drop_private_routes=true`
  deletes them (the `./2g` wrapper that shortened this is gone with 2g); it is
  opt-in because dropping a route someone relies on is not undone by re-running.
- **Deleting a Public Hostname in the UI deletes its DNS record.** The CNAMEs are
  load-bearing; the dashboard's ingress entries are not, for the two locally-managed
  hosts. Clearing the dashboard "tidily" takes services down and presents as a broken
  tunnel.
- **A deleted tunnel cannot be recreated with the same UUID.** A DNS record aimed at one
  does not degrade, it breaks permanently. The delete play refuses unless every straggler
  is named with `-e abandon=`.
- **Never delete a tunnel that still has a CNAME aimed at it.** Check DNS first; the play
  does.
- **Leave infra-dev's Access application, policy and service token alone.** They are the
  way into the container. Different tunnel; confirm which you are looking at.
- **An Access service token is not an API token is not a tunnel token.** Three unrelated
  credentials sharing a word. Every play that talks to Cloudflare reads the API token
  from `~/.config/cloudflare/api-token` and prints how to mint one if it is missing
  (`ansible/README.md` § *The Cloudflare API token*); the service tokens are minted per
  client by `client-home-ssh-config.yml`; the tunnel token, once passed as `--token` in
  argv, is now the tunnel credentials file.
- **A service token in a policy cannot be deleted — rotate it.** `400`, code `12139`,
  `service_token_in_use`. Every token this fleet uses is named by an Access policy, so
  this is the normal case, not an edge one. `POST …/service_tokens/{id}/rotate` keeps the
  id and the policy, returns a fresh `client_id`/`client_secret`, and invalidates every
  client holding the old pair. Deleting is only for a token nothing references.
- **`no_log` on a `uri` task hides the response as well as the headers.** It cost the only
  copy of a service token secret in August, and hid a `400` from the delete play in
  the same way. Register the result, let the task not fail, and print the API's own
  error list separately.

## Safe to delete

**Swept by the owner on 2026-10-25**, the dashboard sweep's plan with it. The list stays as
what to look for after the next failed provisioning run. Since 2026-10-04 every live service
token is named `<container>-<client>` and is the `TUNNEL_SERVICE_TOKEN_ID` in some client's
`~/.config/<container>/token`; anything else is a candidate, removed from its policy first.

- **API tokens after use.** Rotation and migration need `Account -> Cloudflare Tunnel ->
  Edit`, `Zone -> Zone -> Read` and `Zone -> DNS -> Edit` on `gsrpi.uk`, and nothing else.
  **Zone -> Zone -> Read is not optional and was missing from this list**: the cutover
  begins by finding the zone id with `GET /zones?name=gsrpi.uk`, which a tunnel-only token
  cannot do. It cost a run on `two`, 2026-08-28 — a 403 whose body was censored by
  `no_log`, so the answer was in the response nobody could see.
- **Orphaned Access service tokens.** At least one is expected: created 2026-08-22, its
  secret censored by `no_log` before it was printed and unrecoverable. Identify the live
  one by the `client_id` in the phone's `~/.config/infra-dev/token`.
- **Duplicate Access applications** from the same failed runs.

## Open

- **Each sshd still offers `keyboard-interactive`**, because `sshd-infra.conf` does not
  turn it off. sshd is the second layer behind the fleet's Access gate (keys only, no
  root, no passwords), and on Alpine's build without PAM that method probably accepts
  nothing, but turning it off would settle it. It is a change to sshd on the boxes you
  reach through it, for the two-phase procedure, and not chosen yet.
