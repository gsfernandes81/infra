# dev — the dev containers on `zero`, and the hub in front of them

This directory is one Compose project, `name: dev`, holding every dev container on `zero`
(Pi 5, arm64) and the **hub** that is the way in to all of them: `ssh dev` lands on one
claude-sessions menu over every container. **`infra-dev`** is this repo's own container —
Claude Code against **this** repo, with Ansible in the image — and most of this README is
about it. It **is not a control node by default**: no fleet key, no route to `zero`, `one`
or `two`. That is a decision, not an omission; see *The control-node question, deferred*
below and `../docs/management-plane.md` § *A control node inside the fleet*.

> **⚠︎ Built 2026-10-26, not yet on the fleet.** Until the owner brings it up, zero still
> runs the old layout: `infra-dev` alone in a project of its own name, its `/workspace` a bind
> mount of `~gavin/infra`, with its own tunnel, its own offload loop and the menu inside it.
> git history has the README that described that. Two things stand between this file and the
> box: **claude-sessions 0.5.0 is not released**, so the two hashes in `hub/Dockerfile` are
> placeholders (`FILL-FROM-THE-v0.5.0-RELEASE`) and the hub's build fails at `sha256sum -c`,
> on purpose, until they are filled from the release; and base `2026.10.26` is published by
> CI only when this reaches `main` (`make base` builds it locally meanwhile). Then the move
> itself, which is the owner's — *Moving a container in* below has the order.

## Why this exists

**To run a Claude session on `zero` instead of in the cloud.** That is the whole of it,
and everything else here is either in service of that or is optional and off.

**To stop paying the phone's radio for work that has nothing to do with the vessel.**

Driving Claude from the Android app or from Remote Control means every token of every
response crosses the phone's mobile data — the one metered link on the whole map, and
the rule for reasoning about it is the **or3** repo's `CLAUDE.md` § *Data budget*:
metering follows the destination, not the size, and the phone's radio is the only thing
on the map that costs anything. Working in a container on `zero` instead means the model
traffic goes out over zero's home connection, and what crosses the radio is a terminal
session: your keystrokes and the characters that come back.

`ansible-core` and the three collections are in the image as **development tools** — so
that a playbook you are editing can be syntax-checked, linted and read against the real
`ansible.cfg`. They are deliberately *not* wired to the fleet: by default this container
has no route to `zero`, `one` or `two` at all, and running playbooks against them stays
on the control node. See *The control-node question, deferred* below; it is a decision that has
been consciously postponed rather than an omission.

## What it is not

- **Not a tunnel endpoint.** `or3-dev` runs an sshd that the phone terminates a reverse
  forward on, to reach the vessel LAN. Nothing tunnels back through this one,
  and its `sshd_config` sets `AllowTcpForwarding no` to keep it that way.
- **Not a Remote Control host — and since 2026-08-25 neither is anything else here.**
  This container existed to replace driving Claude from the phone, so shipping a disabled
  daemon for the thing it replaces was always hedging against its own reason to exist.
  That argument turned out to apply to all four: `dd-dev` and `ds-dev` ran a supervisor as
  the container's payload, `or3-dev` shipped one defaulted off, and three arrangements for
  one capability is three things to remember and three ways to be confused at 2am. All of
  it is deleted — the supervisors in their repos, the hook and `DEV_REMOTE_CONTROL` here.
  **One way in, everywhere: `ssh dev`**, which lands on the hub's `claude-sessions` menu
  over every container (since 2026-10-26; before that `ssh <alias>` landed on each
  container's own menu, and before 2026-10-02 on `abduco -A claude claude`). Every session
  it opens survives a dropped link, and it does not put a permission classifier in charge
  of a container holding deploy keys. Adding remote control back is a decision with
  reasoning attached, not a variable somebody sets.
- **Not a holder of the docker socket.** See *The socket line somebody will add* below.
- **Not a control node, by default.** It ships ansible but no route to the fleet. See
  *The control-node question, deferred*.

## Layout

| | |
|---|---|
| `Makefile` | **the management interface** — `make up`, `make login`, `make status`, …; `C=<container>` picks the container (infra-dev unless said, `C=hub` the hub), `S=<service>` limits `make up` to one |
| `compose.yaml` | the Compose project — `name: dev`: `hub`, its `cloudflared` sidecar (profile `tunnel`), `infra-dev`, and `or3-dev`, `dd-dev`, `ds-dev` each behind a profile of its own name; one network, `dev`; **nothing published on the host** |
| `hub/` | the hub's image: `Dockerfile` (claude-sessions pinned by release and per-arch SHA-256), `entrypoint.sh`, `door` (installed as `hub-door`, its sshd's `ForceCommand`), `sshd_config`, and `ssh_config` — how it reaches each container |
| `cloudflared.yml` | the hub tunnel's ingress, and the whole of it: `dev.gsrpi.uk` → `ssh://hub:2222` |
| `Dockerfile.base` | `gsrpi-dev-base`, which every dev container is `FROM` — Debian trixie slim + Node 22 + Claude Code + gh + zmx + screen + sshd |
| `Dockerfile` | infra-dev: the base + **ansible** |
| `entrypoint.sh` | ssh material and the hub's key → Claude config → clone or pull the workspace → link the env files → `reconcile` → **sshd(fg)** |
| `login.sh` | in the image: the interactive logins, and the clone if start-up could not make it — idempotent, `make login` |
| `status.sh` | on the host: the readouts — `make status`, `verify`, `fleet`, `collections` |
| `in-workspace` | in the image, on PATH: run a command where the work is, so no client names the path |
| `dev-door` | in the image, on PATH, and sshd's `ForceCommand`: a forwarded command as given — the hub's calls among them — and otherwise a login shell in `/workspace`. It was `claude-sessions-door`, and opened the menu, until 2026-10-26 |
| *(no setup script)* | the host side is `ansible/playbooks/server-create-dev-container.yml`, run from a control node |
| `sshd_config` / `ssh_config` | the in-container daemon, and the baked half of how it reaches out |
| `config.fish` | fish's config, baked in — puts every login shell in `/workspace` |
| `.env.example` | copy to `.env` on zero; **one `.env` for the whole project, and every line in it is required** — Compose refuses a required variable it cannot fill even for a service whose profile is off |

## Bring-up, from nothing

**No fleet access, and one Cloudflare tunnel — the hub's.** The host side is two runs of a
playbook from a control node — the phone — because that is where ansible is and because the
setup is not something zero should have a script for:

```sh
# on the control node
cd ~/infra/ansible
ansible-playbook playbooks/server-create-dev-container.yml --check --diff     # prove first
ansible-playbook playbooks/server-create-dev-container.yml                    # infra-dev
ansible-playbook playbooks/server-create-dev-container.yml -e container=dev   # the hub
```

**The plain run is infra-dev's host side.** It creates the secrets directory, generates the
GitHub deploy key, authorises this control node's own public key, starts `dev/.env` from
`.env.example` if there is none, and writes `INFRA_SECRETS` into it — by line, because that
file now serves every container in the project and the hub. It prints the one `gh repo
deploy-key add …` command it cannot run itself. Its edge half still makes or confirms
infra-dev's *own* tunnel, DNS record and Access application, the pre-hub way in; nothing
uses them once infra-dev runs here, and retiring them is a change of its own.

**`-e container=dev` is the hub's.** The edge half makes the tunnel `dev`, the record
`dev.gsrpi.uk` and an Access application with no policy yet; then `_dev-hub-host.yml` makes
`~/.dev-secrets` (0700) — `tunnel.json`, gavin-owned 0600 so the sidecar can read it, and
`authorized_keys` with this control node's key, the clients allowed to `ssh dev` — and writes
`HUB_SECRETS` and `HUB_TUNNEL_ID` into `dev/.env`, the id beside the credentials it came from,
in the same run. **The hub's own key is not made here and never is**: the hub makes it at
first start, in its own volume (*The hub*, below).

Then, on zero, in your own terminal — `gavin` is not in the docker group, so this half is
never an ansible job:

```sh
cd ~/infra/dev && make dev     # build, start the hub, its tunnel and infra-dev, then walk the logins
```

And on each client — the machine you ssh *from*:

```sh
ansible-playbook playbooks/client-home-ssh-config.yml -e container=dev
ssh dev
```

`make dev` is `make up` followed by `make login`. `make up` builds and starts whatever the
profiles in `.env` name — the hub always, `cloudflared` with `tunnel` in `COMPOSE_PROFILES`
(the example has it), and infra-dev — with every dev container waiting for the hub to be
healthy first. `make login` is the walkthrough in `login.sh`: the deploy key, the fleet
(reported as not configured, which is the default), `gh auth login`, `claude auth login`, and
the workspace clone if start-up could not make it. Every step reads the current state first
and only prompts for what is not done, so re-running it is safe and usually silent. Only the
logins are interactive, and both need a tty — which is why they are in the image rather than
in a playbook.

Then `make verify` should read `sshd: running in the foreground`, `auth: claude logged
in`, `colls: all of requirements.yml is installed`, `hub: key authorised; claude-sessions
0.5.0 here, claude-sessions 0.5.0 at the hub`, and `fleet: no route to zero/one/two` — that
last one is the default, not a fault. `make status` also shows `tunnel: the hub's, serving
dev`, and `make status C=hub` is the hub's own.

| | What it adds | Why it is off |
|---|---|---|
| *(not built)* | ssh to zero, one and two | makes this a control node on a box it controls — deferred |
| `DEV_CGROUP_PARENT=/devpool` | one memory pool over every dev container | the pool's boot file is not installed yet — [`../plans/dev-pool.md`](../plans/dev-pool.md), step 1 |

The tunnel is a profile, not a requirement: with `tunnel` out of `COMPOSE_PROFILES` the hub
and the containers come up anyway, and `make claude` on zero is the menu `ssh dev` would have
given.

## The hub

`dev-hub`, built from `hub/`: a small image with no Claude Code, no node and no repo. It is
the one container an ssh login lands on, and it does four things.

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
rename, so a hook already running keeps the binary it started from. The hub's healthcheck
passes once the binary, `hub.pub` and the drop-in directory exist, and every dev container
`depends_on` it being healthy, because a subpath that does not exist cannot be mounted at
all.

**The key.** The hub makes an ed25519 key at its first start in its own `hub-state` volume
(`~/.hub/id_ed25519`), and it is never anywhere else — not on zero, not on a control node,
not in any other container; that is why the hub runs no agent of any kind. Only the public
half leaves, as `hub.pub`, and each dev container's entrypoint appends it to its
`authorized_keys` at start as `restrict,pty <key>`: commands and a terminal, no forwarding,
no agent. The hub's `ssh_config` is one `Host *`: port 2222, user `dev`, that key,
`accept-new` into `~/.hub/known_hosts` — learned on first contact over a network nothing
else joins, then pinned, so a changed key still refuses — `BatchMode`, and a `ControlMaster`
at `~/.ssh/cm/%C`, which is what makes the menu's second connection for an attach cost a
round trip rather than a handshake.

**The offloader.** The per-container offload loops are gone; the hub runs `claude-sessions
offload-all` every three minutes at a fixed rate, which runs `claude-sessions offload` in
every container at once over ssh, each line prefixed with its container. The measurement
still happens *inside* each container — it reads `/proc` and the socket-diagnostics
netlink, which answer only in the container's own namespaces — so only the timer moved.
Each pass goes timestamped to `~/.hub/passes.log` in the hub (capped near 16 MB, trimmed to
the newest 8 MB). `HUB_OFFLOAD=0` in `.env` stops the timer for everyone;
`DEV_IDLE_OFFLOAD=0` stops it stopping anything in infra-dev, which compose passes on as
`CLAUDE_SESSIONS_OFFLOAD=0` — that container's pass says so and looks at nothing.

**Which containers** is `HUB_HOSTS` in `.env` — names on the `dev` network,
space-separated, in the order the menu shows them, and only containers on base `2026.10.26`
or later, which mount the hub's volume. With one name there, as today, there is no home
screen: the menu is that container's, exactly as it was inside it.

### The menu, two levels deep

