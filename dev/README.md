# dev — the dev containers on `zero`, and the hub in front of them

This directory is one Compose project, `name: dev`, holding every dev container on `zero`
(Pi 5, arm64) and the **hub** that is the way in to all of them: `ssh dev` lands on one
claude-sessions menu over every container. **`infra-dev`** is this repo's own container —
Claude Code against **this** repo, with Ansible in the image. `or3-dev`, `dd-dev` (with
`dd-postgres`) and `ds-dev` are the other repos', each behind a profile of its own name.

> **⚠︎ Built 2026-10-26, not yet on the fleet.** Until the owner brings it up, zero still
> runs the old layout — each container in a project of its own, its `/workspace` a bind mount
> of zero's clone, with its own tunnel, offload loop and menu. Two things stand between this
> file and the box: **claude-sessions 0.5.0 is not released**, so the two hashes in
> `hub/Dockerfile` are placeholders (`FILL-FROM-THE-v0.5.0-RELEASE`) and the hub's build fails
> at `sha256sum -c`, on purpose, until they are filled from the release; and base
> `2026.10.26` is published by CI only when this reaches `main` (`make base` builds it locally
> meanwhile). Then the move itself, which is the owner's — *The cutover from the old layout*
> below has the order.

## Why this exists

**To run Claude sessions on `zero` instead of driving them from the phone.** Every token of a
response driven from the Android app or Remote Control crosses the phone's mobile data, the
one metered link on the map (the **or3** repo's `CLAUDE.md` § *Data budget*: metering follows
the destination, not the size). In a container on `zero` the model traffic goes out over
zero's home line, and what crosses the radio is a terminal session.

`ansible-core` and the collections are in infra-dev as **development tools** — syntax-check,
lint, read a playbook against the real `ansible.cfg` — and are not wired to the fleet.

## What it is not

- **Not a control node.** No container has a key or a route to `zero`, `one` or `two`;
  decided 2026-10-25, [`../docs/management-plane.md`](../docs/management-plane.md) § *A
  control node inside the fleet*. Playbooks run from the phone. `make fleet` and the `fleet`
  line in `make verify` say so, and it is not a fault.
- **Not a Remote Control host.** No dev container runs one ([`../docs/decisions.md`](../docs/decisions.md),
  2026-08-25). One way in everywhere, `ssh dev`; adding it back is a decision, not a variable.
- **Not a holder of the docker socket.** See *The socket line somebody will add*.
- **Not a tunnel endpoint, except or3-dev.** The phone holds a reverse forward into or3-dev to
  reach the vessel LAN. The one `sshd_config` allows `-R` only, the hub's key is `restrict`
  everywhere, and by default only or3-dev's `authorized_keys` holds a client key.

## Layout

| | |
|---|---|
| `Makefile` | **the management interface** — `make up`, `make login`, `make status`, …; `C=<container>` picks the container (infra-dev unless said, `C=hub` the hub), `S=<service>` limits `make up` to one |
| `compose.yaml` | the project: `hub`, its `cloudflared` sidecar (profile `tunnel`), `infra-dev`, and `or3-dev`, `dd-dev` (+ `dd-postgres`), `ds-dev` each behind a profile of its own name; one network, `dev`; **nothing published on the host**. The base tag is its `x-base-tag` line, each container's repo an anchor at the top |
| `hub/` | the hub's image: `Dockerfile` (claude-sessions pinned by release and per-arch SHA-256), `entrypoint.sh`, `door` (installed as `hub-door`, its sshd's `ForceCommand`), `health` (`hub-health`, its healthcheck), `github-tokens` (the token broker) and its offline test, `sshd_config`, and `ssh_config` — how it reaches each container |
| `cloudflared.yml` | the hub tunnel's ingress, and the whole of it: `dev.gsrpi.uk` → the hub, `or3-dev.gsrpi.uk` → or3-dev |
| `Dockerfile.base` | `gsrpi-dev-base`, which every dev container is `FROM` — Debian trixie slim, Node 22, Claude Code, gh, zmx, screen, sshd, Helix, the tools and language servers, Crush, Jcode |
| `Dockerfile` | infra-dev: the base + ansible-core, the collections and the docker CLI |
| `entrypoint.sh` | every container's PID 1: ssh material and the hub's key → Claude config → clone or pull the workspace → link the env files → `child-init.sh` → `reconcile` → keep-alive skill → **sshd (fg)** |
| `dev-door` | sshd's `ForceCommand` in every container: a forwarded command as given, otherwise a login shell in `/workspace` |
| `in-workspace` | on PATH: run a command in `/workspace`, so no client names the path |
| `gh`, `git-credential-hub` | the `gh` wrapper and git's credential helper, both reading the hub's token |
| `sshd_config` / `ssh_config` | the one in-container daemon config, and the baked half of how a container reaches out |
| `config.fish`, `screenrc`, `claude-managed-settings.json` | fish's config (a login shell lands in `/workspace`), screen's, and Claude Code's managed settings (agent view off, stable channel) |
| `login.sh` | in the image: the interactive login walkthrough, and the clone if start-up could not make it — `make login` |
| `status.sh` | on the host: the readouts — `make status`, `verify`, `fleet`, `collections`, `boot-log` |
| `ci/compose.smoke.yaml` | the smoke test's override; never used on zero |
| `.env.example` | copy to `.env` on zero; **one `.env` for the whole project, and every line in it is required** — Compose refuses a required variable it cannot fill even for a service whose profile is off |

The host side is `ansible/playbooks/server-create-dev-container.yml`, run from the phone; the
project is deployed by `server-deploy-compose.yml -e deployment=dev` (`deployments/dev` and
`hosts/zero/dev` are links to this directory, its hooks in `ansible/deploy-hooks/dev/`).

## Bring-up, from nothing

**One Cloudflare tunnel, the hub's, and no fleet access.** On a box that already runs the old
layout, follow *The cutover from the old layout* instead. From the control node — the phone:

```sh
cd ~/infra/ansible
ansible-playbook playbooks/server-create-dev-container.yml --check --diff     # prove first
ansible-playbook playbooks/server-create-dev-container.yml                    # the hub's tunnel and host side
```

