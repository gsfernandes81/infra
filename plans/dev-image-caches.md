# Dev image caches: each repo caches what it owns

**In progress since 2026-11-01.** Decided by the owner; the reasoning is the row *Each
repo builds a CI layer cache of its own dev image* in
[`docs/decisions.md`](../docs/decisions.md). Delete this plan when every row in the
rollout table reads done and a deploy after a base bump has been measured on zero.

## Why

A deploy builds nine images on zero, one at a time (`make build`). After a base bump every
one rebuilds from scratch, because nothing after `FROM` matches: about 12½ minutes on
2026-11-01, by `docker buildx history ls` on zero. With an unchanged base the same builds
take seconds. A registry cache built in CI on the same base tag turns each step on zero
into a layer pull.

The repo that owns a Dockerfile builds its cache. infra owns the base tag and tells each
repo when it moves.

## What infra does

- `.github/workflows/dev-cache.yml` runs after every `dev-base` run that passes, and on
  dispatch. It caches the hub and infra images itself, as
  `gsrpi-dev-base:buildcache-<service>-arm64`.
- Its `dispatch` job runs each child's `dev-image.yml` with `base_tag` set to
  `x-base-tag`. The children are read from `dev/compose.yaml`'s contexts, so a new child
  is asked once it is in `compose.yaml`.
- Each child's service in `dev/compose.yaml` names `<repo>-dev:buildcache-arm64` in
  `cache_from`. or3's has none yet; it gets one once or3 confirms its ref.

## The contract a child's `dev-image.yml` keeps

A cache hit on zero needs the same base digest, the same args, the same Dockerfile and the
same files in the context. So each child's workflow:

1. **Is `.github/workflows/dev-image.yml`**, with `workflow_dispatch` and an input
   `base_tag` (string). infra dispatches it on `main` with that input.
2. **Builds on infra's base tag, never its own default.** With `base_tag` given, it uses
   that. On its own push it reads infra's current tag:
   `curl -fsSL https://raw.githubusercontent.com/gsfernandes81/infra/main/dev/compose.yaml | sed -n 's/^x-base-tag: &base-tag //p'`.
   A `Dockerfile.dev` `ARG BASE_TAG` default is then only for a build by hand.
3. **Passes exactly the args zero passes**: `BASE_TAG`, and nothing else.
4. **Builds the same context zero fetches**: the repository's Git context at the commit
   (`docker/build-push-action`'s default, not `context: .`), with the Dockerfile and
   subdirectory `dev/compose.yaml` names for it.
5. **Builds `linux/arm64` on `ubuntu-24.04-arm`**, natively. amd64 is the repo's choice;
   zero is arm64.
6. **Writes and reads one cache**,
   `type=registry,ref=ghcr.io/gsfernandes81/<repo>-dev:buildcache-arm64,mode=max,compression=zstd,oci-mediatypes=true`.
   Pushing an image as well is the repo's choice; zero reads only the cache.
7. **Keeps the package anonymously readable**, since zero pulls with no credential. A
   package first pushed from a public repo takes its visibility. A private repo's package
   is private, which zero cannot read.

## Rollout

| Repo | `dev-image.yml` | On infra's base | Cache in `compose.yaml` | State |
|---|---|---|---|---|
| claude-sessions | yes, amd64 + arm64, `base_tag` input | yes, since claude-sessions cf00afc | yes, its own two | **done 2026-11-01**: infra's first dispatch ran claude-sessions run 41313446768 on base `2026.11.01`, arm64 in 19s from its cache |
| or3 | to be confirmed by or3 | to be confirmed | no | mailed 2026-11-01: the owner believes it is cached; or3 checks and says how zero reads a private package |
| destiny-director | no | — | yes (ref not built yet) | mailed 2026-11-01 |
| dossier | no | — | yes (ref not built yet) | mailed 2026-11-01 |
| invective | no | — | yes (ref not built yet) | mailed 2026-11-01 |
| nibbles | no | — | yes (ref not built yet) | mailed 2026-11-01 |
| ionic-traces | no | — | yes (ref not built yet) | mailed 2026-11-01 |

## The owner's steps, once

**Done 2026-11-01.** The App exists and is installed on all seven; infra's dev-cache run
41313394751 minted its token and dispatched claude-sessions. Kept for a re-install.

1. **Create a GitHub App for dispatch only**, under the account (Settings, Developer
   settings, GitHub Apps, New). Webhook off. Repository permissions: **Actions: Read and
   write**, nothing else (Metadata: read is added on its own). Not the hub's App: that one
   holds contents and pull-request write on every repo, and its key would then sit in
   infra's Actions secrets.
2. **Install it on the seven child repos only**: claude-sessions, destiny-director,
   dossier, invective, ionic-traces, nibbles, or3. The token is minted for all seven at
   once, so a repo missing from the installation fails the dispatch for every repo.
3. **Give infra its id and key**, then delete the downloaded key file:

   ```fish
   # dispatch App: its id as a variable, its key as a secret, on infra
   gh variable set DEV_DISPATCH_APP_ID -R gsfernandes81/infra --body <app id>
   gh secret set DEV_DISPATCH_APP_KEY -R gsfernandes81/infra < <downloaded key>.pem
   ```

4. **Prove it**: `gh workflow run dev-cache.yml -R gsfernandes81/infra`, then read the
   run's summary. It lists each repo dispatched and each one not.

## Done when

- every rollout row reads done, and
- after the next base bump, `sudo docker buildx history ls` on zero shows the images at
  seconds each, or3 aside if it stays uncached.
