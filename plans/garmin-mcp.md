# Plan — garmin-mcp on `one`, behind its own tunnel

**Approved design, not yet built.** Agreed with the owner on 2026-10-24, after a security
audit of the upstream repo and nine alternatives. Nothing here is deployed. When the stack is
running and the probe below passes, the reasoning moves to `docs/decisions.md` and this file
is deleted, as the three-folder rule says.

**Blocked on one thing:** the shared tunnel play described in *The edge* below, which
`workspace-46` is writing for the calibre-web stack. Calibre-web lands first and records the
sidecar decision; this plan builds on that and does not repeat it.

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
| Transitive deps resolve fresh at every build (`pip install git+…` ignores `uv.lock`) | Sha-tagged image, build policy `missing`: deps freeze between reviewed bumps |
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
  - **`garmin-mcp`** — `build: ${SRC_ROOT:?}/garmin-mcp-remote`, `image:
    garmin-mcp-remote:0cf102c`.
    - **No `ports:`.** Named volume `garmin-tokens` at `/data/garminconnect`;
      `restart: unless-stopped`.
    - `mem_limit: 384m`, tightened after the first real run.
    - `logging: max-size`. `security_opt: no-new-privileges`.
    - `cap_drop: ALL`, adding back `CHOWN`, `SETUID`, `SETGID` and `DAC_OVERRIDE`. The last is
      dropped if the build proves it unneeded.
    - `GARMIN_ENABLED_TOOLS` is a literal list in this file, so a sha bump or a future write tool
      shows up as a diff.
  - **`cloudflared`** — `cloudflare/cloudflared:<version>` — the latest release when this is built, written as a literal and named in the commit message;
    `tunnel --no-autoupdate --config /etc/cloudflared/config.yml run`.
    - The config and credentials are mounted `:ro`; `mem_limit: 64m`.
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

## The edge — the shared tunnel play

From `workspace-46`: sections 0–2 of `_dev-container-tunnel.yml` (zone and account, the tunnel
with its dead-tunnel assert, the CNAME) lifted into a tasks file shared with that play, with
Access as a separate step callers opt into. **garmin-mcp does not opt in**, because claude.ai's
connector cannot pass Access; the shim is the gate.

Before that change is pushed, this side reviews it for four things:
- Access is optional.
- The credentials land outside `~gavin/infra`, owned by 65532 with mode 600.
- The 200/201 handling and the dead-tunnel assert come through the extraction unchanged.
- `--check` is still a real dry run.

## The play — `ansible/playbooks/server-deploy-garmin-mcp.yml`

Run from the phone with `-K`. Every step looks before it acts, so a re-run after a failure is
how you finish.

1. **The edge** — imports the shared play: the tunnel and the `garmin-mcp.<dns_zone>` CNAME.
2. **Source** — the `git` module checks out the pinned sha into `$SRC_ROOT/garmin-mcp-remote`.
   It refuses a dirty checkout or a different sha, and never forces.
3. **Secrets** — the consent secret is generated on the control node into
   `~/.config/garmin-mcp/consent-secret` (0600), the same pattern as the Cloudflare API token
   file, and is never printed. The bearer is generated on `one` and shown to nobody.
   - `.env` is written at 0600. Missing values are filled; existing ones change only under
     `-e rotate=bearer|consent`.
   - A `.env` holding `GARMIN_EMAIL` or `GARMIN_PASSWORD` stops the play.
4. **Build and up** — `community.docker.docker_compose_v2` with build policy `missing`. A
   container is recreated only when its config changed.
5. **The MFA gate** — if the token volume holds no Garmin tokens, the play stops and prints the
   one interactive step, written for fish and a TTY: `ssh -t one`, then inside it a sudo
   `docker compose … run --rm garmin-mcp garmin-mcp-auth`. Upstream's `auth_cli.py` prompts for
   the email, reads the password with `getpass` and asks for the MFA code, so the password never
   reaches a file or an environment variable. Then re-run the play. MFA cannot be automated: the
   code is requested inside the same process that started the login.
6. **The probe, end to end from the control node.** Each step is calibrated against the running
   stack before it is trusted.
   - `/healthz` → 200: the tunnel and nginx.
   - `/mcp` → 401, with a `WWW-Authenticate` naming `https://garmin-mcp.gsrpi.uk`: proves
     `PUBLIC_BASE_URL`.
   - An authorised `tools/list` must equal the allowlist exactly, with no additive or destructive
     names. **This is the read-only proof**; a set variable is not.
   - `/readyz`, authorised (nginx gates it like `/mcp`) → the Garmin login is live.
   - Memory in use is printed, for tightening the limits.
   - Every `debug` whose output is the point carries `changed_when: true`.

**Then** add a claude.ai custom connector for `https://garmin-mcp.gsrpi.uk/mcp` and paste the
consent secret from the phone's file.

## Failure modes

- **Garmin tokens expire** (~6 months): `/healthz` stays 200, tools error, `/readyz` is not ready.
  Re-do the MFA step. **Nothing on the fleet alerts**; filed, not built.
- **Garmin rate-limits the auth step (429):** upstream makes one attempt and stops. Retry later.
- **A leak:** `-e rotate=bearer` and/or `-e rotate=consent`, then reconnect the connector.
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
  and the real memory figures. The play's probe is the proof, on the owner's first run.

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