The edge half makes the tunnel `dev`, its record `dev.gsrpi.uk` and an Access application with
no policy yet; `_dev-host.yml` then makes `~/.dev-secrets` (0700: `tunnel.json`, gavin-owned
0600 for the sidecar, and `authorized_keys` with this control node's key) and an empty
`~/.infra-dev-secrets`, and writes the uid, gid, secrets paths and tunnel id into `dev/.env` by
line. **The hub's own key is never made here**: the hub makes it at first start (*The hub*).

Then the GitHub App, which compose requires — *GitHub tokens, one repo each*, steps 1–4 — and
the rest of `.env` by hand. On zero, once, on a box that never had the old projects:

```sh
cd ~/infra/dev && make volumes   # the external volumes, empty — never at a cutover
```

Then from the control node, the deploy play — a dry-run plan, `[y/N]`, a container-id
comparison, and a probe that the hub reaches each container:

```sh
ansible-playbook playbooks/server-deploy-compose.yml -e deployment=dev -K
```

**`make up` on zero is the break glass** — the same build and start with no plan and no
question; `make dev` is `make up` then `make login`. Each starts what `COMPOSE_PROFILES` names,
the hub always and first, and refuses while an external volume is missing: at a cutover that
is a mistyped name to fix in `compose.yaml`, never one to create.

On each client — the machine you ssh *from*:

```sh
ansible-playbook playbooks/client-home-ssh-config.yml -e container=dev
ssh dev
```

On zero, `make login` (`C=<c>` for another container) reports the hub's token, runs `claude
auth login` if needed, and clones the workspace if start-up could not; re-running it is safe.
Then `make verify` should read `sshd: running in the foreground`, `auth: claude logged in`,
`tunnel: the hub's, serving dev`, `hub: key authorised; claude-sessions 0.5.0 here,
claude-sessions 0.5.0 at the hub`, `github: the hub's token for gsfernandes81/infra, until …`,
all collections installed, and `fleet: no route to zero/one/two`.

**The memory pool is opt-in**: `DEV_CGROUP_PARENT=/devpool` puts every dev container and
`dd-postgres` under one cgroup — 2048M soft, 2560M hard, 6G of swap — once
`hosts/zero/system/devpool` is installed and proved ([`../hosts/zero/system/README.md`](../hosts/zero/system/README.md)
§ *devpool*). Each container's `mem_limit` (infra-dev's 2560m) stays a ceiling inside it, and
its `memswap_limit` is that plus the pool's 6G, so the pool decides how much dev work swaps.

## The hub

`dev-hub`, built from `hub/`: a small image with no Claude Code, no node and no repo. It is
the one container an ssh login lands on, and it does five things.

**The menu.** Its sshd's `ForceCommand` is `hub-door`: the claude-sessions menu over every
container at a terminal, a forwarded command as given, and a login shell for anything else —
or when the menu exits non-zero, after one line saying why, so a broken menu costs a
keypress and never locks the door. The hub is `restart: unless-stopped`, the one container
here that is: it runs no claude, so coming back after a reboot with nobody watching is what
a door should do. The dev containers stay `restart: "no"`.

**The install.** At every start the hub runs `claude-sessions install /opt/claude-sessions`
into the shared `claude-sessions` volume: the binary in `bin/`, the hooks drop-in in
`managed-settings.d/`, the keep-alive skill in `skills/keepalive/`, and beside them
`hub.pub`. Every dev container mounts that volume **read-only** at `/opt/claude-sessions`
(on the base's `PATH`) and its `managed-settings.d` subpath over
`/etc/claude-code/managed-settings.d`. So the version every container's hooks, agent and
offload pass run is pinned **once**, in `hub/Dockerfile`, and reaches them at the hub's next
start — no base bump, no child bump. Each file goes in through a temporary name and a
rename, so a hook already running keeps the binary it started from.

**The key.** The hub makes an ed25519 key at its first start in its own `hub-state` volume
(`~/.hub/id_ed25519`), and it is never anywhere else — not on zero, not on a control node,
not in any other container; that is why the hub runs no agent of any kind. Only the public
half leaves, as `hub.pub`, and each dev container's entrypoint writes it to
`~/.ssh/authorized_keys.hub` at start as `restrict,pty <key>`: commands and a terminal, no
forwarding, no agent. The hub's `ssh_config` is one `Host *`: port 2222, user `dev`, that key,
`accept-new` into `~/.hub/known_hosts` — learned on first contact over a network nothing
else joins, then pinned, so a changed key still refuses — `BatchMode`, and a `ControlMaster`
at `~/.ssh/cm/%C`, which is what makes the menu's second connection for an attach cost a
round trip rather than a handshake.

**The offloader.** `claude-sessions offload-all` every three minutes at a fixed rate, which
runs `claude-sessions offload` in every container at once over ssh, each line prefixed with
its container. The measurement happens *inside* each container — it reads `/proc` and the
socket-diagnostics netlink, which answer only in the container's own namespaces — so only the
timer is the hub's. Each pass goes timestamped to `~/.hub/passes.log` in the hub (capped near
16 MB, trimmed to the newest 8 MB). `HUB_OFFLOAD=0` in `.env` stops it, and is the only
switch. The rules are *claude-sessions*, below.

**The GitHub tokens**, one per container — *GitHub tokens, one repo each*, below.

**Its health** is `hub-health`, the compose healthcheck and `make verify`'s `hub health`
line: the binary, `hub.pub`, the hooks drop-in and every container's token directory in place,
an offload pass in the last 10 minutes (when `HUB_OFFLOAD` is on) and a token pass in the
last 40. Every dev container `depends_on` it being healthy, because a subpath that does not
exist cannot be mounted at all; so a dead loop also stops new containers starting until it is
looked at. Unhealthy restarts nothing.

**Which containers** is every container `compose.yaml` names a repo for — its
`HUB_REPO_<NAME>` line in the hub's environment, the same list the token broker mints for —
sorted by name, and stated nowhere else. Every `claude-sessions` in the hub derives it the
same way — `ssh dev`, the offload timer, and `docker exec dev-hub claude-sessions …` alike
(`hub/claude-sessions`, a wrapper ahead of the binary). With one name, there is no home screen:
the menu is that container's.

### The menu, two levels deep

