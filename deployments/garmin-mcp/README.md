# garmin-mcp

A [Garmin Connect](https://connect.garmin.com) MCP server that claude.ai reaches
as a claude.ai custom connector: ask Claude about your runs, gym sessions, sleep, HRV, training status
and the rest. Upstream is [`gabrielkpo/garmin-mcp-remote`](https://github.com/gabrielkpo/garmin-mcp-remote)
at the sha in `SOURCE`. That is nginx, plus a small OAuth 2.1 shim, in front of
[`Taxuspt/garmin_mcp`](https://github.com/Taxuspt/garmin_mcp). It runs on `one`, behind its own
tunnel's `cloudflared` sidecar, and publishes nothing on the host.

**What guards it** — no Cloudflare Access, because claude.ai's connector cannot pass Access:
- **The OAuth shim.** nginx refuses every request without the bearer token. The shim releases
  that token only to someone who types the **consent secret** on its consent page, and only to
  claude.ai's callback.
- **Reads, plus five writes you chose.** The server registers only what `GARMIN_ENABLED_TOOLS` in
  `compose.yaml` lists: Taxuspt's 108 read tools, and `upload_workout`, `upload_workouts`,
  `schedule_workout`, `unschedule_workout` and `set_activity_description` (added 2026-10-24).
  Nothing that deletes activities, weigh-ins or health data. Every deploy asks the live server
  for its tool list and stops if one is neither a read tool nor in `garmin_allowed_writes` in
  `ansible/deploy-hooks/garmin-mcp/probe.yml`. A leaked token could add workouts, change the calendar and overwrite
  activity notes, and read everything.

Why it is shaped this way, including the security audit: [`docs/decisions.md`](../../docs/decisions.md)
§ *garmin-mcp*. The full design and audit table were in `plans/garmin-mcp.md`, retired once the
first deploy passed every probe (2026-10-24); `git log --all -- plans/garmin-mcp.md` finds it.

## Deploying — from the control node

The first time, or after a rebuild of `one`: its tunnel, then the deploy.

```fish
cd ~/infra/ansible     # wherever the control node's checkout is
ansible-playbook playbooks/server-bring-up-deployment.yml -e deployment=garmin-mcp --check -K
ansible-playbook playbooks/server-bring-up-deployment.yml -e deployment=garmin-mcp -K
```

After a change in git, such as a bump or an allowlist edit, it is the redeploy play alone, which
never touches Cloudflare. `-e recreate=true` puts it through a redeploy when nothing changed:

```fish
ansible-playbook playbooks/server-deploy-compose.yml -e deployment=garmin-mcp -K
```

`server-deploy-garmin-mcp.yml`, the play this deployment had before, is kept until the first
real run of this path and then deleted (`plans/deploy-play-unification.md`).

**A first run pauses at the Garmin login**, with this block. It is the one step that cannot be
automated: Garmin asks for the MFA code inside the same process that started the login.

```fish
ssh -t one
# then, inside that shell:
cd ~/infra/deployments/garmin-mcp
sudo docker compose run --rm --name garmin-mcp-auth garmin-mcp garmin-mcp-auth; and sudo docker compose restart garmin-mcp
```

It asks for your Garmin email, then your password (not echoed and never stored; only the
resulting tokens are kept, in the `garmin-tokens` volume), then the code Garmin sends you. `--name`,
because `compose run` would otherwise reuse the running server's container name and fail on
the conflict. **The restart is not optional**: a failed login is final for the running server.
Run the block in a second terminal, then **press Enter in the terminal running the play**. It
waits for `/readyz` to say `ready` and prints the claude.ai connector URL.

What a deploy does, in order. The steps are `server-deploy-compose.yml`'s; this deployment's own
parts are its hooks in [`ansible/deploy-hooks/garmin-mcp/`](../../ansible/deploy-hooks/garmin-mcp/).
1. `one`'s checkout is pulled to your commit.
2. `preflight.yml` refuses a Garmin email or password in `.env`. On a first bring-up it also
   writes the four `.env` lines this deployment generates, and clones the upstream source.
3. The plan, and the question. Nothing below runs if you answer no.
4. `prepare.yml` writes the consent secret, `SRC_ROOT` and `PUBLIC_BASE_URL` into `.env`, and
   moves the source to the sha in `SOURCE`, at `$SRC_ROOT/garmin-mcp`.
5. `docker compose up`, which builds the image only when its tag is absent.
6. `probe.yml`, from the control node:
   - `/healthz` returns 200;
   - `/mcp` returns 401 without the token;
   - the OAuth metadata names this hostname;
   - `tools/list` returns only read tools and the allowed writes;
   - `/readyz` says `ready`, which is where the play pauses for the login.

## Connecting claude.ai

*Settings → Connectors → Add custom connector*:
- **URL:** `https://garmin-mcp.gsrpi.uk/mcp`.
- **OAuth Client ID / Secret:** leave blank.

claude.ai discovers the OAuth endpoints and opens a consent page. Paste the contents of
`~/.config/garmin-mcp/consent-secret` **on the control node**. The deploy created that file (mode 0600)
and never prints it. You do this once; the claude.ai connector refreshes itself after that.

## Day two

- **The Garmin login expires** after about six months. Tools start failing while `/healthz` stays
  green. **`/readyz` does not notice**: it is decided once, at start-up, so a running server reads
  `ready` with dead tokens. So redeploy with `-e recreate=true`: the new server logs in at
  start-up, `/readyz` reads `failed`, and the play prints the login block and waits for it. Or
  go straight to that block on `one`, then check with
  `sudo docker compose exec garmin-mcp curl -s http://127.0.0.1:8000/readyz`, which reaches the
  server behind nginx and needs no token. **Nothing alerts on this**; it is filed in
  `docs/management-plane.md`.
- **Rotating, after a suspected leak.**
  - The consent secret: delete `~/.config/garmin-mcp/consent-secret` on the control node.
  - The bearer token: delete the `MCP_BEARER_TOKEN=` line from `.env` on `one`.
  - Either or both: then redeploy with `-e recreate=true` and reconnect the claude.ai connector.
    A new consent secret changes nothing the plan can see, so without it nothing is redeployed.
  - Rotating the consent secret also voids every refresh token.
- **Bumping upstream.**
  1. Put the new sha in `SOURCE` and the new tag on `image:` in `compose.yaml`.
  2. Regenerate `GARMIN_ENABLED_TOOLS` with the command in the comment above it, which reads
     the new Taxuspt sha's source and never runs it. The diff is the review of what the bump
     exposes.
  3. Commit, push, and redeploy. The new tag is absent on `one`, so it builds.
- **Allowing a write tool**, such as `add_weigh_in` to log weight through Claude: add the name to
  `GARMIN_ENABLED_TOOLS` **and** to `garmin_allowed_writes` in
  `ansible/deploy-hooks/garmin-mcp/probe.yml`. That is one commit, then a redeploy. With only one of the two, the probe fails and says which name.
- **It is not answering.**
  - `/healthz` 530 or 1033 is the tunnel: `sudo docker logs garmin-mcp-cloudflared`.
  - `/healthz` 502 is the deployment: `sudo docker compose ps` here.
  - The probe's assert messages name which one.

## What not to do

- **No `GARMIN_EMAIL` or `GARMIN_PASSWORD` in `.env`,** though upstream's README says to put
  them there. The server would log in with the password silently whenever its tokens failed,
  and write a base64 copy of the tokens beside them. The deploy refuses to run while either line
  exists, and `compose.yaml` would not pass them through anyway.
- **No `env_file:` in `compose.yaml`.** The environment is explicit so that `.env` cannot add to
  what the container sees.
- **No `ports:` and no `network_mode: host`.** The sidecar reaches nginx over the project network;
  host networking would break both the ingress name and the port isolation from gluetun's 8080.
- **No `DAC_OVERRIDE` removal.** It looks unneeded on a first boot and crash-loops the container
  after the first login. The comment in `compose.yaml` explains why.
