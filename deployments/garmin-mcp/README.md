# garmin-mcp

A **read-only** [Garmin Connect](https://connect.garmin.com) MCP server that claude.ai reaches
as a custom connector: ask Claude about your runs, gym sessions, sleep, HRV, training status
and the rest. Upstream is [`gabrielkpo/garmin-mcp-remote`](https://github.com/gabrielkpo/garmin-mcp-remote)
at the sha in `SOURCE`. That is nginx, plus a small OAuth 2.1 shim, in front of
[`Taxuspt/garmin_mcp`](https://github.com/Taxuspt/garmin_mcp). It runs on `one`, behind its own
tunnel's `cloudflared` sidecar, and publishes nothing on the host.

**What guards it** — no Cloudflare Access, because claude.ai's connector cannot pass Access:
- **The OAuth shim.** nginx refuses every request without the bearer token. The shim releases
  that token only to someone who types the **consent secret** on its consent page, and only to
  claude.ai's callback.
- **Read-only.** The server registers only Taxuspt's read tools (`GARMIN_ENABLED_TOOLS` in
  `compose.yaml`). Every deploy asks the live server for its tool list and stops if a single
  one is not a read tool.

Why it is shaped this way, including the security audit: [`docs/decisions.md`](../../docs/decisions.md)
§ *garmin-mcp*. The full design and audit table were in `plans/garmin-mcp.md`, retired once the
first deploy passed every probe (2026-10-24); `git log --all -- plans/garmin-mcp.md` finds it.

## Deploying — from the phone

```fish
cd ~/infra/ansible     # wherever the phone's checkout is
ansible-playbook playbooks/server-deploy-garmin-mcp.yml --check -K   # prove: nothing is written
ansible-playbook playbooks/server-deploy-garmin-mcp.yml -K
```

**The first run stops at the Garmin login**, with this block. It is the one step that cannot be
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
the conflict. **The restart is not optional**: a failed login is final for the running server. Then **run the play
again**. It finishes with every probe passing and prints the connector URL.

What the play does, in order:
1. The tunnel and DNS, through `server-create-stack-tunnel.yml`.
2. `.env`.
3. The checkout, at `$SRC_ROOT/garmin-mcp`.
4. `docker compose up`, which builds the image only when its tag is absent.
5. The probes, from the phone:
   - `/healthz` returns 200;
   - `/mcp` returns 401 without the token;
   - the OAuth metadata names this hostname;
   - `/readyz` says `ready`;
   - `tools/list` returns read tools only.

## Connecting claude.ai

*Settings → Connectors → Add custom connector*:
- **URL:** `https://garmin-mcp.gsrpi.uk/mcp`.
- **OAuth Client ID / Secret:** leave blank.

claude.ai discovers the OAuth endpoints and opens a consent page. Paste the contents of
`~/.config/garmin-mcp/consent-secret` **on the phone**. The play created that file (mode 0600)
and never prints it. You do this once; the connector refreshes itself after that.

## Day two

- **The Garmin login expires** after about six months. Tools start failing while `/healthz` stays
  green. **`/readyz` does not notice**: it is decided once, at start-up, so a running server reads
  `ready` with dead tokens, and a re-run of the play passes. So run
  `sudo docker compose restart garmin-mcp` first, then re-run the play: now `/readyz` reads
  `failed`, and the play prints the login block. Or go straight to that block. **Nothing alerts on this**; it is filed in
  `docs/management-plane.md`.
- **Rotating, after a suspected leak.**
  - The consent secret: delete `~/.config/garmin-mcp/consent-secret` on the phone.
  - The bearer token: delete the `MCP_BEARER_TOKEN=` line from `.env` on `one`.
  - Either or both: then re-run the play and reconnect the connector.
  - Rotating the consent secret also voids every refresh token.
- **Bumping upstream.**
  1. Put the new sha in `SOURCE` and the new tag on `image:` in `compose.yaml`.
  2. Regenerate `GARMIN_ENABLED_TOOLS` with the command in the comment above it, which reads
     the new Taxuspt sha's source and never runs it. The diff is the review of what the bump
     exposes.
  3. Commit, push, and re-run the play. The new tag is absent on `one`, so it builds.
- **Allowing a write tool**, such as `add_weigh_in` to log weight through Claude: add the name to
  `GARMIN_ENABLED_TOOLS` **and** to `garmin_allowed_writes` in the play. That is one commit, then
  a re-run. With only one of the two, the probe fails and says which name.
- **It is not answering.**
  - `/healthz` 530 or 1033 is the tunnel: `sudo docker logs garmin-mcp-cloudflared`.
  - `/healthz` 502 is the stack: `sudo docker compose ps` here.
  - The play's assert messages name which one.

## What not to do

- **No `GARMIN_EMAIL` or `GARMIN_PASSWORD` in `.env`,** though upstream's README says to put
  them there. The server would log in with the password silently whenever its tokens failed,
  and write a base64 copy of the tokens beside them. The play refuses to run while either line
  exists, and `compose.yaml` would not pass them through anyway.
- **No `env_file:` in `compose.yaml`.** The environment is explicit so that `.env` cannot add to
  what the container sees.
- **No `ports:` and no `network_mode: host`.** The sidecar reaches nginx over the project network;
  host networking would break both the ingress name and the port isolation from gluetun's 8080.
- **No `DAC_OVERRIDE` removal.** It looks unneeded on a first boot and crash-loops the container
  after the first login. The comment in `compose.yaml` explains why.