The owner's shape (2026-10-26), drawn in claude-sessions'
[`docs/mockups.md`](https://github.com/gsfernandes81/claude-sessions/blob/main/docs/mockups.md),
mockups 12 to 15, and binding as the rest of that file is:

- **The home is the containers**, one row each, in `HUB_HOSTS` order, with what is in it in
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

## The workspace and the env volume

**`/workspace` is the container's own named volume, `infra-workspace`, cloned into — no
longer zero's checkout.** zero's `~gavin/infra` is now only what the box runs; the
container's tree is its own, so a commit made in here can never again leave zero's checkout
diverged (`../CLAUDE.md` § *Git*, the 2026-10-25 divergence). **Push to share work**, as
from anywhere else.

At start the entrypoint fills an empty `/workspace` from `DEV_REPO` (set per service in
`compose.yaml`): with `gh repo clone` when gh is logged in, and otherwise with `git clone
git@github.com:$DEV_REPO` and the deploy key from the secrets mount, so a first start does
not wait for `make login`. The global `insteadOf` rewrite turns gh's https URL into ssh, so
both ways go out with the deploy key and differ only in what they need. A volume that holds
files but no checkout is left alone with a warning — it is somebody's work. After that,
every start pulls `--ff-only`, best-effort, as it always did. If both clones failed (the
deploy key not yet registered, no network), `make login` clones once gh works.

**A repo's untracked secrets live in a second volume, `~/.env.d`, linked into the
workspace.** `DEV_ENV_FILES` (per service, space-separated workspace paths; `.env` for the
children, none for infra, whose `.env` files live on the hosts) names them. Each becomes
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
it, and every env volume — along with the hub's key. **or3-dev keeps its bind mount**: its
`/workspace` is zero's own clone of or3 by or3's design, and changing that is or3's call
([`../plans/dev-pool.md`](../plans/dev-pool.md)).

## Moving a container in

### infra-dev itself — the first move

The old `infra-dev` project and this one cannot both run: they name the same container.
**Every live session in infra-dev ends at the move.** The conversations do not — the
`~/.claude` volume moves across — and each is resumable from Archived afterwards.

1. **Release claude-sessions 0.5.0, and fill the two hashes** in `hub/Dockerfile` from the
   release's `SHA256SUMS` asset (also in its notes), in a commit here.
2. **Push everything first.** `/workspace` stops being zero's checkout and becomes a fresh
   clone, so a commit that exists only in `~gavin/infra` on zero is not in the new container.
   Nothing is deleted — the host checkout stays where it is — but account for every local
   commit before moving on: `git log --left-right --cherry-mark HEAD...origin/main` in
   `~gavin/infra`, and each `<` needs a `=` twin upstream (`../CLAUDE.md` § *Git*).
3. **The two playbook runs** from *Bring-up, from nothing* above, from the control node.
   They start nothing. On an existing `dev/.env` the plain run only sets `INFRA_SECRETS`,
   and the old file's other lines are the old layout's, so on zero move it aside first
   (`mv ~/infra/dev/.env ~/infra/dev/.env.old`) and let the runs start the new one from
   `.env.example`.
4. **Stop the old project, keeping its volumes, then start this one.** `ssh -t zero`, then
   inside it:

   ```sh
   cd ~ && sudo docker compose -p infra-dev down     # from ~, so it reads no compose file
   cd ~/infra/dev && make dev
   ```

   `down` without `-v` removes the container and its network and leaves every volume. Not
   from `dev/`, where it would read the new `compose.yaml`, and not `make down`, which now
   means project `dev`. The new file names the old volumes as **external** —
   `infra-dev_infra-claude`, `_infra-gh`, `_infra-ssh-host`, `_infra-local-share`,
   `_infra-jcode` — so the logins, the conversation history and the sshd host key move
   with it.
5. **On each client**, `client-home-ssh-config.yml -e container=dev`, then `ssh dev`. The
   old `infra-dev` block stays in `~/.ssh/config` for now, and once the move is done it
   names a tunnel with no connector behind it — infra-dev's base no longer carries
   cloudflared — so `ssh infra-dev` fails at Cloudflare. That is expected.

### Another repo's container

`or3-dev`, `dd-dev` and `ds-dev` are already in `compose.yaml`, each behind its profile.
Moving one in is, **in its own repo first**:

- bump its `BASE_TAG` to `2026.10.26` or later;
- drop its own `compose.yaml` — this one is its compose file now;
- if an `sshd_config.d` drop-in sets `AuthorizedKeysFile` (dd-dev's and ds-dev's
  `10-authorized-keys.conf` do), add `.ssh/authorized_keys.hub` to it, which is where the
  entrypoint puts the hub's key.

**Then here:**

1. Its secrets directory exists at the path its `*_SECRETS` line in `.env` names. No
   playbook makes one for these three yet, so by hand — mode 700, the contents its old
   setup had.
2. `docker volume ls`, and check the external names in `compose.yaml` against what is there.
   They are guesses that follow the old project's pattern, and `up` refuses loudly if one is
   wrong.
3. Stop its old project the way infra-dev's was: `sudo docker compose -p <old-project> down`,
   no `-v`.
4. Add its profile to `COMPOSE_PROFILES` and its name to `HUB_HOSTS`, then `make up`. The
   hub's environment changed, so the hub is recreated too: every `ssh dev` session drops,
   and no claude does.
5. Its `.env`, if it has one: write it at `~/.env.d/.env` inside the container (`make shell
   C=<c>`), and restart it to link it. For or3, whose workspace is still the host clone, the
   existing `.env` there is a regular file, so the entrypoint reports it and leaves it —
   moving it into the env volume is or3's call.

Its old tunnel and the client block that points at it are retired in a change of their own —
**except or3-dev's block, which stays.** The phone's `or3-tunnel` holds `ssh -N -R
2236:10.1.0.236:22 or3-dev-sh`, a reverse forward to the vessel LAN that has to land inside
or3-dev, so `or3-dev.gsrpi.uk` keeps pointing at or3-dev's own sshd, now through the hub's
tunnel (`cloudflared.yml`). At its move-in, after `make up`, from the control node:

```fish
ansible-playbook playbooks/server-create-dev-container.yml -e container=or3-dev -e via_hub=true
```

That re-points the hostname's CNAME at the hub's tunnel and keeps its Access application and
every client's token, so the phone's alias, its token and or3's tool are untouched. Between
the old project's `down` and that run the phone's tunnel is down, and `or3-tunnel` retries on
its own (at most five minutes apart). Then `ssh or3-dev ssh or3ecr hostname` from the phone
answers `OR3-ECR1-GR` again. Only or3-dev's *old tunnel* is retired after that.

## How this container is used

**You `ssh dev` and pick a session from the menu** — from Termux on the phone, or from a
PC. `Enter` on infra-dev (or straight in, while it is the only container), then `Enter`
attaches or resumes, `n` starts a session in `/workspace`, `s` gives a login shell there.

**What a login to the container runs is the container's decision.** sshd forces every
session through `dev-door` (`sshd_config`'s `ForceCommand`): a forwarded command runs as
given, in `~`, exactly as it would without the door — the hub's `claude-sessions agent`
and `agent exec` calls are forwarded commands, so this is all the hub needs of it — and
anything else gets a login shell in `/workspace`. The menu is not in here any more; it is
the hub's.

**Through the hub, a command is two hops:** `ssh dev ssh infra-dev 'in-workspace git log'`
— the outer `ssh` runs `ssh infra-dev …` in the hub with the hub's key, and the inner one
runs the rest in the container. Two rounds of shell quoting, so keep the inner command
simple. **scp, sftp, Zed and `ssh -L`/`-R` to a container have no route at all** since the
container lost its own tunnel: the hub's sshd forwards nothing, and its key in each
container is `restrict`. That is a gap this change opened and has not closed; until it is,
a file goes over as a stream (`ssh dev ssh infra-dev 'cat /workspace/f' > f`), or you work
on it in the container.

**`in-workspace` is a program in the image** for the commands that want the repo. It cds
to `/workspace` and execs whatever it was handed — the directory and nothing else. *Where
the work is* is the container's business: no client should have to name the path. *Whether
to hold the session across a dropped link* is the menu's: what it opens is a zmx session,
because ssh dies at the phone's lock screen, while a laptop running a one-shot command wants
no session holder at all.

The `cd` is needed for a reason worth knowing, because the symptom is baffling: sshd runs
a remote command as `$SHELL -c '…'`, which is **not a login shell**, so `config.fish`'s
`status is-login` guard is false and its cd never fires. A plain login *does* get a login
shell and lands correctly, and `docker exec` is fine too because it honours the image's
`WORKDIR`. Only the remote-command path is affected — which is why a forwarded command
lands in `~` and `in-workspace` is how one asks for the repo. And it matters because the
entrypoint seeds Claude Code's trust dialog for `/workspace`: a session started in
`/home/dev` asks you to trust a directory that is not the repo.

Each slot is a **zmx** session (since claude-sessions v0.4.0; abduco before). The menu
starts it and attaches it; **Ctrl-\\** detaches; what is under it keeps running, and a
dropped connection costs nothing. zmx replays the session's recent history on every
attach — about 1.08× the bytes, capped near 10,000 lines (≈120 KB after ssh compression
at 80 columns), so one lock-screen drop on the phone costs one replay — and, unlike
abduco, never switches the terminal to the alternate screen, which is what lets a wheel
or a swipe scroll the terminal's own buffer instead of arriving in claude as arrow keys.
Detaching sends `ESC c`, which clears Termux's scrollback; the history comes back with
the next attach. A claude started *outside* a session dies with the ssh link that carried
it, which on a phone means dies at the first lock screen.

**There are two ways in and you want both.** `ssh dev` is the normal one — Cloudflare,
Access, the sidecar, the hub's sshd — and the only one with an alias. The break-glass one
is `docker exec` through zero's own ssh, typed rather than aliased:

```sh
ssh -t zero 'cd ~/infra/dev && make shell'        # a shell in infra-dev; C=<c> for another, C=hub the hub
ssh -t zero 'cd ~/infra/dev && make claude'       # the hub's menu, as ssh dev lands on it
```

It survives a broken tunnel, Access application or token, and a hub whose sshd is down —
`make shell` reaches a container without the hub at all. It had an alias until 2026-08-31
and a published loopback port until 2026-10-04; the alias went because a client-side alias
must name the host the container sits on, which a movable container does not have, and the
port went because it only ever bought a passwordless hop through the same sshd.
[`../docs/ssh-clients.md`](../docs/ssh-clients.md) has the reasoning.

The Makefile is how the containers are stood up and looked at, not how they are used.
`make claude` is the same menu `ssh dev` lands on, reached from a terminal on zero — the
same sessions, not a second set.

## Crush, on trial

[Crush](https://github.com/charmbracelet/crush) is in the base since `2026.10.11`, so every
container on that base or later has it. The way in is the plain one, with nothing built
around it:

```sh
ssh dev                        # then s on infra-dev: a login shell in the repo
crush                          # first start asks for a provider and its key
```

- **No slot.** The claude-sessions menu, its hooks and the offloader know nothing about
  Crush. It is not in a zmx session, so a dropped connection ends it — on the phone that
  means the first lock screen. `crush --continue` picks up the last session in this
  directory. Checked at 0.98.1: it leaves no process behind when it exits.
- **Its state.** The provider key and global settings go under `~/.local/share/crush`
  (the `~/.local/share` volume, so they survive a recreate, and `make down-volumes` takes
  them — see *Secrets*); per-project sessions go in `.crush/` in the working directory,
  which here is the repo. Crush writes a `*` `.gitignore` inside it, and the repo ignores
  `.crush/` as well. `crush dirs` prints both. `~/.config/crush` is not a volume — anything
  written there is gone at the next recreate.
- **Context it reads.** `CLAUDE.md` and `AGENTS.md` among others, so the repo's rules
  reach it as they reach Claude. **Decline "Initialize Project"** — it writes an
  `AGENTS.md` into the repo, which would be a second copy of `CLAUDE.md`.
- **Usage metrics are Crush's default, which is on** (pseudonymous events to Charm). Left
  as it is, not chosen against: turning them off is `"options": {"disable_metrics": true}`
  in a Crush config, or `CRUSH_DISABLE_METRICS=1` — the owner's call, not yet made.
- **The version is the latest release when the base was built, not a pin**, and nothing
  inside a container updates it. CI resolves it (`crush-latest`) and the run's summary
  names it; `make verify`'s `crush` line reads it off a running container. The layer
  re-downloads only when Charm has released since the last tag (~25 MB), not on every
  bump. `make base` takes that day's release, so a local build of a tag can be newer than
  CI's; with GitHub or `repo.charm.sh` down, `make base CRUSH_VERSION=none` builds without
  it. `Dockerfile.base` (the Crush layer) and
  [`../docs/decisions.md`](../docs/decisions.md) have the reasons.

## Jcode, on trial

[Jcode](https://jcode.sh) (`1jehuang/jcode`, MIT, Rust) is in the base since `2026.10.16`,
alongside Crush. Same plain way in:

```sh
ssh dev                        # then s on infra-dev: a login shell in the repo
jcode                          # first start offers provider OAuth or a key
```

- **No slot, and not offloaded on purpose.** Like Crush, jcode is not in a zmx session and
  the claude-sessions menu and offloader know nothing about it. Unlike Crush, that is a
  choice made deliberately: jcode is light enough not to need offloading. Running `jcode`
  auto-starts a detached background server (`setsid()`); jcode's own 5-minute idle timeout
  reaps it, so nothing else is asked to.
- **Its state.** Everything — config, sessions, skills, and the provider login — lives
  under `~/.jcode`, mounted as its own `infra-jcode` volume (the login lands in
  `config/jcode/` beneath it), so it survives a recreate and `make down-volumes` takes it.
  Per-project session state is `.jcode/` in the working directory; the repo ignores it.
- **Context it reads.** `CLAUDE.md` and `AGENTS.md`, so the repo's rules reach it. Decline
  any offer to initialise a project — that writes an `AGENTS.md`, a second copy of
  `CLAUDE.md`.
- **The version is a hash-pin, not a release, and it is bumped by hand.** jcode has no
  signed repository — only unsigned tarballs with a self-vouching `SHA256SUMS` — so there
  is no signature to vouch for "latest". `Dockerfile.base` pins a version and a per-arch
  SHA-256 (the cloudflared model); a new jcode release is a one-line bump there, not a
  `dev/jcode-latest` run.
- **It updates itself, and the install is laid out so that works.** jcode auto-updates by
  default (`jcode update`, `--auto-update`): it downloads a new release into
  `~/.jcode/builds/versions/` and repoints the `stable` symlink, and the launcher on PATH
  follows it. That is why the binary is **not** in root-owned `/usr/local/bin` — it is
  installed the way jcode's own installer does, as `dev`, with the real binary in
  `~/.jcode/builds` and a launcher symlink at `~/.local/bin/jcode` (first on PATH). An
  update lands on the `infra-jcode` volume, so it survives a recreate; a fresh container
  still starts on the pinned version the image carries.
- **Telemetry.** The official `curl | bash` installer phones home to `telemetry.jcode.sh`;
  this image fetches the tarball directly, so that path is not taken. Any runtime usage
  metrics ship at jcode's own default — left as it is, not chosen against. `make verify`'s
  `jcode` line reads the version off a running container. `Dockerfile.base` (the Jcode
  layer) and [`../docs/decisions.md`](../docs/decisions.md) have the reasons.

## The docker CLI is here for `config`, and only that

`docker` and the Compose plugin are in the image, hash-pinned, so the `docker compose
config` diff CLAUDE.md asks for before a compose change can be made from in here. There is
no engine and no socket (the section above still holds), and `DOCKER_HOST` points at a path
that does not exist: `docker compose up` fails at once and says it cannot reach a daemon,
while `config` renders. Render against a copy with a made-up `.env`, never the real one,
since the output interpolates it.

## Ansible from in here

```sh
ansible fleet -m ping                      # from any directory — see below
ansible-playbook playbooks/server-generate-fleet-inventory.yml -K
```

**`ANSIBLE_CONFIG` is set in the image** to `/workspace/ansible/ansible.cfg`. On the
phone, `ansible.cfg` is found only in the cwd, so every run needs `cd ~/infra/ansible`
first and forgetting it produces `No inventory was parsed` — which reads as a broken
inventory rather than a wrong directory, and cost half an hour once. Naming the file
absolutely removes that failure. It points *into the workspace*, so the config in
force is the checkout's and there is no second copy in the image to drift from it.

That works because a relative path inside `ansible.cfg` resolves against **the config
file's own directory**, not the cwd — which is the part worth having checked rather than
assumed, since the whole arrangement rests on it. Verified on ansible-core 2.21.3, the
version this image pins, against this repo's real `ansible/` directory from an unrelated
working directory: `ansible-inventory --list` returned all three hosts with `group_vars`
and `host_vars` applied, and the same command with `ANSIBLE_CONFIG` unset reproduced the
`No inventory was parsed` warning exactly. If a future ansible changes that resolution,
this is the line that breaks and `make fleet` is what says so.

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

**`-K` still works and is still required**, and that is the design rather than a wart.
`gavin` is not in the `docker` group ([`../docs/decisions.md`](../docs/decisions.md):
it is root-equivalent) and NOPASSWD sudo is in
[`../docs/roadmap.md`](../docs/roadmap.md)'s *Not doing*, so escalation costs a
password. You are at an interactive ssh session, so you can type it. A container that
could escalate on all three hosts without anyone present is exactly what this repo has
declined to build twice.

**The collections are baked, not installed at start.** A start that reaches Galaxy is a
start that fails when the network is down. The cost is that the Dockerfile names them
and so does [`../ansible/requirements.yml`](../ansible/requirements.yml) — two lists
that must agree, because the build context is `dev/` and widening it to the repo root
to read one file is worse. `make collections` compares them, so the drift is caught
rather than assumed away. It compares **names, not versions**: `requirements.yml`
states floors, so a version difference is not a fault, but a collection that is asked
for and absent is.

`ansible-core` is **pinned exactly**, unlike Claude Code, and for a reason specific to
there being two control nodes: a playbook that works on one and not the other is the
failure mode, and a floating version makes that arrive at a moment of its own choosing.
The phone is on 2.21.0 and this image is on 2.21.3 — that is a real divergence, and
closing it means bumping the phone, not floating this.

## Debian trixie, for glibc 2.41

**The base is `python:3.13-slim-trixie` as of the `2026.09.21.1` tag, and the reason is
the libc floor.** Bookworm carried glibc 2.36; trixie carries 2.41, which clears the
2.39 that was asked for. Nothing else about the distro was the motive, and the change is
two `FROM` lines — but a distro bump is never only the package you wanted, so what else
moved is written down rather than discovered later.

| moved | consequence |
|---|---|
| glibc 2.36 → **2.41** | the point of the change |
| OpenSSH 9.2 → **10.x** | two claims in `sshd_config` were *measured* on 9.2 — that a drop-in's `Match` is confined to that file, and that `sshd -T` already reports `compression yes`. They are annotated there as owing a re-measure, with the two-minute command to do it |
| fish 3.6 → **4.x** | the login shell. `config.fish` uses `status is-login` and `cd`, which is the least of fish's surface |
| Python 3.13 | unchanged — same image line, same interpreter for `entrypoint.sh` |
| Node 22 | unchanged, still NodeSource. That repository serves trixie; it is also the line most likely to be what breaks, and `Dockerfile.base` says what the fallback is |

**What does not move: the host kernels.** These containers run on Alpine — musl, no glibc
at all — and a container's libc is its own business. glibc 2.41's kernel floor is far
below the 6.x on `zero` and `one`, and the syscalls a newer glibc reaches for (`clone3`
and friends) were already being made by 2.36 on those same boxes under that same docker,
so a seccomp refusal would have arrived long before this bump rather than because of it.

**What the bump did *not* make free: the abduco build stage stayed** (until abduco left the image on 2026-10-06). It was there because
bookworm had no `abduco` package, and this repo's comment had said for a month that
Debian had it "in trixie and sid only" — so moving to trixie looked like it ended the
need for a compiler stage. It did not. `apt-get install abduco` fails on trixie with
`E: Unable to locate package abduco`, on both architectures, against main,
trixie-updates and trixie-security. That was the `2026.09.21.2` build, and it is the only
time the claim was ever executed rather than repeated.

The lesson is the repo's own and keeps recurring: **a fact nobody has run is not a
measurement, however long it has sat in a comment.** The five-minute CI build is what
turned it over, which is an argument for the automatic build rather than against the
change. The stage was then the way this image got abduco at all, not a workaround for an
old base — until 2026-10-06, when zmx replaced abduco and the stage went.

**Verifying the bump is `make verify`.** It now opens with a `libc` line — `ldd
--version` from inside the container — because the floor is otherwise invisible from
outside it, and a `FROM` line reverted by a careless edit would show up nowhere else in
that readout. The rest of the list is the same one that already mattered: `claude`, `gh`,
`zmx` (abduco until 2026-10-06), `screen`, `cloudflared`, `crush` (since `2026.10.11`) and the collections are each printed, and every one of
them is a thing a distro bump can break.

## Claude Code updates itself

**Since the `2026.09.21` base, the version of Claude Code in this container is a floor,
not a fact.** It starts on whatever the image was built with and moves past it on its
own, in the background, with the new version taking effect the next time you start a
`claude`. That is the one thing a `BASE_TAG` no longer pins.

**Why it had to change.** Claude Code ships several releases a week. Pinning it means a
base rebuild, a tag bump and four repos moved for every one of them, which nobody was
ever going to do — so what the pin actually bought was a container quietly months
behind. Worse, the auto-updater *was* there all along and could not run: `npm install
-g` as root writes `/usr/lib/node_modules`, every session in here runs as `dev`, and
Claude Code says it cannot update itself exactly once, at start-up, inside a TUI, in a
container you leave running for weeks.

**What makes it work is one property.** The npm prefix is `/opt/npm-global` and it is
owned by `dev`, so the account that runs `claude` can replace it. Nothing else is
configured: no timer, no wrapper, no daemon of ours. The updater rewrites
`/opt/npm-global/bin/claude` in place, so everything that names `claude` — an ssh
session, `make claude`, the offloader matching on the process name — keeps working
unchanged.

**It is `/opt` rather than `~/.npm-global` for a reason worth keeping.** This container
mounts four named volumes over paths inside `/home/dev`, and **a named volume only
inherits the image's content while it is empty**. A binary baked under a volume's
mountpoint is visible on the container that created that volume and hidden from every
one after it — a `claude` that breaks on a rebuild months later, for a reason nobody
would connect back to a volume. `~/.local/bin` is still first on `PATH`, because that is
where Claude Code's own installer puts a launcher if one is ever run in here.

**Node stays in the image because of this**, and it is worth knowing before somebody
removes it: the `claude` npm installs is a native binary that does not run on Node, so
nothing in ordinary use needs Node in here any more — but the updater shells out to
`npm`, and with npm off `PATH` it fails saying *"Check your internet connection"*, which
points at the network rather than at the missing tool.

**A start still needs no network**, which is the same rule the baked collections and the
baked `cloudflared` are here for. The image carries a working `claude`; the update is
opportunistic. A container with no route out runs what it was built with.

**What it costs**, stated rather than discovered: each container updates itself
separately, so four dev containers on `zero` fetch the same release four times. That is
zero's own home line and not the phone's radio — the [data budget](#why-this-exists)
rule cares about the destination, and this one is free.

### Reading it and steering it

| | |
|---|---|
| what this container is running now | `make verify` — the `claude` line |
| whether it can still update itself | `make verify` — the `autoupdate` line, from `claude doctor` |
| what it started with, and when | `make boot-log` — the entrypoint prints the version at every start |
| update now, without waiting | `make claude-update` |
| stop updating | `DISABLE_AUTOUPDATER: "1"` in `compose.yaml`'s `environment:`, then `make up` |
| which channel it follows | **`stable`**, from the base's managed settings since 2026-10-07 — about a week behind `latest`, skipping releases with major regressions; `make verify`'s `autoupdate` line names it. **Forward only:** a new container starts on the build day's `latest` and stays there until stable passes it — the updater never steps down, and that is accepted. Back to `latest`: edit `dev/claude-managed-settings.json` and bump `BASE_TAG` — managed settings outrank `~/.claude/settings.json`, so it cannot be changed from inside a container |

**The `autoupdate` line does not read the field you would expect, and that is the point.**
`claude doctor` has an `Auto-updates:` field, and it says `enabled` **whether or not an
update can actually land** — it reports the `DISABLE_AUTOUPDATER` setting and nothing
else. Measured on 2.1.278, both ways round: an npm prefix owned by the account that runs
claude and the same prefix owned by root print that identical line, and the only thing
that differs is a warning, `Can't auto-update: npm global folder isn't writable`. So
that warning is what `make verify` looks for, with `Last update attempt: success → …`
as the corroboration — an update this container actually performed, which no reading of
settings can fake. A check built on the obvious field would have passed on exactly the
broken arrangement this change exists to fix.

**How that was established**, since nothing in an agent session can reach a container on
`zero`: both cases were built and run in a throwaway sandbox — install the npm package
into a prefix, hand it to an unprivileged account, run `claude doctor` as that account,
then `chown` the prefix to root and run it again. The end-to-end proof is separate and
stronger: 2.1.275 installed into a user-owned prefix, `claude update` run as that
account, `Successfully updated from 2.1.275 to version 2.1.278`, the `bin/claude` path
unchanged and still owned by the user. What has *not* been run is the image itself —
that needs `make base` or the `dev-base` workflow, and `make verify` on the container is
the acceptance check.

## The agent view is off, and cannot be turned back on in here

**Pressing ← at an empty prompt costs a gigabyte.** The footer offers it — *"← for
agents"* — and what it starts is a `claude daemon`, a warm `bg-spare` with its
`bg-pty-host`, and further full sessions behind those. Measured on 2026-10-01 against
Claude Code 2.1.286, in a pty with a throwaway config:

| state | RSS |
|---|---|
| plain interactive session, idle 60 s | ~250 MB — `claude` alone, no daemon |
| after one **←** at an empty prompt | ~1,260 MB |
| back at the prompt a minute later | ~1,250 MB — nothing released |
| after that session exited | ~690 MB still running, until `claude daemon stop --any` |

`zero` has 4 GB and carries four of these containers. That last row is the part that
matters most: the leftovers **outlive the session that started them**, and were invisible
to the old offloader, which walked down from abduco and found nothing above them — the
current one's orphan sweep is what kills such a tree, and only because the view is off
([the idle-claude offloader](#the-idle-claude-offloader)). or3-dev was holding ~700 MB of daemon and spares on
2026-10-01 for precisely this reason.

**So the base bakes `{"disableAgentView": true}` into
`/etc/claude-code/managed-settings.json`.** Managed settings, not a user or project
setting, because this is fleet policy about zero's RAM rather than a repo's preference:
a checkout's `.claude/settings.json` and the `~/.claude/settings.json` on the
`infra-claude` volume both lose to it. **←** then does nothing, `claude agents` refuses
by name (*"disabled by the 'disableAgentView' setting"*), and no daemon starts.

**What it costs, stated rather than discovered:** `claude --bg` and `claude agents` are
unavailable in these containers. That is the intended trade, not a side effect.

**And since claude-sessions v0.3.0, something depends on it.** The live offloader's orphan
sweep kills any transient `claude daemon` tree that has outlived its `claude`, which with
the view off is only ever a leak — and with it on is agent view's supervisor doing its
job. Turning the view back on anywhere means stopping the offloader there first
([claude-sessions](#claude-sessions)).

**There are two switches, and `make verify` prints both.** The image also sets
`CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, which the entrypoint publishes into
`~/.ssh/environment` so it reaches ssh sessions too. The variable is not a hedge about
where the file goes — **the binary checks it first, before any settings file is loaded** —
so it is the switch that holds in the states the file does not: a malformed file is
ignored whole, and a settings path that a later version moves takes the file with it.

```
agentview : managed settings say off; env=1
```

Two switches, two fields, and not a single PASS — a verdict that collapsed them would
hide the one case they exist for. **The file is parsed, not grepped**, and that is a fix
rather than a flourish: the first version of this line matched the substring
`"disableAgentView":true`, which reads *off* for a file truncated after the word `true`
— no closing brace, so Claude Code's own parse fails, it ignores the file, and the view
is on while the readout says otherwise. It also read *off* for the key nested under some
other object and *not off* for a tab after the colon. A substring test cannot answer a
question about JSON. The check now asks what the binary asks, `=== true` included, so a
`"true"` string is correctly reported as not off.

**Where the path came from**, because this repo does not take a documented default on
trust: grepping the installed binary (2.1.286) in this container on 2026-10-01 gives
`default:return"/etc/claude-code"` for every platform that is not macOS or Windows, with
a `managed-settings.d` drop-in directory beside the file, and the gate itself reading
`if(a.CLAUDE_CODE_DISABLE_AGENT_VIEW) … if(aI()?.settings.disableAgentView===!0) …`.
That closed the one Phase 0 question this change had shipped a hedge for. One corollary
worth knowing: the variable is tested for truthiness, so `CLAUDE_CODE_DISABLE_AGENT_VIEW=0`
**also** disables the view — it is not how you turn it back on.

**The measurement's caveats**, because they are the reason this is a floor and not a
final number: it used a dummy API key rather than a claude.ai login, and the binary
skips warm spares when free memory is under ~1 GB, so a loaded `zero` may already have
been getting a cheaper version of the bad case. Re-measuring on a real login is Phase 0
work still open in [`../plans/claude-sessions.md`](../plans/claude-sessions.md), which is
the design this belongs to — cheap idle sessions are its first half, and finding your
way back to a session after a disconnect is the rest.

## Cloudflare

**Since 2026-10-26 there is one tunnel for every dev container, the hub's**, and its
connector is a sidecar: `dev-cloudflared`, in the `tunnel` profile, the image pinned by
digest exactly as the deployment sidecars pin theirs. Two hostnames: `dev.gsrpi.uk`, the hub's sshd on the
project network, and `or3-dev.gsrpi.uk`, or3-dev's own sshd, kept for the phone's reverse
forward to the vessel (*Moving a container in*; `cloudflared.yml`). No other dev container has
a hostname any more, and the base no longer carries cloudflared at all.

### The order

Both playbooks run from the control node — **there is no ansible on zero and there should
not be.** zero is the box being managed; installing a control plane on it is the wrong
direction, and this container is what zero's control node is *for*.

```sh
cd ~/infra/ansible

# 1. the SERVER side, one run: the EDGE (tunnel `dev`, its DNS record, an Access
#    application with no policy yet) and then the hub's HOST half (~/.dev-secrets with
#    tunnel.json and authorized_keys, HUB_SECRETS and HUB_TUNNEL_ID in dev/.env). Reads the
#    Cloudflare API token from ~/.config/cloudflare/api-token and prints how to mint one if
#    it is missing — ../ansible/README.md § The Cloudflare API token.
ansible-playbook playbooks/server-create-dev-container.yml -e container=dev --check
ansible-playbook playbooks/server-create-dev-container.yml -e container=dev

# 2. start it, with `tunnel` in COMPOSE_PROFILES in dev/.env
ssh -t zero 'cd ~/infra/dev && make up'

# 3. the CLIENT — the machine you ssh FROM. Mints this client's own service token over
#    the API and adds it to the application's policy; nothing is typed. See below.
#    Every block and the fleet in one run; -e container=dev for the hub's alone, which is
#    also the rotation path (-e replace_token=true).
ansible-playbook playbooks/client-home-ssh-config.yml -e container=dev
```

The edge half is the one every dev container's tunnel was always made with, named `dev`;
only the host half is the hub's own (`_dev-hub-host.yml`). `HUB_TUNNEL_ID` is written beside
the credentials it came from in the same run, so the two cannot name different tunnels; the
sidecar needs it on its command line because its image has no shell to read it out of the
file. Under `--check` a tunnel that does not exist yet has no id, and the line is not written
— never a placeholder, which would read as configured.

**Step 3 is per client, and the laptop counts as two of them.** Windows' `ssh.exe` and
WSL's `ssh` read different configs from different homes. Run this play *in WSL* and it
writes both — the Linux block and token, and Windows' block, token and the
`cf-access-<alias>.cmd` wrapper it needs because it has no `sh`. Run it from Termux and
`/mnt/c` is absent, so the Windows half becomes a paste file instead. The details, and
why the Windows token's permissions are printed rather than asserted, are in
[`../ansible/README.md`](../ansible/README.md) § *The laptop is two clients*.

### The service token is minted, not typed

Since 2026-10-04 `client-home-ssh-config.yml` mints this client's own Access service token
over the Cloudflare API — named `<alias>-<client>`, `dev-<client>` for the hub, added to the
application's Access policy, written straight to `~/.config/<alias>/token` at mode 600 —
using the API token at `~/.config/cloudflare/api-token` on the same machine. Nothing is
shown and nothing is pasted. If that file is missing the play prints how to mint one and
stops; [`../ansible/README.md`](../ansible/README.md) § *The Cloudflare API token* is the
same text.

One token per client means a lost laptop is one token to delete in Zero Trust and no other
client notices. Re-running leaves an existing file alone; `-e replace_token=true` rotates
this client's token and rewrites the file. The edge play creates the Access application
with no policy, so a freshly created tunnel admits nobody until a client has run.

**A sidecar, where the per-container tunnels ran inside each container.** Those followed
[`../docs/management-plane.md`](../docs/management-plane.md) § *Addressing*: the tunnel's
identity travelled with the container, so moving one to `one` changed no ingress rule. With
one door for every container that argument applies to the hub instead — the hub, its
sidecar and `cloudflared.yml` move together as one project — and a sidecar is the shape
Phase 3 settled for deployments (`decisions.md`, *Sidecar, not baked-in*). It runs as the
checkout's owner rather than the image's 65532, so the credentials the edge play leaves
gavin-owned at 0600 serve it unchanged.

**A playbook, not a script.** It was written as `dev/cf-provision.sh` first and that was
the same instinct that put `bin/compose` in this repo. Provisioning the way in to a
managed box is management-plane work: in the plane it gets parsed JSON instead of a
hand-rolled extractor, a real `--check`, `no_log` as a mechanism rather than as
discipline, and an API token that could have become a Vault variable at Phase 4 with no rewrite
(it will not: it stays one per machine, `docs/management-plane.md` Phase 4).

### It is additive, and that is load-bearing

`tunnel` out of `COMPOSE_PROFILES` means **no tunnel at all**: the hub and every container
come up anyway, and `make claude` or `make shell` on zero is the way in exactly as if none of
this existed. That is why the sidecar's tunnel id is `${HUB_TUNNEL_ID:-}` and not `:?` — a
required variable stops Compose even with the profile off, so `:?` would hold every
container hostage to a tunnel. With the profile on and no id or no credentials, the
connector refuses at start and says so in `make tunnel-log`; nothing else is affected.

**⚠︎ The loopback publish went on 2026-10-04.** This section used to argue for keeping
it so that `docker exec` — needing sudo — was not the only fallback. Both paths ran
through zero's sshd, so the port was never an independent route, only a passwordless one;
the owner traded that for no port bookkeeping. Cloudflare being down still does not touch
`ssh zero`, and `make shell` is what you run once there.

### Reaching it from Termux — measured, not assumed

Two doubts here are reasonable and only one of them was ever real.

**The client binary is required with or without Access.** An `ssh://` tunnel ingress is
not raw TCP at the edge; only `cloudflared access` speaks it. So the binary is a tunnel
requirement, not an Access one.

**Whether that binary runs on Termux was the real question**, because Termux is bionic
and would refuse a glibc-linked build. Checked on 2026-08-22 by downloading it:

```
cloudflared 2026.8.2, linux-arm64, 37,404,344 B (35.7 MiB)
ELF 64-bit LSB executable, ARM aarch64, statically linked
readelf -l : no INTERP segment      readelf -d : no dynamic section
```

Fully static, no loader needed. (The base pinned the same build until 2026-10-26; the
container side is the sidecar's image now.) **The 35.7 MiB is metered on the phone** and is priced in or3's `docs/data-ledger.md`.

**Access does not add a browser.** `cloudflared access login --help` says, in its own
words, *"The subcommand will launch a browser. For headless systems, a url is
provided."* — so even the human flow degrades correctly. But it never runs here, because
the policy is a service token:

```
--service-token-id value      [$TUNNEL_SERVICE_TOKEN_ID]
--service-token-secret value  [$TUNNEL_SERVICE_TOKEN_SECRET]
```

### Two Cloudflare things called a "token", and they are not related

This cost a round of confusion, so it is worth stating flatly before anything else:

| | Where | What it is | Who holds it |
|---|---|---|---|
| **API token** | My Profile → API Tokens | authorises the *playbook* to call the Cloudflare API | each machine that runs playbooks, at `~/.config/cloudflare/api-token` (0600); one per machine |
| **Access service token** | Zero Trust → Access → Service credentials | a `client_id`/`client_secret` a *machine* presents to get **through** Access | each client, at `~/.config/dev/token`; one per client, named `dev-<client>`, minted by the client play |

They are different objects with different lifetimes and different homes, and naming an
API token "service_token" — which is an entirely reasonable thing to do — makes them look
like the same thing.

**A lost service-token secret is recovered by rotation, never by delete-and-recreate.**
The client play does this itself: `-e replace_token=true` on the client that lost it
rotates that client's own token and rewrites its file, and nobody else's token is touched.
Delete-and-recreate is not an option Cloudflare offers while a policy references the
token (`400`, `service_token_in_use`), and the policy the client play writes *is* that
reference.

**The API token is a file, one per machine.** `~/.config/cloudflare/api-token` on each
machine that runs playbooks, mode 600, outside the repo (a checkout is where a secret gets
committed) and outside every secrets directory here (each is mounted into a container). Rolling or deleting it in
the dashboard breaks nothing already built — the tunnel, the DNS record, the Access
application and the service tokens do not authenticate with it — so rotation is: roll it,
overwrite the file. **It is the one thing that cannot be minted from the command line**,
because Cloudflare's own `POST /user/tokens` needs an existing token to call it; the
instructions the plays print when the file is missing are the whole of the manual surface.

### No identity provider is configured, and none will be

The Access application is created with `allowed_idps: []` and
`auto_redirect_to_identity: false`. Its one policy is `decision: non_identity` naming
the service token. **There is no IdP behind this at all** — no Google, no GitHub, no
account linked to anything. Proton is not an option on Cloudflare (it publishes no
OIDC/SAML for personal accounts) and it does not need to be, because the question never
arises. If a human path is ever wanted, Access's built-in **one-time PIN** emails a code
to any address, a Proton one included, and still configures no IdP.

`decision: non_identity` is not interchangeable with `allow`. `allow` with a
`service_token` include still expects an identity behind the request and sends a
headless client to a login page it cannot complete — which presents as the tunnel being
broken rather than as the wrong policy type.

### Where the three secrets go, and where they must not

| Secret | Lives | Must never be |
|---|---|---|
| Cloudflare **API token** | `~/.config/cloudflare/api-token` on each machine that runs playbooks | in `$HUB_SECRETS` or `$INFRA_SECRETS` |
| Tunnel **credentials file** | `$HUB_SECRETS/tunnel.json`, mode 600, mounted read-only into the sidecar alone | in argv or env |
| Access **service token** | each client's `~/.config/dev/token`, mode 600 | in a container, or in a `ProxyCommand` |

Each of those "must never" is a specific failure, not tidiness:

- **The API token cannot go in a secrets directory** because each is mounted into a
  container. A container able to rewrite the Access policy in front of itself is not
  protected by it. Nothing the running container does needs that token.
- **The tunnel credentials are a file, not `--token`.** ⚠︎ **So are the host tunnels'
  now** — that stopped being a difference on 2026-08-29, when 2g finished and every host
  moved to `--config` with its secret in `/etc/cloudflared/<host>.json` at 0600. The
  reason the container did it first still stands: it is `host-setup.md`'s token-in-argv
  leak and `management-plane.md`'s *secrets never go in `command_args`*. There is no
  `supervise-daemon` in a container, but `docker inspect` shows argv **and** env, and
  `.Config.Env` is exactly what `server-generate-fleet-inventory.yml` refuses to read
  because it holds live secrets. A read-only tunnel credentials file is the spelling that
  is in neither.
- **The service token must not be in the container**, because it authorises *reaching*
  the containers — putting it inside is the same mistake in the other direction. On a
  client it is a file the `ProxyCommand` sources rather than part of it, because a secret on
  a command line is a secret in `ps` output and in shell history.

### Health

`make status` reads a `tunnel` line with three distinguishable answers — no sidecar (the
profile is off), running but not healthy, and serving — because a single up/down collapses
the interesting middle case. It reads Docker's verdict on the sidecar's healthcheck rather
than probing again, and that healthcheck is `cloudflared tunnel ready` against its own
metrics endpoint on `127.0.0.1:20241` — `readyConnections` of at least one, the probe
[`../docs/recovery.md`](../docs/recovery.md) already calibrated: counting sockets on port
7844 and reading the log were both tried on `one` and **both read dead against a tunnel that
was serving normally**. A process check would repeat that mistake here in a new way —
cloudflared is running the whole time it retries a tunnel that will never connect. `make
tunnel-log` (`docker logs dev-cloudflared`) is what it points you at.

## The control-node question, deferred

**By default this container cannot reach `zero`, `one` or `two`.** No fleet key, no
`ssh_config.fleet`, no `known_hosts.fleet`. It develops this repo — edit, commit, push,
syntax-check a playbook — and running playbooks against the fleet stays on the control
node.

That is a step back from where this was heading, taken deliberately. The container was
being built as a second control node, and there is a real objection to it: **it puts the
control plane inside a container on one of the boxes the control plane controls.** Three
things follow from that shape and none of them is imaginary.

- **It cannot fix the thing it lives in.** If zero is wedged, the control node is wedged
  with it, and the box you most want to reach is the one you cannot. The phone has no
  such problem, which is the argument for the phone remaining the real control node.
- **The blast radius is circular.** A key that reaches all three hosts as an account in
  `wheel`, in a container that runs a claude, on the box that runs Immich and the
  Cloudflare tunnel. Compromise the container and you have the fleet, including its own
  host.
- **It is a third control node nobody sized for.** `docs/management-plane.md` names two —
  Termux now, `two` at Phase 8 — and picked `two` on the reasoning that a control node
  should be the box with the least on it. zero is the box with the most.

Against all of that there is one genuinely good argument, which is why this is deferred
and not refused: **an inventory run from Termux is metered end to end to reach boxes that
are on zero's own LAN, and from inside this container it is free.** That is a real,
recurring saving, and Phase 8's answer — scheduling from `two` — was blocked on rootless
podman, which is Phase 7. ⚠︎ Settled 2026-10-25: the owner decided no control node inside the
fleet, which closes this and dropped Phase 8 as well (`docs/management-plane.md`).

So it is left as one variable, off, with the argument written down rather than settled by
whoever next runs the script:

**Nothing in the repo builds it.** The three files the container would need —
`id_ed25519_fleet`, `ssh_config.fleet`, `known_hosts.fleet` — are read by the entrypoint
if present and are written by nothing. That is deliberate: a switch that turns this on is
a switch someone flips without reading the argument. When it is decided, it becomes a
fourth playbook, and two things it will have to solve are already known and easy to miss:

- **`~/.ssh/config` on zero has no `Host zero` block** — nobody writes one for the machine
  they are sitting on. `compose.yaml` already carries the other half of the fix, mapping
  the bare name to `host-gateway` (Docker's own alias for the bridge gateway, which
  survives a renumbering that a hardcoded `172.17.0.1` would not).
- **`~/.ssh/known_hosts` on zero has no entry for zero either**, and `ansible.cfg` sets
  `host_key_checking = True`, which fails rather than prompts. The answer is
  `/etc/ssh/ssh_host_ed25519_key.pub` — more authoritative than a known_hosts line, which
  only records a key somebody once accepted.

Both were found by trying it, not by reading it. Without them the failure is `ansible
cannot reach zero`, which sends you looking at the key rather than at a missing block.

`make status` and `make fleet` say which state it is in, and say nothing is wrong when it
is off.

## What the container can reach, and what that is worth

| | Reaches | Held as |
|---|---|---|
| git | `gsfernandes81/infra`, read-write | deploy key, generated on zero, never transmitted |
| `gh` | your GitHub account, at whatever scope the token has | a login in the `infra-gh` volume |
| the fleet | **nothing, by default** — see above | `id_ed25519_fleet`, opt-in, generated on zero |
| the hub | nothing outward — the hub reaches *in*: its key, `restrict,pty`, runs commands and terminals here | `hub.pub`, written to `~/.ssh/authorized_keys.hub` at every start |

**The fleet key is the one that would be new, and it is a bigger prize than anything
`or3-dev` holds** — which is why it is off by default and why the section above exists.
`or3-dev`'s deploy key touches one repo and its vessel key touches one PC; this would
reach every host in the fleet as an account in `wheel`. If it is ever turned on, three
properties are what would keep it a trade rather than a quiet escalation, and whatever
builds it has to maintain all three:

- **It has to be a separate key from the one you use by hand**, so it is revocable on its
  own: pull three `authorized_keys` lines and the container is locked out while your
  laptop still works.
- **It never leaves zero.** It would be generated there. No copy on the phone, in the
  repo, or in transit, so there is nothing to lose.
- **It cannot escalate unattended.** sudo wants a password on all three hosts and this
  repo refuses NOPASSWD. Read the fleet freely; change it only with someone present.

Nothing is published on the host for the same reason: a shell in here holds all three of
the above, and the ways to one are the hub — behind the tunnel's Access policy — and
`docker exec` on zero. **The hub is therefore as good as a shell in every container**: its
key is authorised in all of them, which is why it lives in the hub's volume alone and the hub
runs no agent and no claude.

## The socket line somebody will add

`- /var/run/docker.sock:/var/run/docker.sock` is missing from `compose.yaml`
deliberately, and it is the single most likely edit somebody makes in a hurry, because
this is the repo that drives docker deployments.

`decisions.md` puts the docker group in the same class as root: anyone holding the
socket can bind-mount `/` into a container. Handing it to a container that also runs a
claude and holds ssh keys to all three hosts is that same grant with two more ways to
reach it — and it would be handed to the box that runs Immich and the Cloudflare
tunnel, not to a spare one.

**Nothing needs it.** Ansible drives docker on `zero` the same way it drives docker on
`one`: over ssh, as a host in the inventory. `community.docker`'s `docker_compose_v2`
invokes the Compose CLI plugin on the target and needs neither a local socket nor the
Python SDK, which is what made retiring `bin/compose` at Phase 3 cheap. If something
one day genuinely needs the socket, the answer is a rootless podman socket under a
dedicated account, not this line.

## Sharing or3-dev's layers

**This section described a discipline that no longer exists, and that is the point.**
Until 2026-08-24 every expensive layer in this `Dockerfile` was byte-identical to
`or3/dev/Dockerfile` by hand: add a package to one list and not the other and *both*
images paid full price for every build from that line down, silently — nothing failed,
it just got slow, and the reason was two directories away.

Both files are now thin children of `Dockerfile.base`, so the layers below the `FROM`
are the same layers, not two builds that happen to agree. Layer sharing stopped being a
convention nobody could check and became the pull.

## Four copies of this, and what to do about it

`zero` now runs four of these: `dd-dev`, `ds-dev`, `or3-dev` and this. They differ in
about six values — repo, container name, port, volume prefix, secrets directory,
whatever extra tooling that repo needs — and agree on some 700 lines of Dockerfile,
entrypoint, Makefile and sshd config. **This one was written to be the last copy, not
to be a fourth pattern**: everything or3-specific in `or3/dev` is already a variable
here, and the two files that carry host-specific values (`ssh_config.fleet`,
`known_hosts.fleet`) are read from the secrets mount rather than baked.

**Built on 2026-08-24, on the infra side**: `Dockerfile.base` is the shared ~700 lines,
built by CI to `ghcr.io/gsfernandes81/gsrpi-dev-base:<BASE_TAG>` (public; tag set in
the Makefile, single source; `.github/workflows/dev-base.yml`, which since 2026-09-21
runs itself on any push to `main` touching `dev/` rather than waiting to be
dispatched), and
this repo's `Dockerfile` is now a thin child — `FROM` the ghcr name plus the ansible
layer. There is no build order: the FROM pulls. `make base` builds the identical image
(Crush aside: it takes that day's release, or none — *Crush, on trial*)
locally under the same name as the offline fallback — docker prefers local over pull,
so a GitHub outage means building on the host, children none the wiser. **All four are
converted as of 2026-08-24**; each conversion was, in that repo:

1. delete everything shared from its dev Dockerfile, leaving
   `ARG BASE_TAG=<tag>` + `FROM gsrpi-dev-base:${BASE_TAG}` + its own extras
   (or3: uv and its ssh identity; dd: railway, the database clients and its venv;
   ds: its venv);
2. drop `USER_UID`/`USER_GID` from its compose build args — the dev user is built in
   the base, same guard one layer down;
3. nothing else — the FROM pulls from ghcr, so no other repo needs infra present.

**or3-dev converted on 2026-08-24**, and it is the conversion that proves the shape:
it is the child that differs most, and none of its differences needed a fork. What it
needed instead became the base's seams (four then, five now — `child-init.sh` was added for dd-dev and ds-dev) —

| or3-dev needs | It gets it from |
|---|---|
| its secrets at `/run/or3-secrets`, holding `id_ed25519_or3ecr_m` and `id_ed25519_or3_deploy` | `DEV_SECRETS_DIR`, and the entrypoint copying **every** `id_*` rather than a list of names |
| or3ecr's host key pinned in tracked content | `/home/dev/known_hosts.extra`, baked by the child |
| `AllowTcpForwarding yes` — the phone's reverse forward is its reason to exist | `/home/dev/sshd_config.d/10-forwarding.conf`, and the `Include` at the *top* of `sshd_config` so a child's value wins |
| ~~the Claude Remote Control supervisor~~ | It had a seam of its own — a hook the base fired when a child baked an `rc-supervisor.sh` — and **both are gone as of 2026-08-25**, along with or3-dev's daemon. No dev container on this fleet runs remote control; the row stays because the seam it justified is the one worth understanding: a hook in the base, the daemon in the child that owns the policy |
| `uv`, pinned to the version or3ecr runs | its own layer, above `USER dev`. Deliberately **not** in the base: that pin is a contract with `work/bootstrap/requirements-or3ecr.txt`, so it belongs to the repo holding the other half |

That last row is the general rule: a thing goes in the base when the containers agree
about it, and stays in a child when it is that repo's business. `ANSIBLE_CONFIG` moved
the other way for the same reason on the same day — it names a path inside `/workspace`,
which is a different repo in every container, so it now lives in this repo's child.

Children pin a tag, never `latest`, so a base rebuild cannot change a container behind
its repo's back. **Bumping the base is: edit `BASE_TAG` in infra's Makefile, push to
`main`, and the workflow publishes that tag on its own** — then move each child's pin
when that repo is ready. `make base` is still there for the two cases it was always for:
no network, and not wanting to wait for CI at all.

**That wait is about five minutes, not the 20-40 the workflow and three other files used
to claim.** Nobody had checked: the three runs that have built this image took 4m16s,
4m42s and 4m07s end to end, arm64-under-QEMU leg included — the last of them the first
automatic one, on 2026-09-21. The number mattered because it was the argument for
reaching for `make base`, and at five minutes that argument is much weaker. Measured
from the run timestamps, which is the artefact; the sentence in the docs was the guess.

**What a Pi pulls on a bump is only the layers that changed, since `2026.10.06.3`.**
Before that, CI built every tag from scratch, so every layer got a new digest. The
`.06.1` → `.06.2` bump changed one `ARG` (claude-sessions), and zero still downloaded
264 MiB of a 306 MiB image, then decompressed it alongside Immich. That is the
`make up` that took minutes and dropped the ssh session. `dev-base.yml` now keeps a
registry build cache (the `buildcache` tag in the same package) and pushes zstd layers.
`Dockerfile.base` pins its python base by digest so the cache cannot be pulled out from
under it. A bump that moves only something near the bottom of the file
(claude-sessions, zmx, the copied scripts) should ship a few MiB, and the child's
ansible layers still build on the Pi as before — **plus ~25 MB when Crush has released
since the last tag**, because its layer is keyed on the version CI resolves and sits above
those (*Crush, on trial*). Two things follow:

- **Moving the python digest is the refresh.** Nothing re-runs Debian's `apt-get` or
  reinstalls Claude Code otherwise, so Debian security updates arrive only when that line
  moves. The Crush layer re-runs on its own release and refreshes nothing but Crush.
  The comment above `FROM` in `Dockerfile.base` says how to read the current digest. It
  costs one full pull on every host, which is the price of fresh packages.
- **To check that a bump really was small**, watch the pull in `make up`: shared layers
  print `Already exists`, and only the moved ones download. A Crush layer and the few
  below it downloading is a Crush release — the run's summary names the version. If the
  whole image downloads on a bump that did not move the python digest, the cache missed. That is worth a look
  before it becomes normal again.

zstd needs Docker 23 or newer on whatever pulls the image.

**The tag is whatever `dev/Makefile`'s `BASE_TAG` line says — `2026.10.01` as this is
written — and naming it a second time here is how it goes stale, which it had: this
sentence said `2026.09.21.1` for two bumps.** Read the Makefile, not this. The genealogy,
because the suffixes are not self-explaining: `2026.10.01` turned the agent view off,
`2026.09.21.2` put the abduco compile stage back when trixie turned out not to package it,
`2026.09.21.1` was trixie itself, `2026.09.21` the bookworm image with the self-updating
Claude, `2026.08.25` its predecessor, `.24.2` the dd/ds conversion and `2026.08.24.1` the
or3 one
— suffixes rather than new dates, because each earlier tag is already pushed and a
pinned tag is a contract that the same tag is the same bytes. `dev-base.yml` refuses to
overwrite one without `force`, which is the check working — and since it runs on every
push it now also refuses the other way round: **a push that changes a file the image is
built from without bumping `BASE_TAG` fails the run**, because the thing a person
forgets is not the dispatch, it is the bump. Which files those are is derived from the
`COPY` lines in `Dockerfile.base`, so adding one needs no edit in the workflow.

**A comment in `Dockerfile.base` does not count, and a comment in `entrypoint.sh` does.**
That is not an oversight. The first version of this compared file names, and failed a
push whose only change to the Dockerfile was a paragraph of prose — in a file that is
three-quarters prose, that is a red `main` nobody will keep reading. A Dockerfile comment
provably cannot reach the built image, so comments are stripped before comparing (parser
directives like `# syntax=` kept, and the stripping refused outright if the file ever
grows a heredoc). In a shell script `#` cannot be told from content without parsing the
shell — `entrypoint.sh` has two heredocs — so those compare byte for byte. Strip where it
is provable; refuse where it would be a guess. A change to the base is now a
change to four containers, so the question before editing `Dockerfile.base` is which of
the five seams the change belongs in — a setting that is true for one child is a child's
setting, however tempting it is to put it where it will be inherited.

**The fifth seam is `child-init.sh`**, and dd/ds are why it exists. The other four all
place a file; those two needed something *done* — `uv sync --frozen` against the
lockfile in the bind mount, which cannot happen at build time because `/workspace` is
not mounted then, and must happen before anything can arrive. So the entrypoint runs
`/home/dev/child-init.sh` if the image bakes one: after the pull, so a lockfile that
just moved is the one it installs from, and before the supervisor and sshd, so no
session meets a half-installed venv. Non-fatal, like the pull — a container you can ssh
into and fix beats one that refused to start over its own dependencies — and *bounded*,
because non-fatal only covers the half of that which exits. It runs ahead of the door,
so a `uv sync` blocked on a lock in the mount or retrying at a dead network costs the
door as completely as a crash would. `timeout -k 10 600`, and the kill lands in the
same warning branch as a failure; `DEV_CHILD_INIT_TIMEOUT` moves it.

The shape as originally designed, kept for the reasoning:

- **`infra` owns a base image.** One `Dockerfile` here, built on the host as
  `gsrpi-dev-base:<tag>` — Debian slim, Node, Claude Code, gh, zmx, screen, sshd,
  fish, the `dev` user, the ENV block. That is the 700 shared lines, in one place.
- **Each repo's `dev/Dockerfile` becomes three lines**: `FROM gsrpi-dev-base:<tag>`
  plus whatever that repo needs on top — nothing for or3, `ansible-core` and the
  collections for this one.
- **The entrypoint, sshd config and Makefile ship in the base image** and are
  parameterised by environment, which is most of the way to how they already work.
- **`compose.yaml` and `.env` stay per-repo.** They are the six values that genuinely
  differ, and they are already the only place those values live. ⚠︎ **Reversed
  2026-10-25, built 2026-10-26:** every dev container is a service in this directory's one
  `compose.yaml`, with one `.env` (*The hub*, above, and `docs/decisions.md`).

Three things make it worth doing rather than tidy-minded. The layer-sharing above
becomes guaranteed instead of a convention nobody can check. A fix to the entrypoint —
which has already been made three times — gets made once.

And the third is the one with a clock on it: **cloudflared is hash-pinned in four
Dockerfiles.** Bumping it means a version and two SHA256s, four times, and Cloudflare
deprecates old client versions — the edge eventually refuses them, and it presents as a
broken tunnel rather than as "your client is old". So there is a slow deadline on four
separate files and no single place to wind it. ⚠︎ Since 2026-10-26 there is one connector for
every dev container, the hub's sidecar, pinned by digest in `compose.yaml`; the base carries
none.

That is also the answer to "is the pin too conservative". It is not: a container's update
path is a rebuild, and a hash is what makes the rebuild reproducible — the argument in
`dev/Dockerfile` holds, and applies more strongly to the hosts, which is why they stopped
autoupdating on 2026-08-23. What is too conservative is having *four copies of the pin*.
Under a base image it is one `ARG` in one place, and the friction that stops anyone
bumping it disappears. Two things make it work to
schedule rather than now: there is no registry on this fleet, so "the base image" means
a build-order dependency between repos that has to be made obvious rather than
discovered, and it is a change to the thing you are working *inside*, which is the
category this repo's `CLAUDE.md` is most careful about.

**dd-dev and ds-dev converted on 2026-08-24**, in their own repos, and between them they
used every seam: `child-init.sh` for the venv sync, `DEV_SECRETS_DIR` pointed at the
gitignored `.dev-ssh/` inside their own bind mount, their own `ssh_config`, and two
`sshd_config.d` drop-ins —
`10-authorized-keys.conf`, naming the host account's `authorized_keys` (how both were
reached before the base existed, and not a thing to re-key), and `20-forwarding.conf`,
which puts `AllowTcpForwarding` back to the default their old config left in place.
Neither repo needs this one checked out: the `FROM` pulls.

**Their identities arrive through `ssh_config.fleet`, and that is not a coincidence of
naming.** Both used to symlink `~/.ssh/config` at a host-side file, which under this base
is destructive — the entrypoint assembles that path with a redirection at every start, a
redirection follows a symlink, and `~/.ssh` is not a volume, so the second boot of a
container would have truncated the host's own config. The entrypoint now `rm -f`s the
path before writing it, and both children renamed their file to the one thing the base
prepends. It buys them the ordering as well: identities in force *before* the start-up
pull, which nothing a child runs can be, because `child-init.sh` runs after it.

Two start-up warnings were fixed in the same change rather than inherited by two more
containers. The fleet sentence — *zero, one and two are unreachable* — now prints only
for a container that did **not** name its own `DEV_SECRETS_DIR`, because it means
nothing in the other three; and *NOTHING can ssh in* is not said when a drop-in names
its own `AuthorizedKeysFile`, which is the case where it would be false and believed.

## The idle-claude offloader

A held session is why a session survives a dropped link. It is also why a conversation
nobody has touched since Tuesday is still holding memory: **one idle session's process tree
measured 1,146 MB RSS on this container** — 208 MB for the session, 145 MB for its
transient daemon, and 819 MB across four `bg-pty-host`/`bg-spare` helpers. Four dev
containers on a 4 GB Pi that also runs Immich cannot each hold a gigabyte for a
conversation that ended.

**Since 2026-10-26 the hub runs it, for every container** — `claude-sessions offload-all`
every three minutes, which runs `claude-sessions offload` in each one over ssh (*The hub*,
above). **From base `2026.10.06` until then each entrypoint ran its own `claude-sessions
offload` every three minutes, live** — Stage B of [`../plans/claude-sessions.md`](../plans/claude-sessions.md),
in force on each container from its recreate onto that base. It stops a slot that is
detached and idle — since v0.4.7 (base `2026.10.08`) *measured* quiet by the kernel, with
a keep-alive for quiet waits — and leaves the conversation resumable from the menu;
nothing with a conversation is closed, and the memory is what is reclaimed. The rules are
in [claude-sessions](#claude-sessions) below. It was armed on claude-sessions v0.4.1, which
fixed [#9](https://github.com/gsfernandes81/claude-sessions/issues/9): a slot running
background subagents, forks, Workflow or Monitor fires no hook while they work, and used
to read as idle ten minutes after its parent's `Stop`.

**It replaced `offload-idle-claude.sh`**, which stopped a claude after 90 minutes of
transcript silence — an hour's worth of a claude's longest self-scheduled wake-up plus
margin — and refused attached sessions, sessions with work under them, and sessions with
no transcript. Two things retired it. The new hooks *saw* a pending `ScheduleWakeup` or
`CronCreate`, so the 90-minute floor's reason was gone (and since v0.4.7 nothing reads
timers at all: a quiet wait asks for a keep-alive). And it timed every session by the
**newest** transcript in the shared workspace directory, so one active slot kept every
other slot alive: on or3-dev it stopped nothing in 2.7 days while a slot sat idle for
about 16 hours (infra#9). It could also see only abduco sessions, and a slot is a zmx
session since claude-sessions v0.4.0. It and abduco were deleted in the same base.

## claude-sessions

[`gsfernandes81/claude-sessions`](https://github.com/gsfernandes81/claude-sessions) is the
session registry [`../plans/claude-sessions.md`](../plans/claude-sessions.md) designs: one
JSON file per slot under `~/.local/share/claude-sessions/` (on the volume, so it
outlives the container), kept current by Claude Code's own hooks — and, since v0.3.5, an
`archive/` beside them: one small file per conversation `c` has put away (`archived <ms>`)
or taken back out (`kept <ms>`) — age-archiving writes nothing, being worked out as the
list is read. Since 2026-10-26
the **hub** pins it — **v0.5.0**, not yet released as this is written — a static binary, by
tag and SHA-256 per architecture, and installs it into the volume every container runs it
from, `/opt/claude-sessions/bin/claude-sessions` (*The hub*, above). Until then each base
installed its own at `/usr/local/bin`, v0.4.7 the last.

**The menu is the hub's since v0.5.0, and it is where `ssh dev` lands** — containers first,
then Loaded, Offloaded and a folded Archived inside each (*The menu, two levels deep*,
above). Each container's rows still come from that container: the hub runs `claude-sessions
agent` there over ssh for its rows and actions, and `agent exec` for the one child an action
needs at your terminal, so every lock and every launch is decided inside the container as
before. What follows is the single-container menu's history, which 0.5.0 keeps inside each
container except for the grouping: the state groups it names (`Needs you`, `Working`,
`Idle`, `Offloaded`, `Closed`) became Loaded, Offloaded and Archived, with a waiting session
an amber `!` on its row.

**Until v0.5.0** `claude-sessions`
with no arguments, at a terminal, lists the live and offloaded slots, any zmx session it
did not start, and under
`Closed` every workspace conversation on disk —
**grouped by state** under `Needs you`, `Working`, `Idle`, `Offloaded` and `Closed` (an
Esc-interrupted row is `Idle` since v0.4.2; v0.3.3;
an empty group is not drawn, and an unregistered session counts as idle). There are no marks
and no numbers: an unread title is bold, a session attached elsewhere is dim, amber is the
Needs-you heading, and status lines name a session by its quoted title. `Enter` attaches or resumes, `n` starts a new slot in `/workspace`, `c` closes, `s`
is a shell, `?` the keys, `q` quits. Piped, it prints `list`. Since v0.3.0 the menu fills
the terminal, with its closing rule, status line and hints on the bottom lines. **The
`Closed` group is every conversation in Claude Code's own transcript store**
(`$CLAUDE_CONFIG_DIR/projects/*/<id>.jsonl`, v0.3.4) that started in `/workspace` or below it
and is not running — whoever started it: a slot, a `claude` run by hand, the old `abduco -A
claude claude` path, or what a slot held before a `/clear`. A slot's *current* conversation
is not repeated there, a transcript with no reply and no typed prompt (a bare `/clear`) is
not a conversation, and piped `list` still leaves the group out. `Enter` on one runs `claude
--resume <id>` in a new zmx slot from the directory Claude Code filed it under — refused, with `which is
gone`, when that directory no longer exists, as for a deleted worktree (or through the slot
whose record names it). Closed slot records are no longer a list source, so a new slot may
reuse a closed one's name. **Since v0.3.5** each group's heading is a labelled rule with a
count (`── Closed · 7 ────`), rows are indented under it from 60 columns, and there is an
**`Archived` group**, last and shut at every start, that `Enter` on its heading folds open:
`c` on a `Closed` row archives it without asking, and 30 days since a conversation's last
entry archives it on its own; `c` or `Enter` on an archived row takes it out again for 30
days. **The archive is the menu's only** — it writes `archive/<id>` in the registry and never
touches Claude Code's files, so `claude --resume` still finds everything. **Since v0.3.6**
anything slower than a quarter second shows Docker Compose's braille spinner on the row being
worked on and says what on the status line (`closing session`, `resuming session`, …), keys
other than `q`, Ctrl-C and a resize are ignored meanwhile, and only changed lines are written, so an
idle menu still sends nothing. **Since v0.3.7** the menu exits **129** and writes nothing
when its terminal goes away (a dropped ssh link), where v0.3.6 and earlier panicked and
dumped core into their working directory — `/workspace`, the repo
([claude-sessions#6](https://github.com/gsfernandes81/claude-sessions/issues/6)); a closed
output pipe no longer aborts any subcommand, and a real bug unwinds and exits 101 with no
core. The door's fallback after a 129 prints to, and starts a shell on, a terminal that is
gone; both fail quietly, which is why the door is unchanged — and in practice the door has
usually been hung up along with the menu before its fallback runs. **Since v0.3.8 every
claude the menu starts or resumes scrolls in the terminal's own buffer**
([claude-sessions#8](https://github.com/gsfernandes81/claude-sessions/issues/8)): it is
started with `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`, `CLAUDE_CODE_DISABLE_MOUSE` and
`CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL` set to `1` unless the login already set them (to any
value — and Claude Code tests them for truthiness, so `=0` disables too; only an empty `NAME=`
turns a feature back on, the same trap the agent-view variable has), so a swipe
on the phone scrolls Termux locally instead of a round trip, and long-press selects. The
owner's accepted costs: more flicker after a resize, history after a dropped link only in a
terminal that stayed open (Ctrl+E redraws), no focus view or diff panel, no mouse. **Only
slots get them** — a `claude` typed into a shell runs with Claude Code's defaults. The names
come from inside Claude Code's binary, which updates itself here, so **`make verify`'s
`scrollvars` line counts them in the binary the container is running**: fewer than three is a
rename, and an issue for claude-sessions. **A row's title is what Claude Code's own
`/resume` picker shows** (v0.3.1): the `/rename` name, else Claude Code's generated title,
else the first prompt — read from the transcript by the hook at `SessionStart` and `Stop`.
A recreate ends every slot anyway, and each one takes its new title when it is resumed. **The
door was `claude-sessions-door`** from 2026-10-04 until 2026-10-26 — sshd's `ForceCommand`
here and `make claude`: the menu at a terminal, a login shell with no terminal or when the
menu exited non-zero, a forwarded command run as given in `~`. Its menu half is the hub's
`hub-door` now, and what is left in here is `dev-door` (*How this container is used*).

| Piece | Where | What it does |
|---|---|---|
| the hooks | `/etc/claude-code/managed-settings.d/claude-sessions.json` — the hub volume's `managed-settings.d`, mounted read-only | `SessionStart`, `UserPromptSubmit`, `Stop`, `Notification` and `SessionEnd` — five since v0.4.7, which feed the **menu only** (titles, who is busy); no offload rule reads them, so `PostToolUse`, `SubagentStart` and `SubagentStop` went. Each calls `claude-sessions hook`, which always exits 0 and prints nothing. Every event but `SessionStart` (30 s timeout) and `SessionEnd` (1 s) runs **async** (v0.4.6) — Claude Code neither waits for it nor kills it, so no hook of ours can hold a prompt — because a millisecond hook stalled past its 5 s timeout on a loaded box (or3's); late events are applied in the order Claude Code forked them. Exit 0 and silence still matter for the two synchronous hooks: a `SessionStart` failure is shown to you, and its output would reach claude as context |
| the keep-alive skill | `~/.claude/skills/keepalive/SKILL.md`, copied by the entrypoint at every start from the hub's `/opt/claude-sessions/skills/keepalive/` — only while `CLAUDE_SESSIONS_OFFLOAD=1`, and removed otherwise | when to run `claude-sessions keepalive`, and for how short. On the config volume, so the image cannot carry it; a failed copy says so in the boot log and removes any old one, which would name a command that might not exist |
| the status line | the same file's `statusLine` (v0.4.5) | `claude-sessions statusline` every minute: the container's RAM and load, yellow then red as they rise, and its name. Managed settings, so it outranks a user `statusLine` — Claude Code's `/statusline` command writes one that never shows here; `make verify`'s `hooks` line names it |
| `reconcile` | the entrypoint, before sshd | marks slots whose process died with the last container; since v0.4.0 it sweeps no sockets — `zmx list` clears a dead daemon's own, and zmx's socket directory, `/tmp/zmx-<uid>`, empties with a recreate (a `make restart` keeps /tmp; a stale socket there is cleared by the next `zmx list`) |
| `offload` | run in here by the hub's `offload-all`, every 3 minutes (the entrypoint's own loop until 2026-10-26) | stops a detached slot measured quiet for 10 minutes (v0.4.7, *The rules* below) and runs the orphan sweep — live from base `2026.10.06` (a dry run before it, as Stage A). Each pass's verdicts, and any failed pass with its exit code, go timestamped to the hub's `~/.hub/passes.log`, every container's lines prefixed with its name (capped near 16 MB, trimmed to the newest 8 MB; the per-container `~/.local/share/claude-sessions-passes.log` before it stays on the volume); stops and sweep lines also go to this container's `offload.log`. Each pass prints, per slot, its measured line — bytes (TCP included), CPU, its line and how long it has been quiet — which since v0.4.7 is the offloader's own reason, and only on stdout: this log is the record to read when a slot was stopped that should not have been. `make idle` is `offload-all --dry-run` in the hub: verdicts for every container, nothing stopped — though since v0.4.5 it writes the activity state as a live pass does, so a hand pass just before the loop's leaves the loop a window too short to count, and the next one counts it |

**The hooks file is written by the binary and is not in this repo** — by the hub's
`claude-sessions install` at every hub start, into the volume (before 2026-10-26, by the base
at build time). `claude-sessions hooks-config` prints exactly the events its code handles, so the hooks
installed and the hooks understood cannot drift apart. It is a managed-settings *drop-in*:
a user's `disableAllHooks` cannot turn it off, no repo's `.claude/` has to know about it,
and the agent-view file beside it stays its own. **Never also deliver these hooks from the
claude.ai admin console** — server-managed settings put hooks behind an approval dialog and
replace this file outright. That a root-written file raises no dialog is from the vendor's
docs, not yet from a box: the first `claude` in a rebuilt container is the check.

**The rules (v0.4.7, owner, 2026-10-08): measured, not read from Claude Code.**
`claude-sessions offload` stops a slot when it is **detached** at the pass, **not under a
keep-alive**, and **measured quiet for 10 minutes** — no 3-minute window over its byte
budget (a minute's worth at its learned line) or over 3000 ms of CPU — judged only on
readings the pass took itself, of the slot's current claude. Nothing that reads Claude Code
holds a slot any more: not a pending timer, not background agents or shells, not the
idle-since-`Stop` clock, not a permission prompt — **a slot waiting on you is offloaded
too**. Busy work holds a slot by being busy; work that waits quietly (a `sleep` before a
check, CI, a `ScheduleWakeup`, a server waiting for a request) is held by
**`claude-sessions keepalive <duration>`** — required, at most 12h, `0` ends it, belonging to
the process that asked — and the keep-alive skill the entrypoint installs at every start
(`~/.claude/skills/keepalive/SKILL.md`) tells claude when and for how short. Quiet time
still counts during a keep-alive, so a slot still quiet when it ends goes at the next pass.
**The 3-minute cadence is load-bearing**: the CPU budget per window is fixed, so a slower
timer would read an idle claude's own CPU as activity. What a busy-but-not-working slot
looks like is in [claude-sessions#14](https://github.com/gsfernandes81/claude-sessions/issues/14):
a background poller every few minutes reads as activity and keeps the slot — the safe
way. Claude Code's 30-minute reinstall after an update does **not**: one busy window every
half hour leaves the rest quiet, so the slot is still offloaded once detached — and that
offload is what ends the reinstall loop (the base's node block).

Unchanged from before: **a slot with no conversation** — nothing typed or replied in its
transcript, a new slot left before its first prompt or a `/clear`ed one — **is closed
instead** (v0.3.3), logged `closed … no conversation on disk to resume`. Only a claude whose
parent is a zmx session is judged at all: one started in the menu's `s` shell, by a
forwarded command or in `screen` is never registered and never offloaded. **The ten minutes
do not start at the detach:** read a long reply for longer than that, lock the phone, and
the slot goes at the next pass. Keep a slot you care about attached, or ask for time;
`Enter` on its row brings it back if it went. Attached means zmx reports a client
(`clients=` in `zmx list`); a zmx daemon that does not answer keeps its slot, because
attached cannot be ruled out.

Reading it:

```
make idle          the offloader's verdict on every slot in every container, now — a dry run, nothing stopped
make offload-log   what it stopped or swept in one container, and the hub's failed passes and last pass
make sessions      claude-sessions doctor — per slot, how long since each hook event
make status        includes `offloader : the hub's, last pass Nm ago`, or why not
make verify        the binary's version, the hooks file parsed as dev, and the keep-alive skill as installed
```

Stage A's `~/.local/share/claude-sessions-dry-run.log` and the old script's
`~/.local/share/claude-offload.log` stay on the volume — the evidence Stage B was read
against; nothing deletes them, so remove them by hand once read.
`~/.local/share/claude-sessions/hook.log` is the hook's own failures. Since v0.3.2 a lock
failure names its event and, for a `SessionEnd`, its reason — `claude-1: SessionEnd (logout)
dropped, lock: … busy for 400ms` — so `grep dropped` answers which events were lost. A
`SessionEnd` dropped while an offload or a menu close held the slot is **expected**, and
since v0.4.6 so is one dropped behind an async hook stalled on the box's load while holding
the lock: `SessionEnd` waits only 400 ms, so the record stays live with a dead process, the
menu shows it offloaded, and `reconcile` settles it. Any other event waits 15 s for the lock
(a `SessionStart` that cannot bind, 2 s), so any other drop means that wait ran out — a
fault worth an issue on claude-sessions. Since v0.4.7 the hooks feed the menu only, so a
dropped event costs a wrong title or busy mark there, not an offload. A `SessionEnd (clear)` or `(resume)`
cannot appear at all: those ends change nothing, so v0.3.2 takes no lock for them — they
used to race their own `SessionStart` for it, which is what infra-dev's eight `busy for
400ms` lines on v0.2.0 most likely were. `offload.log` beside it gets every real stop and every line
of the orphan sweep (stray `daemon run --origin transient` trees whose parent is no longer
a `claude`). **The sweep is live with the offloader**: it logs `sweep: killed …`, or
`sweep: kept, too young (Ns)` for a daemon under ten minutes old — the daemon's own age, so
an old one goes on the first pass after its claude exits. A dry run (`make idle`) logs
`sweep: WOULD KILL …` and `would keep, too young` with the same check. **The sweep is only safe with the agent view off** ([above](#the-agent-view-is-off-and-cannot-be-turned-back-on-in-here)):
agent view's supervisor outlives its session by design, and this rule would kill it.
**"events: none seen"** in `make sessions` means the hooks are not firing. Each pass's
`memory:` line is the container's free memory by **working set** since v0.4.3 —
`memory.max` minus `memory.current` plus `inactive_file`, with the reclaimable page cache
named, `578 MB free … (99 MB of it reclaimable page cache)` — and the menu's room check uses
the same figure, so a burst of file I/O no longer reads as a session's worth of RAM
(claude-sessions#7).

**Resuming an offloaded or closed session is `Enter` on its row in the menu.** Without the
menu: `claude-sessions doctor` prints each slot's session id, then `claude --resume <id>`
in its directory.

`DEV_IDLE_OFFLOAD=0` in `dev/.env` and a `make up` turn off offloading in infra-dev
(compose passes it on as `CLAUDE_SESSIONS_OFFLOAD=0`, and that container's pass then looks at
nothing); `HUB_OFFLOAD=0` turns off the hub's timer for every container. Overrides, neither normally worth setting: `CLAUDE_SESSIONS_DIR` (the
registry) and zmx's own `ZMX_DIR` (its sockets, and its logs — `$ZMX_DIR/logs` instead of
`~/.local/state/zmx/logs`) — each must be
the same for every login and the hub's offload pass, so set one in compose or not at all. Never
set `ZMX_SESSION_PREFIX`: claude-sessions strips it, and slot names would disagree. Do not put a source checkout
at `~/.local/share/claude-sessions` — that is the registry; dev containers check the source
out at `~/.local/share/src/claude-sessions`.

## Secrets

None are in git. `.env` and `.env.*` are gitignored; everything else lives in mode-700
directories on zero, each mounted read-only. infra-dev's is `INFRA_SECRETS`, default
`~/.infra-dev-secrets`, at `/run/infra-secrets`:

| File | What it is |
|---|---|
| `authorized_keys` | public keys allowed to ssh **into** the container. Nothing outside the project network reaches its sshd now, so in practice the one key that logs in is the hub's, which the entrypoint writes to `~/.ssh/authorized_keys.hub` at every start — its own file, so refreshing this one cannot drop it |
| `id_ed25519_infra_deploy` | GitHub deploy key for this repo, read-write, generated on zero |
| `id_ed25519_fleet` | **not built** — would reach all three as `gavin`; see the deferred question above |
| `ssh_config.fleet` | **not built** — the three `Host` blocks |
| `known_hosts.fleet` | **not built** — their host keys |
| `tunnel.json` | infra-dev's own pre-hub tunnel's credentials, which the plain run's edge half still writes — unused here: the container sees it in this mount and runs no connector |

The hub's is `HUB_SECRETS`, default `~/.dev-secrets`, at `/run/hub-secrets` in the hub —
`authorized_keys`, the clients allowed to `ssh dev` — and its `tunnel.json` is mounted into
the sidecar alone. Both are written by `server-create-dev-container.yml -e container=dev`.
**The hub's own private key is in neither**: it is made in, and never leaves, the
`hub-state` volume, which `make down-volumes` drops — the containers then authorise the new
one at their next start. A repo's own `.env` files are in its env volume (*The workspace and
the env volume*).

**Two credentials live on volumes, not here**, and `make down-volumes` takes both: the
Claude login (`infra-claude`) and **Crush's provider API key**, typed at its first start
and kept in `~/.local/share/crush/` on `infra-local-share`.

**There is no `credentials.json`, not even behind a flag.** or3-dev keeps one as a
documented bad idea: copying the phone's Claude login in does not work — claude
contacted the auth server one second after starting and wrote the file back with
zero-length tokens, and the phone's own login had by then been through a refresh it did
not initiate. An OAuth login is bound to the device that performed it. Repeating a
documented bad idea in a second container is how it stops reading as one, so the only
path here is `make login`, once, persisted in the `infra-claude` volume.

**Everything here is written by a playbook run from the phone, and nothing crosses the
radio that matters.** The deploy key is generated on zero by `ssh-keygen` over ssh, so
the private half never leaves that disk. `authorized_keys` gets the control node's *own*
public key, which is not a secret. `tunnel.json` is assembled on zero from a secret
generated during the API call. The one genuinely metered thing in the whole arrangement
is the 35.7 MiB `cloudflared` download on the phone, and it is priced in or3's ledger.

This is where or3-dev differs and the difference is structural: its `seed-secrets.sh`
*has* to run on the phone, because the or3ecr key and the Claude credentials live there.
Nothing infra-dev needs originates on the phone except one public key.

## The three things that are load-bearing

**`sshd` is the foreground process, so the container's lifetime is the door's.**
Nothing you type can end the container — `exit` closes an ssh session, `/exit` closes a
claude, and PID 1 has not moved.

**A session that is not held dies with the link that carried it.** On a phone that is
not a corner case: the ssh session ends at the lock screen, and an unwrapped claude ends
with it, mid-edit. The menu is the habit — every session it opens is a zmx session, and
`make claude` and `ssh dev` both land on the hub's menu, so they list the same sessions
whichever way you came in. `screen` is also in the image and is better for ordinary shell
work. abduco left the image on 2026-10-06, with the old offloader that was its last user.

**`/workspace` is the container's own clone, in a volume, not the host's checkout**
(since 2026-10-26; it was a bind mount of `~gavin/infra` before, one working tree shared
with the box, which is how zero's checkout came to diverge on 2026-10-25). The entrypoint
clones it once and pulls `--ff-only` on every start after, best-effort: a container that
will not come up because the network is down, or because the tree has local work, is worse
than one running a slightly old checkout. Work leaves by `git push`, and nothing in here
can change what the box runs.

## The targets

```sh
cd ~/infra/dev
make              # the header of the Makefile: every target, one line each
make up           # build + (re)create everything the profiles name — drops the sessions of
                  # every container it recreates; S=<service> for one (and the hub)
make restart      # stop + start one container; does NOT re-read compose.yaml
make stop         # stop one container; its sessions end, its volumes stay
make status       # one screen: container, sshd, sessions, logins, the hub, the tunnel, ansible
make verify       # status + the tools + the collections + the fleet
make login        # the logins, again, and the workspace clone if it is missing
make fleet        # ssh to each host, then `ansible fleet -m ping`
make collections  # the image's collections vs ansible/requirements.yml
make claude       # the hub's menu, as `ssh dev` lands on it
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

`C=<container>` picks the container for the targets that take one — infra-dev unless said,
`C=hub` for the hub (`dev-hub`), `C=or3-dev` and so on for the others once they are in.

They work with or without `sudo` — the Makefile adds one when it is not already root —
and the same set is available from the repo root as `make dev-up`, `make dev-login` and
so on. `make dev` at either level is the bring-up above.

The uid the container's `dev` user is built at comes from the **owner of the
checkout**, read with `stat`, not from `id -u`: under `sudo` that is 0, and a dev user
at uid 0 writes root-owned files into whatever it shares with the host — or3-dev's
bind-mounted clone today. The same uid is what the hub's sidecar runs as, to read the
gavin-owned `tunnel.json`. It refuses to build at 0 rather than doing it.

`restart` is `stop`/`start` deliberately — `up -d` re-evaluates the config and may
recreate the container, throwing away every live session in it. The corollary: a
change to `compose.yaml` only lands on `up`. This is the same rule
[`../CLAUDE.md`](../CLAUDE.md) states for the deployments, for the same reason.

`make down-volumes` takes `CONFIRM=yes`. It drops **the project's own volumes** — every
cloned workspace, with any unpushed work in it; every env volume, with the repos' `.env`
files; the shared `claude-sessions` volume; and `hub-state`, which holds the hub's key, its
known_hosts and **the hub's sshd host key**. So afterwards every container authorises a new
hub key at its next start, and every client is asked to accept a changed host key for `dev`
— the moment a real one would be waved through, so expect it before you run this. The claude
and gh logins, the conversation history and each container's own host key are in
**external** volumes, kept from each container's old project, and `down -v` leaves those
alone.

`logs` follows sshd's output. When the question is why a start went wrong, use
`boot-log`: the top of the log, where the entrypoint's lines are.
