# Plan — garmin-mcp on `one`, behind its own tunnel

**Approved design, built in `1322e4a`, not yet deployed.** Agreed with the owner on 2026-10-24, after a security
audit of the upstream repo and nine alternatives. Nothing here is deployed. When the stack is
running and the probe below passes, the reasoning moves to `docs/decisions.md` and this file
is deleted, as the three-folder rule says.

**No longer blocked.** The shared tunnel play landed with calibre-web in `7bda874`, along with
the sidecar decision (`docs/decisions.md` § *Sidecar, not baked-in*). This plan builds on both
and does not repeat them. The steps are in `plans/garmin-mcp-implementation.md`.

## What it is

A remote MCP server that lets claude.ai read the owner's Garmin Connect data — runs, gym
sessions, sleep, HRV, training status — through a custom connector.

- **Upstream:** [`gabrielkpo/garmin-mcp-remote`](https://github.com/gabrielkpo/garmin-mcp-remote)
  at `0cf102c139c78287bbb4a7fce5f597b3de3764c8` (v0.1.3). One image, three processes under
  supervisord: nginx on 8080, a 300-line OAuth 2.1 shim on 127.0.0.1:8001, and
  [`Taxuspt/garmin_mcp`](https://github.com/Taxuspt/garmin_mcp) on 127.0.0.1:8000, pinned by
  upstream's Dockerfile at `30324f70ccb50c2570126501df17acf0b5572083`.
- **Read-only.** Taxuspt registers about 155 tools, 23 of them destructive (`delete_activity`,
  and `delete_weigh_ins`, which deletes the whole day by default). Only its `READ_ONLY_TOOLS`
  are enabled. The owner may want writes later. That would be a reviewed diff to the allowlist,
  not a mode switch.

## Why `one`

- **Not `two`:** an armv6 Pi 1 with about 475 MB of RAM. There is no published image, and the
  dependencies (`pydantic-core`, `curl-cffi`) have no armv6 wheels.
- **Not `zero`:** critical and remote. An internet-facing third-party service holding a long-lived
  Garmin session should fail somewhere a reboot costs nothing.
- **`one`:** a non-critical aarch64 Pi 4 that already builds a stack from source.
  - The token volume lives on the root filesystem under `/var/lib/docker`, not on `/media`, so
    the mount guards do not come into it.
  - Garmin traffic leaves through the home IP, not gluetun's VPN.

## Why Taxuspt and not Garmin's new Personal API

Garmin launched an official [Personal API](https://developer.garmin.com/gc-developer-program/personal/personal-api)
on 2026-10-21. You create a key in Connect Web with an expiry you choose, delete it to revoke
it, and it only reads. As a credential it is clearly better than a scraped SSO session. The
servers for it lost for these reasons:

- **Coverage.** Its 26 endpoints carry rich per-activity detail: running dynamics, training
  effect, training load, a per-run VO₂ max, HR zones and splits. Strength comes only as
  per-exercise summaries: sets, reps, max weight and volume. Missing:
  - Set-by-set strength detail.
  - Training status, morning readiness, and the trends of load and VO₂ max.
  - Race predictions, the personal-record list, endurance, hill score and running tolerance.
  - Recovery time, gear, and workouts/plans.

  The owner mostly runs and lifts, and wants those.
- **Maturity.** `Mason-Levyy/garmin-personal-mcp` and `Shape-Calendar/garmin-personal-mcp` were
  2–3 days old at audit.

**Revisit when** one of them matures *and* surfaces set-level strength data. The activity FIT
file is downloadable through the API and contains the sets, but neither server passes them to
the model. Switching backends changes only `deployments/garmin-mcp/`; the tunnel and the play
stay.

## Security audit — what was found, and what this design does about it

The shim was attacked in-process: 44 attempts, 43 held. They covered bearer edge cases, the
redirect allowlist, PKCE, code reuse, forged and expired refresh tokens, and XSS on the consent
page. No path to the bearer token exists without `MCP_CONSENT_SECRET` or a refresh token signed
with it.

| Finding | Handled by |
|---|---|
| A leaked bearer means the whole Garmin account, including deletes | `GARMIN_ENABLED_TOOLS` = read-only allowlist; the probe proves it |
| Transitive deps resolve fresh at every build (`pip install git+…` ignores `uv.lock`) | Sha-tagged literal `image:` with `build: policy`: Compose builds only when the tag is absent, so deps freeze between reviewed bumps |
| Upstream silently logs in with `GARMIN_PASSWORD` if set, and writes a base64 copy of the tokens | The play refuses a `.env` holding `GARMIN_EMAIL` or `GARMIN_PASSWORD` |
| Metadata built from the Host header when `PUBLIC_BASE_URL` is unset | Always set, derived from the hostname |
| Unauthenticated hits grow Docker's json-file log on one's SD card | `logging: max-size` |
| Global consent lockout: strangers can block *new* connections indefinitely (reproduced) | Accepted. Existing connections refresh without going through it |
| Consent page frameable; shows an attacker-chosen client name | Accepted. Codes can only reach claude.ai's callback |
| `/register` 500s on JSON that is not an object | Cosmetic |

**Known risks, deliberately not reported upstream (owner, 2026-10-24):** the last four rows,
plus the dependency-pinning one. The owner may file them if this stays in use.

**Accepted residual:** if the bearer leaks from claude.ai's side, it gives read access to health
and location history until it is rotated.

## The stack — `deployments/garmin-mcp/`

- **`compose.yaml`**, `name: garmin-mcp`, two services on the project network. `no network_mode:
  host` is load-bearing and is stated in a comment: without it, in-container ports cannot
  collide with `one`'s (gluetun holds 8080 on the host), and `garmin-mcp` resolves by name.
  - **`garmin-mcp`** — `build: ${SRC_ROOT:?}/garmin-mcp`, `image:
    garmin-mcp-remote:0cf102c`.
    - **No `ports:`.** Named volume `garmin-tokens` at `/data/garminconnect`;
      `restart: unless-stopped`.
    - `mem_limit: 512m`, and left there: there is headroom on a Pi 4, and "tighten later" would
      be a planned second session.
    - `logging: max-size`. `security_opt: no-new-privileges`.
    - `cap_drop: ALL`, adding back `CHOWN`, `SETUID`, `SETGID` and **`DAC_OVERRIDE`,
      unconditionally**. Upstream's entrypoint runs `chown -R` as root on every start, under
      `set -e`, and the auth step leaves the token directory at 0700 owned by `app`
      (`token_utils.py:33`). Without `DAC_OVERRIDE`, root cannot read into that directory, so
      the container crash-loops — but **only after the first successful auth**. A first boot
      over an empty directory would wrongly prove the capability unneeded.
    - `GARMIN_MCP_STATELESS_HTTP=true`. Upstream defaults to stateful sessions, which the MCP SDK
      drops after 30 minutes idle, and claude.ai reports the resulting 404 as a failed tool call
      (Taxuspt README, the `GARMIN_MCP_STATELESS_HTTP` entry). Without it, the first call after
      any quiet half hour fails.
    - `GARMIN_ENABLED_TOOLS` is a literal list in this file, so a sha bump or a future write tool
      shows up as a diff.
  - **`cloudflared`** — `cloudflare/cloudflared:<version>` — the latest release when this is built, written as a literal and named in the commit message;
    `tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`.
    - The config and credentials are mounted `:ro`; `mem_limit: 128m`.
    - Outside 2h's staggered autoupdate by design: an update is a tag bump plus a redeploy.
- **`cloudflared.yml`** — the tracked ingress: `garmin-mcp.gsrpi.uk → http://garmin-mcp:8080`,
  then `http_status:404`.
- **`.env.example`** — `SRC_ROOT`, `MCP_BEARER_TOKEN`, `MCP_CONSENT_SECRET`, `PUBLIC_BASE_URL` and
  the tunnel credentials path, every one `:?`. **No Garmin email or password**, and a comment
  saying why.
- **`SOURCE`** — the upstream URL and `0cf102c139c78287bbb4a7fce5f597b3de3764c8`.
- **`hosts/one/garmin-mcp`** → `../../deployments/garmin-mcp`.

**The allowlist is derived by reading, never importing,** `tool_annotations.py` at the pinned
Taxuspt sha. It is cross-checked against the `@app.tool()` registrations and against
`ADDITIVE_TOOLS` and `DESTRUCTIVE_TOOLS`, and the derivation is redone with every sha bump.

## The edge — `server-create-stack-tunnel.yml`, as it landed

The edge is calibre-web's `server-create-stack-tunnel.yml`, run with `stack=garmin-mcp`. It
was reviewed from this side on 2026-10-24 against the four points agreed for it (Access
optional, credentials outside the checkout at 65532:0600, the 200/201 handling and
dead-tunnel assert intact, a real `--check`), and landed in `7bda874`.

- **`deployments/garmin-mcp/edge.yml` says `access: none`,** so the play makes no Access
  objects and skips its login probe. claude.ai's connector cannot pass Access; the shim is
  the gate.
- **It writes `TUNNEL_ID` and `TUNNEL_CREDENTIALS` into `.env`,** creating it at 0600, and the
  credentials to `~/.garmin-mcp-secrets/tunnel.json`, 65532:65532 at 0600, outside the
  checkout.
- **It proves the host's `compose.yaml`, `edge.yml` and `cloudflared.yml` match the phone's,**
  and hands the host and `stack_hostname` to later plays through `add_host`.
- **garmin's play imports it** and adds only garmin's own steps. The sidecar is calibre-web's,
  pinned identically.

## The play — `ansible/playbooks/server-deploy-garmin-mcp.yml`

Run from the phone with `-K`. Every step looks before it acts, so a re-run after a failure is
how you finish.

1. **The edge** — imports `server-create-stack-tunnel.yml`: the tunnel and the
   `garmin-mcp.<dns_zone>` CNAME.
2. **Source** — the `git` module checks out the pinned sha into `$SRC_ROOT/garmin-mcp`, the path
   `bin/check-sources` looks for. It refuses a dirty checkout and moves a clean one to the
   pinned sha, so a reviewed bump needs no manual step. It never forces.
3. **Secrets** — the consent secret is `lookup('password', '~/.config/garmin-mcp/consent-secret
   …')` on the control node. That one line creates the 0600 file the first time and reads it
   afterwards, the same place the Cloudflare API token file lives. It is never printed, because
   CLAUDE.md keeps secrets out of scrollback. The bearer is generated on `one` and shown to
   nobody.
   - `.env` is written at 0600, and the play fills only missing values. **Rotation is deleting
     the value and re-running**: the consent secret's file on the phone, or the bearer's line in
     `.env`. There is no rotate flag.
   - A `.env` holding `GARMIN_EMAIL` or `GARMIN_PASSWORD` stops the play. This is one task, kept
     because upstream's own README tells you to put the password there.
4. **Build and up** — `community.docker.docker_compose_v2` with `build: policy`, the module's
   default. Compose then builds only when the literal `image:` tag is absent. A container is
   recreated only when its config changed.
5. **The MFA gate, read from `/readyz`** — no root inspection of the volume. Login runs in the
   background, so the play polls `/readyz` (authorised) until it leaves `pending`. On `failed`,
   it stops and prints the one interactive step, written for fish and a TTY: `ssh -t one`, then
   a block to paste inside it.
   - The block is a sudo `docker compose … run --rm garmin-mcp garmin-mcp-auth`, **followed by
     `docker compose … restart garmin-mcp`**. A failed background login is terminal for the
     server process — it says "restart the server" (`__init__.py:351`) — and a re-run of the
     play recreates nothing when the config is unchanged, so without the restart the probe would
     fail again.
   - Upstream's `auth_cli.py` prompts for the email, reads the password with `getpass` and asks
     for the MFA code, so the password never reaches a file or an environment variable. The
     tokens land in `$GARMINTOKENS/garmin_tokens.json`, which is where the server reads them.
   - Then re-run the play. MFA cannot be automated: the code is requested inside the same
     process that started the login.
   - The printed reason says `failed` can also mean a Garmin 429 or expired tokens; the fix is
     the same block.
6. **The probe, end to end from the control node.** Each step is calibrated against the running
   stack before it is trusted.
   - `/healthz` → 200: the tunnel and nginx.
   - `/mcp` unauthenticated → 401: nginx is up and gating.
   - `/.well-known/oauth-protected-resource` names `https://garmin-mcp.gsrpi.uk/mcp`: proves
     `PUBLIC_BASE_URL`. The 401's `WWW-Authenticate` cannot prove it, because nginx builds that
     header from `$host`.
   - An authorised `tools/list` — a bare POST, which stateless mode allows without an
     `initialize`. It sends `Accept: application/json, text/event-stream`, and the JSON is read
     from the SSE `data:` line. **This is the read-only proof**; a set variable is not. Every
     served name must match `^(get|count|search)_`, or appear in the play's
     `garmin_allowed_writes` list, which is empty today. This holds for all 108 read tools and
     none of the 47 write tools at the pinned sha. It carries no second copy of the allowlist,
     and a future write tool is one name in that list.
   - `/readyz` → `ready` (from step 5).
   - Memory in use is printed, as a record.
   - Every `debug` whose output is the point carries `changed_when: true`.

**Then** add a claude.ai custom connector for `https://garmin-mcp.gsrpi.uk/mcp` and paste the
consent secret from the phone's file.

## Failure modes

- **Garmin tokens expire** (~6 months): `/healthz` stays 200, tools error, `/readyz` is not ready.
  Re-do the MFA step. **Nothing on the fleet alerts**; filed, not built.
- **Garmin rate-limits the auth step (429):** upstream makes one attempt and stops. Retry later.
- **A leak:** delete the consent secret's file on the phone and/or the bearer's line in `.env` on `one`, re-run the play, then reconnect the connector.
- **`one` reboots:** the stack returns under `unless-stopped`. Nothing depends on `/media`.

## Verification before commit (`infra-dev`, no route to the fleet)

- **`docker compose config`** with a static compose binary in the scratchpad (sha256 checked
  against the release) and a stub `.env`. It needs no daemon. Its output is never committed.
- **Ansible:** `ansible-playbook --syntax-check` and `--check` against stubs, with
  `ANSIBLE_CONFIG` pointed at the checkout under test.
- **The allowlist cross-check** above.
- **The two-way secret scan and `git diff --stat`.**
- **Review:** a Fable review and autofix, or `/code-review xhigh` while Fable is out, with the
  fixes in a second commit.
- **Not verifiable here, and the handover says so:** the aarch64 build, the MFA step, the probe
  and the real memory figures. A Fable advisor reviewed this plan on 2026-10-24. Its five
  first-run breakers are folded in above: stateless HTTP, the restart after MFA, `DAC_OVERRIDE`,
  `build: policy`, and what the 401 proves. So are three of its simplifications. The play's probe is the proof, on the owner's first run.

## Docs, in the same commit as the stack

- **`docs/decisions.md`** — two rows, citing calibre-web's sidecar row rather than restating it:
  - Host, and no Access in front.
  - Taxuspt read-only over the Personal API, with the coverage reason and the revisit trigger.
- **`README.md`** — the fleet table, and a ports row: *none published; own tunnel*.
- **`docs/cloudflare.md`** — a hostname row for `garmin-mcp.gsrpi.uk`, marked as its own tunnel,
  not one's host tunnel.
- **`docs/management-plane.md` phase table** — filed, not started:
  - No alert on Garmin token expiry.
  - The Personal API revisit.
  - The shim findings, kept and unfiled.
- **This file is deleted** in the commit that finishes the work.
