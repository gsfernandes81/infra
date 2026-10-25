# Plan: one deploy play for every compose deployment, what is left

**Under way.** `server-deploy-compose.yml` redeploys the plain compose deployments (plan,
one question per deployment, `up`, ids compared, health waited for), takes per-deployment
checks as hook files in `ansible/deploy-hooks/<name>/`, and reads required `.env` names out
of `compose.yaml`. `send2ereader`'s checks are the first hooks. First bring-up is
`server-bring-up-deployment.yml`. The reasoning is in
[`docs/decisions.md`](../docs/decisions.md), *One redeploy play for the plain compose
deployments*.

## Open

1. **Exercise `send2ereader`'s `probe.yml`.** The whole path has run for real, owner-reported
   2026-10-25: a no-change plan on `one`, and on `zero` a recreate plan, the question, `up`,
   the id comparison and the health wait (syncthing, recreated, up after about a minute).
   What has not run is a hook-driven probe, which only fires after a redeploy of the
   deployment that has one. It runs the next time `send2ereader`'s image changes.
2. **Delete `server-deploy-send2ereader.yml`** once step 1 has passed, and
   point `deployments/send2ereader/README.md` and the root `README.md` at the generic play
   only.
3. **Move `garmin-mcp` onto it**, the delicate one. Its play's parts that are not generic:
   generating `MCP_BEARER_TOKEN` and `MCP_CONSENT_SECRET` into `.env`; checking out upstream
   at `SOURCE`'s sha under `$SRC_ROOT` (the image is built on `one`, never pulled); the
   allowlist check against `compose.yaml`; the probes including the served-tools check; and
   the interactive Garmin login step (the manual MFA instructions). Move them as hooks
   *unchanged*. Its `failed_when: false`, `no_log` and explicit-environment details carry
   lessons that look like noise. Delete `server-deploy-garmin-mcp.yml` after a real run of
   the new path, and drop `garmin-mcp` from `deploy_own_play` in the generic play.
4. **Update the docs that name the old plays** when each is deleted: `README.md`,
   `ansible/README.md`, `deployments/*/README.md`, `docs/management-plane.md`.

When 1 to 4 are done, delete this file.