The owner's shape (2026-10-26), drawn in claude-sessions'
[`docs/mockups.md`](https://github.com/gsfernandes81/claude-sessions/blob/main/docs/mockups.md),
mockups 12 to 15, and binding as the rest of that file is:

- **The home is the containers**, one row each, in the hub's list order, with what is in it in
  words — `3 loaded · 1 offloaded`, `nothing open`, `not answering`. A container with a
  session waiting for you is marked with an amber `!`; one with something unread is bold.
  Marked, never moved. `Enter` opens one; `n` and `s` act in the container under the cursor.
- **Inside a container: Loaded, Offloaded, and Archived**, which holds everything closed,
  starts folded, and opens with `Enter` or a click on its heading — the heading says `Enter
  shows` or `Enter hides`. A session waiting for you is an amber `!` on its row rather than a
  group of its own. Every key is the single-container menu's, plus `Esc` back to the home.
- **A container that does not answer** says so, and is asked again every 15 seconds without
  redrawing — an idle hub still sends nothing down the metered link. `s` on it tries a shell
  there anyway, which may answer where the agent did not.

## GitHub tokens, one repo each

**The hub holds the one GitHub credential, and hands each container a token for its own repo
and nothing else** (owner, 2026-10-27). It is the ONLY way a container reaches GitHub: no
deploy key, no `gh` login, no https-to-ssh rewrite, so the App is made before the cutover
(step 0 there). or3's deploy key stays for one job only: lending BuildKit or3's private repo
when its image is built on zero.

How it works:

- **A GitHub App, made once by you, is the credential.** Its private key is
  `github-app.pem` in `$HUB_SECRETS` (`~/.dev-secrets`), mounted read-only into the hub and
  into nothing else — the same rule as the hub's ssh key.
- **`hub/github-tokens` mints an installation token per container**, asking GitHub for exactly
  one repository — the container's, from the anchors at the top of `compose.yaml`, the same
  ones its `DEV_REPO` clones — and for `HUB_GITHUB_PERMISSIONS`. It checks the answer names
  that one repo and writes nothing otherwise. A token lasts an hour; the hub renews every 30
  minutes, and a failed pass keeps the old token and retries in 2.
- **Each container mounts only its own directory** of the `github-tokens` volume, read-only,
  at `/run/github` (a subpath mount, like the hooks drop-in). A claude in `or3-dev` can read
  or3's token and no other container's, and the token itself can reach or3 alone.
- **In the container nothing needs logging in.** `/usr/local/bin/gh` is a wrapper that hands
  the real gh the token, read fresh on each call; git uses `git-credential-hub` for
  `https://github.com`, so a clone, pull or push over https uses it too; the entrypoint clones
  over https with it on a first start. An explicit `GH_TOKEN` still wins.

What changes for you:

- **PRs, issues and comments made from a container appear as the App** (`<app-name>[bot]`),
  not as you; commits are still authored by `GIT_USER_NAME`. That is the price of a token
  scoped to one repo: GitHub mints those only for an App's installation.
- **A container reaches its own repo only.** `gh` in infra-dev cannot open a PR on
  claude-sessions any more; that is the point, and a container that needs a second repo is a
  second line in `compose.yaml`, not a wider token.
- `gh auth status` reports failure on an installation token (it asks for a user the token does
  not have) while every repo command works; `make login` and the entrypoint check the token
  file instead, and `make status` prints `github: the hub's token for <repo>, until <time>`.

**Making the App, once, before the cutover** — the browser half is yours, everything else is in the repo:

1. On GitHub, *Settings → Developer settings → GitHub Apps → New GitHub App*: any name and
   homepage; *Webhook* unticked; *Repository permissions* Contents, Pull requests, Issues and
   Workflows **read and write**, Actions, Checks and Commit statuses **read**; *Only on this
   account*. Create it and note its **App ID**.
2. On the App's page, *Generate a private key* — a `.pem` downloads — then *Install App* on your
   account, *Only select repositories*: infra, or3, destiny-director, dossier.
3. The key to zero, never into a repo: from the phone, `scp <the.pem> zero:.dev-secrets/github-app.pem`,
   then on zero `chmod 600 ~/.dev-secrets/github-app.pem` and delete the phone's copy.
4. `HUB_GITHUB_APP_ID=<id>` in `dev/.env` — compose requires it, and `make check` refuses a
   missing `github-app.pem`.
5. Proof, from `make shell C=infra-dev`: `git -C /workspace push --dry-run origin HEAD`
   succeeds — a push needs the token's write even on public infra, so this is the token at
   work — and `git ls-remote https://github.com/gsfernandes81/or3` is refused, because or3 is
   private and the token is infra's alone. (Reading a public repo proves nothing: anyone can.)
   `~/.hub/github-tokens.log` in the hub has each pass, never a token.

Asking for a permission the App was not granted fails every token with GitHub's reason in the
log (HTTP 422); narrow `HUB_GITHUB_PERMISSIONS` in `.env` or widen the App. The checks are
`python3 hub/test_github_tokens.py`, offline, against a stand-in GitHub that verifies each
JWT's signature.

## The workspace and the env volume

**`/workspace` is each container's own named volume, cloned into** (`infra-workspace`,
`or3-workspace`, …) — never a host clone. zero's `~gavin/infra` is only what the box runs, so
a commit in a container can never leave zero's checkout diverged (`../CLAUDE.md` § *Git*).
**Push to share work**, as from anywhere else.

At start the entrypoint fills an empty `/workspace` from `DEV_REPO` (set per service from the
repo anchors in `compose.yaml`) with `git clone` over https and the hub's token, bounded and
never fatal. A volume that holds files but no checkout is left alone with a warning — it is
somebody's work. After that, every start pulls `--ff-only`, best-effort: a container that will
not come up because the network is down, or the tree has local work, is worse than one on a
slightly old checkout. If the clone failed (no token yet, no network), `make login C=<c>`
clones once the token is there.

**A repo's untracked secrets live in a second volume, `~/.env.d`, linked into the
workspace.** `DEV_ENV_FILES` (per service, space-separated workspace paths; `.env` for or3 and
dd, none for infra, whose `.env` files live on the hosts) names them. Each becomes
`/workspace/<f>` → `~/.env.d/<f>`, so the workspace volume — which can be thrown away and
re-cloned — never holds a secret, and editing `/workspace/.env` writes through to the env
volume. **Symlinks, not hard links:** two volumes are two mounts, and `link(2)` refuses
across mounts. Rules the entrypoint keeps:

- **Never clobbered.** A *regular* file where the link should be — an editor that saves by
  rename, `sed -i` — is the newest copy, so it is reported and left: `mv /workspace/.env
  ~/.env.d/.env`, then `make restart`, puts it back.
- **Never committed.** Each link goes into the checkout's `.git/info/exclude`, whatever the
  repo's `.gitignore` says.
- **Only plain paths.** An entry that is absolute or contains `..` is refused with a
  warning.

**`make down-volumes` drops both kinds** — every cloned workspace, with any unpushed work in
it, and every env volume — along with the hub's key (*The targets*). It never touches a host
clone: nothing reads one, and each child image builds from its repo on GitHub.

## The cutover from the old layout

**One cutover moves all four containers at once** (owner, 2026-10-27), and **every one comes
out working in its own clone, in a volume** — no workspace is a bind mount of a host clone
any more. Until it runs, zero runs the old layout: `infra-dev` and `or3-dev` each in their
own compose project with zero's clone as `/workspace`, `dd-dev` and `ds-dev` defined in their
repos and stopped.

Every running claude in `infra-dev` and `or3-dev` ends at step 5; the conversations do not —
each `~/.claude` volume is reused by name — and each is resumable from Archived afterwards.
The phone's vessel tunnel is down from step 5 to step 7, a few minutes, and `or3-tunnel`
reconnects by itself.

**What carries over, and what has to be carried:**

- **Logins, history and sshd host keys** — every old volume is named **external** in
  `compose.yaml` (`infra-dev_*`, `or3-dev_*`, `destiny-director_*`, `dossier_*`, as
  [`../docs/fleet-inventory.md`](../docs/fleet-inventory.md) listed them on 2026-10-25). dd's
  database volume too.
- **Pushed work** — each workspace is a fresh clone of its repo. **Anything not pushed is not
  in it**: uncommitted changes, local branches, stashes, worktrees, and ignored files such as
  or3's `var/`, `waterproof/live/` and `.rehearsal/`. Step 1 lists each; the host clones stay
  on zero untouched, so nothing is deleted, but nothing there is visible to a container.
- **Untracked secrets** — dd's `.env` (DATABASE_URL, the Railway token) goes into dd-dev's env
  volume, linked into its workspace, in step 6. dd's and ds's `.dev-ssh/` keys move out of
  their clones into `~/.dd-dev-secrets` and `~/.ds-dev-secrets` in step 2. or3's keys are
  already in `~/.or3-dev-secrets`.
- **Nothing reads the host clones any more.** Each child builds straight from its repo on
  GitHub (`main`), with its own Dockerfile, on base `2026.10.26` passed as the `BASE_TAG`
  build arg each already takes — so no child repo changes first. or3, being private, is
  fetched over ssh with its deploy key from `~/.or3-dev-secrets`. Once step 1's listing is
  clean, the clones of or3, destiny-director and dossier on zero can be deleted.
- `dd-dev` and `ds-dev` no longer mount zero's `~gavin/.ssh`: the hub's key is their way in.
- `or3-dev.gsrpi.uk` stays, re-pointed at the hub's tunnel in step 7, so the phone's
  `or3-tunnel` reverse forward lands inside `or3-dev` as before (`cloudflared.yml`).

**The steps.** Blocks are for fish, pasted inside the shell named.

