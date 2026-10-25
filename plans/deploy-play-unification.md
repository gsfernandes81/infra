# Plan: one deploy play for every compose deployment, what is left

**Under way, and only runs and deletions are left.** `server-deploy-compose.yml` redeploys
every compose deployment (plan, one question per deployment, `up`, ids compared, health
waited for), takes per-deployment checks as hook files in `ansible/deploy-hooks/<name>/`, and
reads required `.env` names out of `compose.yaml`. `send2ereader` and `garmin-mcp` are both on
it, and their old plays are kept only until each has had a real run of the new path. First
bring-up is `server-bring-up-deployment.yml`. The reasoning is in
[`docs/decisions.md`](../docs/decisions.md), *One redeploy play for the plain compose
deployments* and *garmin-mcp joins the redeploy play*.

## Open

1. **Run each moved deployment through the new path, the owner's.** Neither has had a
   hook-driven probe yet, and `garmin-mcp`'s hooks have not run at all. `-e recreate=true`
   makes a redeploy with nothing changed, so neither has to wait for an image bump. Recreating
   is a short outage of each, and `garmin-mcp` pauses at its Garmin login only if the login has
   lapsed.
   ```fish
   cd ~/infra/ansible
   ansible-playbook playbooks/server-deploy-compose.yml -e deployment=garmin-mcp --check -K
   ansible-playbook playbooks/server-deploy-compose.yml -e deployment=garmin-mcp -e recreate=true -K
   ansible-playbook playbooks/server-deploy-compose.yml -e deployment=send2ereader -e recreate=true -K
   ```
   The `--check` should end in a plan that says *nothing to change* for `garmin-mcp`: its
   preflight writes nothing on a deployed host, and a plan that differs means it did.
2. **Delete `server-deploy-send2ereader.yml` and `server-deploy-garmin-mcp.yml`** once their
   run in step 1 has passed, and with them the "superseded" rows in `ansible/README.md`, the
   paragraph in the root `README.md`, and the "kept until" notes in both deployments' READMEs.
   `docs/management-plane.md` names `server-deploy-send2ereader.yml` in Phase 3's row and in
   § *`bin/compose` goes*; both say what was true then, so they gain "since deleted" and keep
   the name.

When 1 and 2 are done, delete this file.