0. **Release and pin; make the App.** Merge claude-sessions to `main`; wait for `v0.5.0`; put
   its two checksums (`SHA256SUMS`) into `hub/Dockerfile`; merge infra to `main`. Base
   `2026.10.26` publishes from that push (about five minutes), or `make base` builds it
   locally. Make the GitHub App (*GitHub tokens, one repo each*, steps 1–3): it is every
   container's only way to GitHub from here on.
1. **On zero (`ssh zero`): what would not carry over, for all four clones.** Read-only.

   ```fish
   for r in ~/infra ~/or3 ~/destiny-director ~/dossier
       echo "== $r"
       git -C $r fetch -q
       git -C $r status --short
       git -C $r log --branches --not --remotes --oneline
       git -C $r stash list
       git -C $r worktree list | tail -n +2
       git -C $r status --short --ignored | grep '^!!'
   end
   ```

   Empty under a heading means that clone has nothing to lose. Push what should survive, and
   note any ignored directory worth copying in by hand after step 5 (`docker cp` into the
   container's `/workspace`). `.env`, `.dev-ssh/` and `.venv/` in that list are expected:
   the first two are carried below, the last is rebuilt.
2. **On zero: pull, set the old `.env` aside, move the keys out of the clones.**

   ```fish
   cd ~/infra; and git pull --ff-only
   install -m 600 dev/.env ~/dev.env.old; and rm dev/.env
   for r in dd:destiny-director ds:dossier
       set n (string split : $r)
       install -d -m 700 ~/.$n[1]-dev-secrets
       cp -a ~/$n[2]/.dev-ssh/. ~/.$n[1]-dev-secrets/
   end
   sudo docker volume ls --format '{{.Name}}' | grep -E '^(infra-dev|or3-dev|destiny-director|dossier)_'
   ```

   The old `.env` is backed up outside the directory at 600, never beside itself. A volume name
   that differs from `compose.yaml`'s is fixed there before `make up`.
3. **From the control node: the dev project's tunnel and host side.** It starts the new
   `dev/.env` from `.env.example` and writes its own lines (uid, secrets dirs, tunnel id).
   Then put `HUB_GITHUB_APP_ID` in that `.env` by hand.

   ```fish
   cd ~/infra/ansible
   ansible-playbook playbooks/server-create-dev-container.yml
   ```

4. **On zero: check the paths the new `.env` names** — `ls -d ~/.or3-dev-secrets
   ~/.dd-dev-secrets ~/.ds-dev-secrets ~/.or3-dev-secrets/id_ed25519_or3_deploy` — and fix
   any line that is wrong. The last is what builds or3's image.
5. **From the control node: the deploy play, twice, with the old projects stopped between.**

   ```fish
   cd ~/infra/ansible
   ansible-playbook playbooks/server-deploy-compose.yml -e deployment=dev -K
   ```

   The first run checks `.env`, the secrets and the external volumes, then **builds every
   image** — the hub, infra-dev and or3-dev, or3 fetched over ssh with its deploy key — while
   the old containers still run, so a failed build costs nothing. Then it **stops**, naming the
   old projects that still hold the dev names. On zero, from `~` and not from inside any dev
   container:

   ```fish
   cd ~
   for p in infra-dev or3-dev destiny-director dossier
       sudo docker compose -p $p down
   end
   ```

   No `-v`: the volumes are what moves. From `~`, because in `dev/` `docker compose` would read
   the new `compose.yaml`. A project with nothing left in it is a no-op. Then the same play
   again: the build is cached, the plan lists every container it would create, it asks
   `[y/N]`, and on `y` it starts the hub, its tunnel, infra-dev and or3-dev
   (`COMPOSE_PROFILES`), waits for them, compares container ids, and probes that the hub
   reaches each one. dd-dev and ds-dev stay stopped, as they were. `make login C=<c>` on zero
   afterwards walks any login a container still lacks.
6. **dd's `.env`, into its env volume** — the first time dd-dev is wanted:

   ```fish
   make up S=dd-dev
   sudo docker cp ~/destiny-director/.env dd-dev:/home/dev/.env.d/.env
   make restart C=dd-dev
   ```

   The restart links it into `/workspace/.env`. `docker cp` keeps the file's owner, which is
   the checkout's — the container's `dev` uid.
7. **From the control node: the vessel tunnel's hostname onto the hub's tunnel.**

   ```fish
   ansible-playbook playbooks/server-create-dev-container.yml -e container=or3-dev -e via_hub=true
   ```

   It re-points `or3-dev.gsrpi.uk` and keeps its Access application and every client's
   token. It refuses, rather than mint a tunnel, if the hub's does not exist.
8. **On each client:** `git pull` in the client's checkout, then the whole
   `client-home-ssh-config.yml` — it writes `dev`'s block and token, keeps `or3-dev`'s, and
   removes the blocks and token files of `infra-dev`, `dd-dev` and `ds-dev`, whose tunnels
   are retired. Then `ssh dev`.

**Proof, each against the thing it claims:**

- `ssh dev` opens on four containers; `infra-dev` and `or3-dev` say what is open in them,
  `dd-dev` and `ds-dev` "not answering" while stopped.
- A new claude in `infra-dev` shows busy, then idle, in the menu — the hooks are read from
  the hub's volume (the one thing no box has shown yet).
- `make shell C=or3-dev`, then `git -C /workspace remote -v` and `git -C /workspace status`:
  a clean clone of or3, not zero's.
- From the phone, `ssh or3-dev ssh or3ecr hostname` answers `OR3-ECR1-GR`.
- After step 6, `make shell C=dd-dev`, then `pg_isready -h postgres` and `readlink
  /workspace/.env`: the database by its old name, and the env file by its link.
- `make verify` on zero, and `make status` for the hub, its tunnel and the offload passes.

**Rolling back** is the old layout, one commit back, with every old volume intact and every
host clone as it was (so delete no clone until the new layout has been proved): `make down` here, check out the commit before the hub in `~/infra`,
`install -m 600 ~/dev.env.old dev/.env`, and `make up` there; or3 and infra-dev come back as
they were. `or3-dev.gsrpi.uk` then needs re-pointing at or3-dev's old tunnel:
`server-create-dev-container.yml -e container=or3-dev`, without `via_hub`. Work committed in
a new container's volume clone in the meantime is in that volume, not the host clone: push it
first.

**Afterwards, each its own change:** retire infra-dev's and or3-dev's old tunnels (the
CNAMEs no longer use them), and the Access applications and service tokens of infra-dev,
dd-dev and ds-dev, where they exist — or3-dev's stays, its hostname now on the hub's; in each
child repo, drop its compose file and its authorized-keys drop-in, bump its `BASE_TAG`
default, and fix its docs (or3's `docs/dev-tunnel.md` names `~/or3/dev` for `make tunnel-log`,
`up` and `shell`, now `~/infra/dev` with `C=or3-dev`; dd's and ds's say their keys are in
`.dev-ssh/`). The
host clones of or3, destiny-director and dossier, `.dev-ssh/` included, can go once the
containers are proved.

### A container added later

In `compose.yaml`: a repo anchor at the top, a service built like the three above (its
`DEV_REPO` that anchor, its own `subpath:` of the tokens volume, its old volumes named
external if it has any), and a `HUB_REPO_<NAME>` line in the hub's environment. Its profile in
`COMPOSE_PROFILES` if it should start at rest; then `make up`. The hub's environment changed,
so it is recreated first — its start makes the new token directory, and the container waits
on it — and every open `ssh dev` view drops for a few seconds; no claude does (owner and
advisor, 2026-10-27: a list file in place of the recreate would trade that ordering away for a
second place each repo is named). A container removed from `compose.yaml` loses its token
directory at the hub's next start.

## The smoke test

`.github/workflows/dev-smoke.yml` runs on every push that touches `dev/`: it builds the base,
the hub and infra-dev on GitHub's runner, brings them up with `make` and stand-in keys, and
checks, each by name — the hub reaching infra-dev with its own key, a client key reaching the
hub's door, the hooks drop-in, the binary and the GitHub token arriving through their mounts,
the workspace cloned over https with that token, the tools on `PATH`, and ds-dev building
straight from its GitHub URL. Its header lists what it cannot check (the Pi, the pool,
Cloudflare, the App, or3-dev). Until claude-sessions 0.5.0 is released it builds the hub's
binary from that repo's branch, through `ci/compose.smoke.yaml` and the Makefile's
`COMPOSE_OVERRIDE`; neither is ever used on zero.

## What every container carries for work

The base, so every child has it by its `FROM` line (owner, 2026-10-27):

- **Helix** (`hx`, 25.07.1, with its compiled grammars), and `EDITOR`/`VISUAL` set to it.
- **Language servers**, the ones Helix uses by default and Claude Code's code-intelligence
  plugins look for: `ty` and `ruff` (Python, Helix's defaults), `pyright-langserver`,
  `typescript-language-server` with TypeScript 5.9, `bash-language-server`,
  `yaml-language-server` and the compose one, `vscode-{json,html,css}-language-server`,
  `docker-langserver`, `fish-lsp`, `taplo` (TOML). No Markdown server: Claude reads Markdown
  as text, and one would only serve an editor (owner, 2026-10-27). A project's venv
  comes first on `PATH` where its Dockerfile puts it there, so the repo's own pinned ruff and
  ty win inside it. Claude Code's LSP plugins are not enabled here; the binaries they need are.
- **Command-line tools**: ripgrep, fd, jq, yq (mikefarah's), tree, file, zip/unzip, xz,
  rsync, sqlite3, shellcheck, shfmt, bat, fzf, delta, htop, lsof, strace, dig, nc, wget,
  patch, bc, uv.

Not here, and why: `ansible-language-server` wants Node 24 and the base runs Node 22;
rust-analyzer, because no container works on a Rust repo; compilers, which each child adds
for its own builds (dd and ds add `build-essential`). Every binary that runs as what it
downloads is hash-pinned per arch in `Dockerfile.base`; the npm and PyPI ones are
version-pinned, as Claude Code is.

## Crush and Jcode, on trial

Two more agent harnesses in the base, the owner's calls (their rows in
[`../docs/decisions.md`](../docs/decisions.md), their layers in `Dockerfile.base`). `ssh dev`,
`s` on a container, then `crush` or `jcode`; the first start asks for a provider.

- **No slot**: neither runs in a zmx session, so a dropped connection ends it, and the menu and
  offloader know nothing about either. `crush --continue` picks up the last session.
- **State**: Crush's key and settings in `~/.local/share/crush` (a volume; `~/.config/crush` is
  not), jcode's everything, login included, under `~/.jcode`; per-project `.crush/` and
  `.jcode/`, which the repo ignores. **Decline any offer to initialise a project** — it writes
  an `AGENTS.md`, a second `CLAUDE.md`.
- **Versions**: Crush is the latest release when the base was built (`crush-latest`; `make base
  CRUSH_VERSION=none` without it when GitHub or `repo.charm.sh` is down). Jcode is hash-pinned
  and bumped by hand, then updates itself into `~/.jcode/builds`, which is why it is installed
  as `dev` with a launcher in `~/.local/bin`. `make verify` names both.
- **Telemetry** is left at each default: Crush's metrics are on (`CRUSH_DISABLE_METRICS=1` —
  the owner's call, not yet made); jcode's installer, which phones home, is not used.

## How a container is used

**You `ssh dev` and pick a session from the menu** — from Termux on the phone, or from a
PC. `Enter` on a container (or straight in, while there is only one), then `Enter` attaches
or resumes, `n` starts a session in `/workspace`, `s` gives a login shell there.

**Every session the menu opens is a zmx session**, and that is the habit to keep: on a phone
the ssh session ends at the lock screen, and a claude started outside one ends with it.
**Ctrl-\\** detaches; what is under it keeps running. Each attach replays recent history (up
to ~10,000 lines, ≈120 KB compressed at 80 columns), and detaching sends `ESC c`, which clears
Termux's scrollback until the next attach. `screen` is there for ordinary shell work.

**sshd forces every session through `dev-door`**: a forwarded command runs as given, in `~` —
which is all the hub's `claude-sessions agent` calls need — and anything else gets a login
shell in `/workspace`. **sshd is the foreground process**, so nothing you type ends the
container: `exit` closes an ssh session, `/exit` a claude, and PID 1 has not moved.

**Through the hub, a command is two hops:** `ssh dev ssh infra-dev 'in-workspace git log'`
runs `ssh infra-dev …` in the hub with its key, then the rest in the container — two rounds
of quoting, so keep it simple. **scp, sftp, Zed and `ssh -L`/`-R` to a container have no
route**: the hub's sshd forwards nothing, and its key is `restrict`. That is an open gap; until
it closes, a file goes over as a stream (`ssh dev ssh infra-dev 'cat /workspace/f' > f`).

**`in-workspace`** cds to `/workspace` and execs what it was handed: a forwarded command is
`$SHELL -c '…'`, not a login shell, so it lands in `~` — and a claude started there asks to
trust a directory that is not the repo. Its header has the rest.

**The break-glass way in is `docker exec` through zero's own ssh**, typed rather than aliased:

```sh
ssh -t zero 'cd ~/infra/dev && make shell'        # a shell in infra-dev; C=<c> for another, C=hub the hub
ssh -t zero 'cd ~/infra/dev && make claude'       # the hub's menu, as ssh dev lands on it
```

It survives a broken tunnel, Access application or token, and a hub whose sshd is down —
`make shell` reaches a container without the hub at all. Why it has no alias and no published
port is in [`../docs/ssh-clients.md`](../docs/ssh-clients.md). `make claude` is the same menu
and the same sessions as `ssh dev`, not a second set.

## Claude Code in here

**It updates itself, so the version in the image is a floor**; a new version takes effect at
the next `claude`. That works because the npm prefix, `/opt/npm-global`, is owned by `dev` —
and not under `/home/dev`, where a volume would hide it. Node stays for it: the updater shells
out to `npm`, and without npm fails saying *"Check your internet connection"*. The reasons are
the rows on not pinning it and on the stable channel in [`../docs/decisions.md`](../docs/decisions.md).

| | |
|---|---|
| what a container runs now | `make verify` — the `claude` line |
| whether it can still update itself | `make verify` — the `autoupdate` line, from `claude doctor` |
| what it started with, and when | `make boot-log` — the entrypoint prints the version at every start |
| update now, without waiting | `make claude-update` |
| stop updating | `DISABLE_AUTOUPDATER: "1"` in the service's `environment:` in `compose.yaml`, then a redeploy |
| which channel | **`stable`**, from `claude-managed-settings.json` — about a week behind `latest`. Forward only: a new container starts on the build day's `latest` and stays until stable passes it. Changing it is that file and a base bump; managed settings outrank `~/.claude/settings.json` |

**The `autoupdate` line does not read `claude doctor`'s `Auto-updates:` field**, which says
`enabled` whether or not an update can land (measured on 2.1.278, both ways round). It looks
for the warning `Can't auto-update: npm global folder isn't writable`, with `Last update
attempt: success → …` as corroboration. `BLOCKED — …` is that warning.

**The agent view is off, and cannot be turned back on in here.** One **←** at an empty prompt
starts a `claude daemon` with warm spares: measured on 2.1.286, an idle session went from
~250 MB to ~1,260 MB, and ~690 MB stayed running after it exited. So the base sets
`"disableAgentView": true` in managed settings and `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, which
the binary checks first and so holds if the file is malformed or moved; `=0` **also** disables
it. `claude --bg` and `claude agents` are unavailable, by intent. **The offloader's orphan
sweep depends on it** — with the view on it would kill agent view's supervisor — so turning it
back on means stopping the offloader first. `make verify`'s `agentview` line reports both
switches. The figures are a floor: taken with a dummy API key rather than a login, and the
binary skips warm spares under ~1 GB free; the re-measure is open in
[`../plans/claude-sessions.md`](../plans/claude-sessions.md).

**The login is `make login`, once**, kept in the `*-claude` volume. Never copy the phone's
`credentials.json` in: tried in or3-dev, claude blanked the copy within a second and refreshed
the phone's login under it. An OAuth login belongs to the device that made it.

## Ansible from in here

**`ANSIBLE_CONFIG` is set in the image** to `/workspace/ansible/ansible.cfg`, so a run from
any directory reads the checkout's config instead of failing with `No inventory was parsed`
(which reads as a broken inventory, not a wrong directory). It works because a relative path
inside `ansible.cfg` resolves against **the config file's own directory**, not the cwd —
verified on ansible-core 2.21.3.

**The corollary, and it will bite anyone editing Ansible in a worktree.** Because the
variable is absolute and wins over the cwd, `cd`-ing into
`.claude/worktrees/<name>/ansible` and running a playbook still reads
`/workspace/ansible`'s `inventory`, `group_vars` and `host_vars` — the *main* checkout's.
The symptom is not an error: a variable added to the worktree's `group_vars/all.yml`
reads undefined while the variables already in that file resolve normally, because the
file being read is the other copy of it. Prefix the run with
`ANSIBLE_CONFIG=<worktree>/ansible/ansible.cfg`. `ansible` and `ansible-inventory` do
*not* share the confusion and so deepen it: their playbook directory is the cwd, so they
pick up the worktree's `group_vars` and cheerfully print the value the playbook cannot
see.

**The collections are baked, not installed at start** — a start that reaches Galaxy fails
when the network is down. So `Dockerfile` and [`../ansible/requirements.yml`](../ansible/requirements.yml)
both name them, and `make collections` compares the two by **name**, not version
(`requirements.yml` states floors). **`ansible-core` is pinned exactly**, because a playbook
that checks here and fails on the phone is the failure mode; move the two together.

**The docker CLI is here for `docker compose config`, and only that** — the diff
`../CLAUDE.md` asks for before a compose change. There is no engine and no socket, and
`DOCKER_HOST` points at a path that does not exist, so `up` fails at once while `config`
renders. Render against a copy with a made-up `.env`, never the real one: the output
interpolates it.

### The socket line somebody will add

`- /var/run/docker.sock:/var/run/docker.sock` is missing from `compose.yaml` deliberately,
and it is the most likely edit somebody makes in a hurry in a repo that drives docker
deployments. The socket is root on zero (`../docs/decisions.md`: the docker group is
root-equivalent), handed to a container that runs a claude, on the box that runs Immich.
**Nothing needs it**: Ansible drives docker on `zero` over ssh, as a host in the inventory.
If something one day genuinely needs a socket, the answer is a rootless podman socket under
a dedicated account, not this line.

## Cloudflare

**One tunnel for every dev container, the hub's**, its connector the `dev-cloudflared`
sidecar in the `tunnel` profile, pinned by digest as the deployment sidecars are, and run as
the checkout's owner so the gavin-owned 0600 `tunnel.json` serves it. Two hostnames:
`dev.gsrpi.uk`, the hub's sshd, and `or3-dev.gsrpi.uk`, or3-dev's own sshd, kept for the
phone's reverse forward to the vessel (`cloudflared.yml`). The base carries no cloudflared.

**Provisioning is two plays from the control node**, never ansible on zero. The server side,
`server-create-dev-container.yml` (*Bring-up*), reads the Cloudflare API token from
`~/.config/cloudflare/api-token` and prints how to mint one if it is missing
([`../ansible/README.md`](../ansible/README.md) § *The Cloudflare API token*). It writes
`HUB_TUNNEL_ID` beside the credentials in the same run — the sidecar's image has no shell to
read it from the file — and under `--check`, for a tunnel not yet made, writes no placeholder.

**The client play mints each client's own Access service token**, `dev-<client>`, adds it to
the policy and writes `~/.config/dev/token` at 0600; nothing is shown or pasted, and a lost
laptop is one token to delete. `-e replace_token=true` rotates it (never delete-and-recreate:
Cloudflare refuses while the policy names it). **The laptop is two clients**, Windows and WSL;
run it in WSL for both ([`../ansible/README.md`](../ansible/README.md) § *The laptop is two
clients*). A client needs the `cloudflared` binary, since an `ssh://` ingress speaks only to
`cloudflared access`; on Termux the static linux-arm64 build runs, its 35.7 MiB priced in
or3's `docs/data-ledger.md`.

**Two different things are called a token.** The **API token** (My Profile → API Tokens, one
per machine that runs playbooks) lets a play call the API, and is the one thing that cannot be
minted from the command line. The **Access service token** (Zero Trust → Access → Service
credentials, one per client) gets a client through a `decision: non_identity` policy with no
identity provider. Why, and where each secret must never go — the API token in no secrets
directory, the tunnel credentials never in argv or env, the service token never in a
container — is [`../docs/management-plane.md`](../docs/management-plane.md).

**It is additive.** With `tunnel` out of `COMPOSE_PROFILES` the hub and every container come
up anyway. That is why the sidecar's tunnel id is `${HUB_TUNNEL_ID:-}` and not `:?` — a
required variable stops Compose even with the profile off. With the profile on and no id or
credentials, the connector refuses at start and says so in `make tunnel-log`; nothing else is
affected.

**Health.** `make status`'s `tunnel` line has three answers — no sidecar (the profile is off),
running but not healthy, and serving — read from Docker's verdict on the sidecar's
healthcheck, `cloudflared tunnel ready` against `127.0.0.1:20241` (`readyConnections` ≥ 1).
That is the probe [`../docs/recovery.md`](../docs/recovery.md) calibrated: counting sockets on
7844 and reading the log both read dead against a tunnel that was serving.

## Four copies of this, now one base

Every dev container is `FROM gsrpi-dev-base`, built from `Dockerfile.base` — the ~700 lines the
four containers used to carry each — and differs only in its own Dockerfile and its service in
`compose.yaml`. `.github/workflows/dev-base.yml` builds it to
`ghcr.io/gsfernandes81/gsrpi-dev-base:<tag>` (public) on any push to `main` that touches
`dev/`.

**The tag is `compose.yaml`'s `x-base-tag` line**, stated once: every service passes it as
`BASE_TAG`, the Makefile and the workflow read the same line, and each child Dockerfile's
`ARG` default is only a fallback for a build outside compose. So **a bump moves every
container at its next build**. Bumping is: edit that line, push to `main`, and the workflow
publishes the tag on its own — about five minutes (the first three runs took 4m16s, 4m42s and
4m07s end to end, arm64 under QEMU included) — then deploy. `make base` builds the identical
image locally under the ghcr name (Crush aside: it takes that day's release), and docker
prefers a local image over a pull: the fallback for no network, or not waiting.

**A published tag is never overwritten** (the workflow refuses without `force`), and **a push
that changes a file the image is built from without bumping the tag fails the run** — the
files are derived from `Dockerfile.base`'s `COPY` lines. Comments in `Dockerfile.base` do not
count, since one cannot reach the image; shell scripts compare byte for byte.

**A bump pulls only the layers that changed**: the workflow keeps a registry build cache (the
`buildcache` tag) and pushes zstd layers, and `Dockerfile.base` pins its python base by
digest so the cache cannot move under it; a bump near the bottom of the file ships a few MiB,
plus ~25 MB when Crush has released. A pull of the whole image on a bump that did not move
that digest means the cache missed (shared layers print `Already exists`). **Moving the python
digest is the refresh** — Debian's security updates arrive only then, for one full pull per
host. zstd needs Docker 23 or newer. The base is Debian trixie, for glibc 2.41 (`make verify`'s
`libc` line; the decisions row on trixie).

**What goes in the base and what stays in a child:** a thing goes in the base when the
containers agree about it, and stays in a child when it is that repo's business — or3's `uv`,
pinned to what or3ecr runs, is or3's; `ANSIBLE_CONFIG` names a path in infra's tree, so it is
infra-dev's. A change to `Dockerfile.base` is a change to four containers. A child varies the
base through these seams and no others:

- **`DEV_*` in its service's environment** — `DEV_NAME`, `DEV_SECRETS_DIR`, `DEV_REPO`,
  `DEV_ENV_FILES`, `DEV_CHILD_INIT_TIMEOUT` (the entrypoint's header lists them). Every
  `id_*` private key in its secrets directory is copied into `~/.ssh`.
- **Baked files**: `/home/dev/ssh_config` (its `~/.ssh/config`) and
  `/home/dev/known_hosts.extra` (host keys pinned in its own repo — or3ecr's).
- **`/home/dev/child-init.sh`**, run at start after the pull — so a lockfile that just moved is
  the one installed from — and before sshd, so no session meets a half-installed venv; dd and
  ds `uv sync` there. Non-fatal and bounded (`timeout -k 10 600`, `DEV_CHILD_INIT_TIMEOUT`),
  because anything ahead of sshd that hangs costs the door.

**sshd has no seam**: `sshd_config` is the one file for every container, and a drop-in a child
copies in is ignored.

## claude-sessions

[`gsfernandes81/claude-sessions`](https://github.com/gsfernandes81/claude-sessions) is the
session registry: one JSON file per slot under `~/.local/share/claude-sessions/` (on a volume),
kept current by Claude Code's own hooks. The hub pins **v0.5.0** (not yet released) and
installs it for every container (*The hub*); its design and screens are that repo's
`docs/design.md` and `docs/mockups.md`.

**The menu is the hub's** (*The menu, two levels deep*), but each container's rows come from
that container: the hub runs `claude-sessions agent` there over ssh, and `agent exec` for the
one child an action needs at your terminal, so every lock and launch is decided inside the
container. `Enter` attaches or resumes, `n` starts a slot in `/workspace`, `c` closes, `s` is
a shell, `?` the keys, `q` quits, `Esc` goes back. A resume runs `claude --resume <id>` in a
new slot from the directory Claude Code filed the conversation under, refused (`which is
gone`) when that directory no longer exists. **The archive is the menu's only**: Claude
Code's files are never touched, so `claude --resume` still finds everything; without the
menu, `claude-sessions doctor` prints each slot's session id.

**Every claude the menu starts scrolls in the terminal's own buffer**, so a swipe scrolls
Termux locally: it gets `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`, `_MOUSE` and
`_VIRTUAL_SCROLL` set to `1` unless the login set them (only an empty `NAME=` turns one back
on). The owner's accepted costs: more flicker after a resize, no focus view, diff panel or
mouse, and history after a dropped link only in a terminal that stayed open (Ctrl+E redraws).
`make verify`'s `scrollvars` line counts the names in the running binary: fewer than three is
a rename, and an issue for claude-sessions.

| Piece | Where | What it does |
|---|---|---|
| the hooks | `/etc/claude-code/managed-settings.d/claude-sessions.json` — the hub volume's `managed-settings.d`, mounted read-only | `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification` and `SessionEnd`, which feed the **menu only** (titles, who is busy); no offload rule reads them. Each calls `claude-sessions hook`, which always exits 0 and prints nothing. All but `SessionStart` (30 s timeout) and `SessionEnd` (1 s) run **async**, so no hook of ours can hold a prompt |
| the keep-alive skill | `~/.claude/skills/keepalive/SKILL.md`, copied by the entrypoint at every start from the hub's volume | when to run `claude-sessions keepalive`, and for how short. A failed copy says so in the boot log and removes any old one, which would name a command that might not exist |
| the status line | the same file's `statusLine` | the container's RAM and load, yellow then red as they rise, and its name. Managed settings outrank a user `statusLine`, so Claude Code's `/statusline` writes one that never shows here |
| `reconcile` | the entrypoint, before sshd | marks slots whose process died with the last container |
| `offload` | run in each container by the hub's `offload-all`, every 3 minutes | stops a detached slot measured quiet for 10 minutes, and runs the orphan sweep. Each pass's verdicts go to the hub's `~/.hub/passes.log`, prefixed by container; stops and sweep lines also go to the container's `offload.log` |

**The hooks file is written by the binary, not kept in this repo**, so the hooks installed
are exactly the events its code handles; as a managed-settings drop-in, a user's
`disableAllHooks` cannot turn it off. **Never also deliver these hooks from the claude.ai
admin console** — server-managed settings put hooks behind an approval dialog and replace this
file outright.

**The rules (owner, 2026-10-08): measured, not read from Claude Code.** `offload` stops a
slot that is **detached**, **not under a keep-alive**, and **measured quiet for 10 minutes** —
no 3-minute window over its byte budget (a minute's worth at its learned line) or 3000 ms of
CPU. Nothing Claude Code reports holds a slot — not a timer, background agents or a
permission prompt: **a slot waiting on you is offloaded too**. Work that waits quietly (a
`sleep`, CI, a `ScheduleWakeup`) is held by **`claude-sessions keepalive <duration>`** — at
most 12h, `0` ends it — and the skill tells claude when; a slot still quiet when it ends goes
at the next pass. **The 3-minute cadence is load-bearing**: the CPU budget per window is fixed,
so a slower timer would read an idle claude's own CPU as activity.

**A slot with no conversation** (before its first prompt, or `/clear`ed) **is closed
instead**. Only a claude whose parent is a zmx session is judged at all — one in the `s` shell,
a forwarded command or `screen` is never offloaded. **The ten minutes do not start at the
detach**: read a long reply, lock the phone, and the slot goes at the next pass; `Enter` brings
it back. Attached means zmx reports a client (`clients=`); a zmx that does not answer keeps
its slot.

Reading it:

```
make idle          every slot's verdict in every container, now — a dry run, nothing stopped
make offload-log   one container's stops and sweeps, and the hub's failed and last passes
make sessions      claude-sessions doctor — per slot, how long since each hook event
make status        includes `offloader : the hub's, last pass Nm ago`, or why not
make verify        the binary's version, the hooks file parsed as dev, the keep-alive skill
```

A dry run still writes the activity state, so a `make idle` just before a live pass leaves
that pass a window too short to count; the next one counts it.

- **`~/.local/share/claude-sessions/hook.log`** is the hook's own failures; `grep dropped`
  answers which events were lost. A dropped `SessionEnd` is **expected** when an offload, a
  menu close or a stalled async hook held the slot — it waits only 400 ms, and `reconcile`
  settles the record. Any other drop is a fault worth an issue; it costs a wrong title or busy
  mark, not an offload.
- **`offload.log`** has every real stop and the orphan sweep (`sweep: killed …`, or `kept, too
  young` under ten minutes old) — **only safe with the agent view off** (*Claude Code in
  here*).
- **"events: none seen"** in `make sessions` means the hooks are not firing.
- Each pass's `memory:` line is free memory by **working set** (reclaimable page cache
  counted as free), the same figure the menu's room check uses.
- `claude-sessions-dry-run.log`, `claude-offload.log` and `claude-sessions-passes.log` in a
  container's `~/.local/share` are from the offloaders before the hub's; remove them by hand.

Overrides, neither normally worth setting: `CLAUDE_SESSIONS_DIR` (the registry) and zmx's
`ZMX_DIR` — each must be the same for every login and the hub's pass, so set one in compose or
not at all. **Never set `ZMX_SESSION_PREFIX`**: slot names would disagree. A source checkout of
claude-sessions goes at `~/.local/share/src/claude-sessions`, never at the registry's path.

## Secrets

None are in git. `.env` and `.env.*` are gitignored; the rest live in mode-700 directories on
zero, each mounted read-only into the one container that needs it:

| `.env` line, default | Mounted | Holds |
|---|---|---|
| `HUB_SECRETS`, `~/.dev-secrets` | the hub, `/run/hub-secrets` | `authorized_keys` — the clients allowed to `ssh dev`; `github-app.pem` — the GitHub App's key, put there by hand; `tunnel.json` — mounted into the sidecar alone |
| `INFRA_SECRETS`, `~/.infra-dev-secrets` | infra-dev, `/run/infra-secrets` | nothing, by default. A client key in an `authorized_keys` here would let it straight in; no fleet key is ever put here (*What it is not*) |
| `OR3_SECRETS`, `~/.or3-dev-secrets` | or3-dev, `/run/or3-secrets` | the or3ecr key, the phone's `authorized_keys`, and or3's deploy key — lent to BuildKit to fetch or3's private repo, and no GitHub credential inside the container. Written by or3's `dev/seed-secrets.sh` |
| `DD_SECRETS`, `DS_SECRETS` | dd-dev, ds-dev | what was each clone's `.dev-ssh/` |

`server-create-dev-container.yml` writes the first two, from nothing that crosses the radio
but the control node's own public key. **The hub's private key is in none of them**: it is made
in, and never leaves, the `hub-state` volume. A repo's `.env` files are in its env volume. The
Claude login (`*-claude`), Crush's key (`~/.local/share/crush`) and jcode's login (`~/.jcode`)
are on the containers' external volumes, which `make down-volumes` leaves alone.

**What a container can reach:**

| | Reaches | Held as |
|---|---|---|
| git and `gh` | its own repo, and no other | the hub's hourly token at `/run/github/token` |
| the fleet | nothing | — |
| the hub | nothing outward — the hub reaches *in*: commands and terminals, `restrict,pty` | `hub.pub`, written to `~/.ssh/authorized_keys.hub` at every start |

Nothing is published on the host; the ways to a shell in a container are the hub, behind
Access, and `docker exec` on zero. **The hub is as good as a shell in every container**, which
is why its key lives in its volume alone and it runs no agent and no claude.

## The targets

```sh
cd ~/infra/dev
make              # the header of the Makefile: every target, one line each
make dev          # up, then login
make up           # build + (re)create everything the profiles name — drops the sessions of
                  # every container it recreates; S=<service> for one (and the hub)
make restart      # stop + start one container; does NOT re-read compose.yaml
make stop         # stop one container; its sessions end, its volumes stay
make status       # one screen: container, sshd, sessions, logins, offloader, the tunnel, ansible
make verify       # status + the tools + the hub + the GitHub token + the collections + the fleet
make login        # the walkthrough: the token, the fleet, claude's login, the workspace clone
make fleet        # ssh to each host, then `ansible fleet -m ping` — says there is no fleet access
make collections  # the image's collections vs ansible/requirements.yml
make claude       # the hub's menu, as `ssh dev` lands on it
make claude-update # update Claude Code now in one container, and say whether it updates itself
make shell        # a login shell in one container (fish in infra-dev, bash in the hub)
make logs         # follow one container's log (= its sshd's)
make boot-log     # one container's entrypoint lines, from the top, ANSI stripped
make tunnel-log   # what the hub's cloudflared has been saying
make idle         # the offloader's verdict in every container, now (stops nothing)
make offload-log  # one container's stops and sweeps, and the hub's failed and last passes
make sessions     # claude-sessions doctor in one container: the registry, and the hooks
make down         # stop and remove every container in the project (volumes stay)
make down-volumes # also drop the project's own volumes — CONFIRM=yes
```

Not in the header, and used by the deploy play's preflight or by hand: `make check` (`.env`,
secrets and external volumes), `make build`, `make check-names` (no other compose project holds
a dev container's name), `make volumes` (creates missing external volumes empty — a fresh box
only), and `make base` (the base, locally).

`C=<container>` picks the container for the targets that take one — infra-dev unless said,
`C=hub` for the hub (`dev-hub`), `C=or3-dev` and so on for the others. They work with or
without `sudo` — the Makefile adds one when it is not already root — and the same set is
available from the repo root as `make dev-up`, `make dev-login` and so on.

The `dev` user's uid comes from the **owner of the checkout** (`stat`), not `id -u`, which is
0 under `sudo` and would write root-owned files into everything shared with the host. It
refuses to build at 0, or when `dev/.env`'s `HOST_UID`/`HOST_GID` — which the deploy play's
compose reads — disagree with the checkout.

`restart` is `stop`/`start` deliberately: `up -d` re-evaluates the config and may recreate
the container, ending every session in it. So a change to `compose.yaml` lands only on `up`
or a deploy — the rule [`../CLAUDE.md`](../CLAUDE.md) states for the deployments.

`make down-volumes CONFIRM=yes` drops **the project's own volumes**: every cloned workspace,
with any unpushed work; every env volume; `claude-sessions` and `github-tokens`; and
`hub-state`, with the hub's key and **its sshd host key** — so every client is then asked to
accept a changed host key for `dev`, the moment a real one would be waved through. Expect it.
The logins, history and each container's own host key are external volumes, which stay.

When the question is why a start went wrong, `boot-log`, not `logs`: the top of the log is
where the entrypoint's lines are.
