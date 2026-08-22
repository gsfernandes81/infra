# infra-dev — the development container on `zero`

Runs Claude Code against **this** repo on `zero` (Pi 5, arm64), reached by ssh, with
Ansible in the image so the container is also a control node for the fleet it manages.

## Why this exists

**To stop paying the phone's radio for work that has nothing to do with the vessel.**

Driving Claude from the Android app or from Remote Control means every token of every
response crosses the phone's mobile data — the one metered link on the whole map, and
the rule for reasoning about it is the **or3** repo's `CLAUDE.md` § *Data budget*:
metering follows the destination, not the size, and the phone's radio is the only thing
on the map that costs anything. Working in a container on `zero` instead means the model
traffic goes out over zero's home connection, and what crosses the radio is a terminal
session: your keystrokes and the characters that come back.

The same argument applies twice over to Ansible. An `ansible-playbook` run from Termux
reaches `zero`, `one` and `two` over the internet, so a full audit is metered from end
to end. The identical run from inside this container reaches `one` and `two` across the
home LAN and `zero` over its own loopback. **The audit becomes free.** That is the
substantive reason this container is not just a second shell on zero, and it is why the
image carries `ansible-core` and the three collections rather than expecting you to
install them.

## What it is not

- **Not a tunnel endpoint.** `or3-dev` publishes an sshd that the phone terminates a
  reverse forward on, to reach the vessel LAN. Nothing tunnels back through this one,
  and its `sshd_config` sets `AllowTcpForwarding no` to keep it that way.
- **Not a Remote Control host.** `or3-dev` ships `rc-supervisor.sh`, disabled by
  default. This one ships nothing of the kind: the container exists to replace driving
  Claude from the phone, and shipping a disabled daemon for the thing it replaces is
  hedging against its own reason to exist. or3's copy is there if the need returns, and
  adding it here should be a decision with reasoning attached rather than a default
  nobody chose.
- **Not a holder of the docker socket.** See *The socket line somebody will add* below.

## Layout

| | |
|---|---|
| `Makefile` | **the management interface** — `make up`, `make login`, `make status`, … |
| `compose.yaml` | the stack — `name: infra-dev`, one service, loopback-only port 2225 |
| `Dockerfile` | Debian slim + Node 22 + Claude Code + gh + screen/abduco + sshd + **ansible** |
| `entrypoint.sh` | ssh material → Claude config → `git pull` → **sshd(fg)** |
| `login.sh` | in the image: the interactive logins, idempotent — `make login` |
| `status.sh` | on the host: the readouts — `make status`, `verify`, `fleet`, `collections` |
| `seed-secrets.sh` | **run on zero**; generates the keys and lifts the ssh fragments |
| `sshd_config` / `ssh_config` | the in-container daemon, and the baked half of how it reaches out |
| `config.fish` | fish's config, baked in — puts every login shell in `/workspace` |
| `.env.example` | copy to `.env` on zero and edit |

## Bring-up, from nothing

All of it on `zero`, in your own terminal — `gavin` is not in the docker group, so none
of this runs from an agent session.

```sh
cd ~/infra/dev
./seed-secrets.sh                      # generates both keys, lifts the ssh fragments

# the two things seed-secrets.sh prints and does NOT do:
gh repo deploy-key add ~/.infra-dev-secrets/id_ed25519_infra_deploy.pub \
    --repo gsfernandes81/infra --title infra-dev-zero --allow-write
for h in zero one two; do ssh-copy-id -i ~/.infra-dev-secrets/id_ed25519_fleet.pub $h; done

cp .env.example .env && $EDITOR .env   # INFRA_SRC and INFRA_SECRETS are the two that matter
make dev                               # build, start, then walk the logins
```

Then add the phone's public key so it can get in:

```sh
cat >> ~/.infra-dev-secrets/authorized_keys    # paste the phone's ~/.ssh/id_ed25519.pub
make restart
```

`make dev` is `make up` followed by `make login`, which is the walkthrough in
`login.sh`: git over ssh, the three hosts, `gh auth login`, `claude auth login`. Every
step reads the current state first and only prompts for what is not done, so re-running
it is safe and usually silent.

Then `make verify` should read `sshd: running in the foreground`, `auth: claude logged
in`, `colls: all of requirements.yml is installed`, and three hosts answering.

## How this container is used

**You ssh into it and work in an `abduco` session** — from Termux on the phone, or from
a PC:

```sh
ssh infra-dev                                  # a shell
ssh -t infra-dev abduco -A claude claude       # a claude that survives the link
abduco                                         # (inside) list sessions
```

`abduco -A NAME CMD` attaches the session called `NAME`, creating it if it is not
there — so the same command starts the work and comes back to it. **Ctrl-\\** detaches;
what is under it keeps running, and a dropped connection costs nothing. A claude
started *outside* a session dies with the ssh link that carried it, which on a phone
means dies at the first lock screen.

**There are two ways in and you want both.** Cloudflare is the normal one; the loopback
port through zero is break-glass. See *Cloudflare* below for why keeping the second is
not belt-and-braces.

```
Host infra-dev                     # normal — no dependency on zero's sshd
  HostName infra-dev.gsrpi.uk
  User dev
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand cloudflared access ssh --hostname %h

Host infra-dev-lan                 # break-glass — no dependency on Cloudflare
  HostName 127.0.0.1
  Port 2225
  User dev
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand ssh zero nc %h %p
```

The second must be a `ProxyCommand` rather than a `ProxyJump`, for the reason
`or3/dev/README.md` § *`ProxyJump zero` does not work* sets out at length: zero's sshd
sets `AllowTcpForwarding no`, which refuses the `direct-tcpip` channel `ProxyJump`
opens, and flipping that setting would weaken the internet-facing box that runs Immich.
The first needs no such workaround, which is one of the things the tunnel buys.

The Makefile is how the container is stood up and looked at, not how it is used.
`make claude` and `make shell` are the same two sessions reached from a terminal on
zero instead — `make claude` attaches the *same* `claude` session the ssh line above
does, not a second one.

## Ansible from in here

```sh
ansible fleet -m ping                      # from any directory — see below
ansible-playbook playbooks/audit.yml -K
```

**`ANSIBLE_CONFIG` is set in the image** to `/workspace/ansible/ansible.cfg`. On the
phone, `ansible.cfg` is found only in the cwd, so every run needs `cd ~/infra/ansible`
first and forgetting it produces `No inventory was parsed` — which reads as a broken
inventory rather than a wrong directory, and cost half an hour once. Naming the file
absolutely removes that failure. It points *into the bind mount*, so the config in
force is the repo's and there is no second copy in the image to drift from it.

That works because a relative path inside `ansible.cfg` resolves against **the config
file's own directory**, not the cwd — which is the part worth having checked rather than
assumed, since the whole arrangement rests on it. Verified on ansible-core 2.21.3, the
version this image pins, against this repo's real `ansible/` directory from an unrelated
working directory: `ansible-inventory --list` returned all three hosts with `group_vars`
and `host_vars` applied, and the same command with `ANSIBLE_CONFIG` unset reproduced the
`No inventory was parsed` warning exactly. If a future ansible changes that resolution,
this is the line that breaks and `make fleet` is what says so.

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

## Cloudflare

### The order, and why it is this way round

**Stand the container up first, with no tunnel, and provision from inside it.** The
tunnel is not a prerequisite for the container; the container is a prerequisite for
provisioning the tunnel comfortably, because **there is no ansible on zero and there
should not be.** zero is the box being managed — installing a control plane on it is the
wrong direction, and this container is what zero's control node is *for*.

```sh
# on zero, once — the container comes up with no tunnel and is reached on 127.0.0.1:2225
cd ~/infra/dev && ./seed-secrets.sh
cp .env.example .env && $EDITOR .env      # leave DEV_TUNNEL_HOSTNAME empty for now
make dev

# then from inside it — where ansible lives, and where the API calls are free
make shell
cd /workspace/ansible
ansible-playbook playbooks/cloudflare-dev-tunnel.yml --check    # prove first
ansible-playbook playbooks/cloudflare-dev-tunnel.yml            # apply

# back on zero: set DEV_TUNNEL_HOSTNAME=infra-dev.gsrpi.uk in dev/.env
make up                                   # NOT restart — the entrypoint reads it at start
```

The phone works too and needs no container — it has `ansible-core` and can reach zero —
but the Cloudflare calls are then metered, and so is the ssh to zero. From inside the
container both are free.

### The container has to reach its own host, and that needs two nudges

`one` and `two` are ordinary LAN addresses a bridged container reaches unaided. **zero is
the awkward one**, because from inside the container zero is the bridge gateway, and
because two files that should describe it do not:

- **`~/.ssh/config` on zero has no `Host zero` block** — nobody writes one for the machine
  they are sitting on. `seed-secrets.sh` synthesises it, pointing `HostName` at the bare
  name, and `compose.yaml` maps that name to `host-gateway`. Docker's own alias, so it
  survives the bridge being renumbered in a way a hardcoded `172.17.0.1` would not.
- **`~/.ssh/known_hosts` on zero has no entry for zero either**, and `ansible.cfg` sets
  `host_key_checking = True`, which fails rather than prompts. `seed-secrets.sh` takes the
  key from `/etc/ssh/ssh_host_ed25519_key.pub` instead — more authoritative than a
  known_hosts line, which only records a key somebody once accepted.

Both were found by trying to run the playbook rather than by reading the code. Without
them the failure is `ansible cannot reach zero`, which sends you looking at the fleet key
and not at a missing four-line block.

`cloudflared` runs **inside** this container, not on zero, which is
[`../docs/management-plane.md`](../docs/management-plane.md) § *Addressing*'s decision
and still the right one: the tunnel's identity travels with the container, so moving it
to `one` changes no ingress rule anywhere. Every host-side alternative — extra rules on
zero's existing tunnel, or a shared ingress container — breaks exactly there.

**A playbook, not a script.** It was written as `dev/cf-provision.sh` first and that was
the same instinct that put `bin/compose` in this repo. Provisioning the way in to a
managed box is management-plane work: in the plane it gets parsed JSON instead of a
hand-rolled extractor, a real `--check`, `no_log` as a mechanism rather than as
discipline, and an API token that becomes a Vault variable at Phase 4 with no rewrite.

### It is additive, and that is load-bearing

`DEV_TUNNEL_HOSTNAME` unset means **no tunnel at all** and the container is reached over
`127.0.0.1:2225` exactly as if none of this existed. Set but with no credentials present
is a warning at start, not a failure to come up.

**Keep the loopback publish even once the tunnel works.** It is tempting to drop it and
be rid of the port bookkeeping, and that would leave `docker exec` on zero — needing
sudo, on a box you may be trying to reach *because* something is wrong — as the only
fallback. The two failure modes are independent: Cloudflare being down or the token
being wrong does not touch `ssh zero`, and zero's sshd being wedged does not touch the
tunnel. Having both is the only reason neither is a single point of failure.

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

Fully static, no loader needed. The same hash is pinned in the `Dockerfile`. **The
35.7 MiB is metered on the phone** and is priced in or3's `docs/data-ledger.md`.

**Access does not add a browser.** `cloudflared access login --help` says, in its own
words, *"The subcommand will launch a browser. For headless systems, a url is
provided."* — so even the human flow degrades correctly. But it never runs here, because
the policy is a service token:

```
--service-token-id value      [$TUNNEL_SERVICE_TOKEN_ID]
--service-token-secret value  [$TUNNEL_SERVICE_TOKEN_SECRET]
```

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
| Cloudflare **API token** | nowhere — `vars_prompt`, in memory for one run | in `$INFRA_SECRETS` |
| Tunnel **credentials** | `$INFRA_SECRETS/tunnel.json`, mode 600, mounted read-only | in argv or env |
| Access **service token** | the phone's environment, mode-600 fish conf.d | in the container, or in a `ProxyCommand` |

Each of those "must never" is a specific failure, not tidiness:

- **The API token cannot go in the secrets directory** because that directory is mounted
  into the container. A container able to rewrite the Access policy in front of itself
  is not protected by it. Nothing the running container does needs that token.
- **The tunnel credentials are a file, not `--token`.** The host tunnels use
  `--token <secret>`, which is `host-setup.md`'s token-in-argv leak and
  `management-plane.md`'s *secrets never go in `command_args`*. There is no
  `supervise-daemon` in a container, but `docker inspect` shows argv **and** env, and
  `.Config.Env` is exactly what `audit.yml` refuses to read because it holds live
  secrets. A read-only credentials file is the spelling that is in neither.
- **The service token must not be in the container**, because it authorises *reaching*
  the container — putting it inside is the same mistake in the other direction. On the
  phone it goes in the environment rather than the `ProxyCommand`, because a secret on a
  command line is a secret in `ps` output and in shell history.

### Health

`make status` reads a `tunnel` line with three distinguishable answers — off, configured
but not connected, and serving — because a single up/down collapses the interesting
middle case. The probe is `readyConnections` from cloudflared's own metrics endpoint on
`127.0.0.1:20241`, which is the probe [`../docs/recovery.md`](../docs/recovery.md)
already calibrated: counting sockets on port 7844 and reading the log were both tried on
`one` and **both read dead against a tunnel that was serving normally**. A process check
would repeat that mistake here in a new way — cloudflared is running the whole time it
retries a tunnel that will never connect. `make tunnel-log` is what it points you at.

## What the container can reach, and what that is worth

| | Reaches | Held as |
|---|---|---|
| git | `gsfernandes81/infra`, read-write | deploy key, generated on zero, never transmitted |
| `gh` | your GitHub account, at whatever scope the token has | a login in the `infra-gh` volume |
| the fleet | `zero`, `one`, `two` as `gavin`, no sudo without `-K` | `id_ed25519_fleet`, generated on zero |
| the tunnel | outbound to Cloudflare's edge; publishes this sshd at one hostname | `tunnel.json`, read-only, written by the playbook |

**The fleet key is the one that is new, and it is a bigger prize than anything
`or3-dev` holds.** `or3-dev`'s deploy key touches one repo and its vessel key touches
one PC; this reaches every host in the fleet as an account in `wheel`. Three things
make that an acceptable trade rather than a quiet escalation, and all three are
properties to preserve:

- **It is a separate key from the one you use by hand**, so it is revocable on its own:
  pull three `authorized_keys` lines and the container is locked out while your laptop
  still works.
- **It never leaves zero.** `seed-secrets.sh` generates it there. There is no copy of
  it on the phone, in the repo, or in transit, so there is nothing to lose.
- **It cannot escalate unattended.** sudo wants a password on all three hosts and this
  repo refuses NOPASSWD. Read the fleet freely; change it only with someone present.

The published port is `127.0.0.1:2225` for the same reason, and the loopback default is
the whole of that port's protection — sshd behind it is key-only, but what a key gets
you here is a shell holding all three of the above.

## The socket line somebody will add

`- /var/run/docker.sock:/var/run/docker.sock` is missing from `compose.yaml`
deliberately, and it is the single most likely edit somebody makes in a hurry, because
this is the repo that drives docker stacks.

`decisions.md` puts the docker group in the same class as root: anyone holding the
socket can bind-mount `/` into a container. Handing it to a container that also runs a
claude and holds ssh keys to all three hosts is that same grant with two more ways to
reach it — and it would be handed to the box that runs Immich and the Cloudflare
tunnel, not to a spare one.

**Nothing needs it.** Ansible drives docker on `zero` the same way it drives docker on
`one`: over ssh, as a host in the inventory. `community.docker`'s `docker_compose_v2`
invokes the Compose CLI plugin on the target and needs neither a local socket nor the
Python SDK, which is what makes retiring `bin/compose` at Phase 3 cheap. If something
one day genuinely needs the socket, the answer is a rootless podman socket under a
dedicated account, not this line.

## Sharing or3-dev's layers

**Every expensive layer in the `Dockerfile` is byte-identical to `or3/dev/Dockerfile`,
on purpose.** zero has already built that image, so the apt layer, the Node + Claude
Code layer and the `gh` tarball are cache hits, and this image costs the ansible layer
plus a few small `COPY`s. On a Pi 5 that is the difference between a rebuild of about a
minute and one of about fifteen.

It is also fragile in a specific way: add a package to one list and not the other and
**both** images pay full price for every build from that line down, silently — nothing
fails, it just gets slow, and the reason is two directories away. So when either file
is edited, edit both, and put any genuine divergence *after* the shared block rather
than inside it.

That fragility is the argument for the next section.

## Four copies of this, and what to do about it

`zero` now runs four of these: `dd-dev`, `ds-dev`, `or3-dev` and this. They differ in
about six values — repo, container name, port, volume prefix, secrets directory,
whatever extra tooling that repo needs — and agree on some 700 lines of Dockerfile,
entrypoint, Makefile and sshd config. **This one was written to be the last copy, not
to be a fourth pattern**: everything or3-specific in `or3/dev` is already a variable
here, and the two files that carry host-specific values (`ssh_config.fleet`,
`known_hosts.fleet`) are read from the secrets mount rather than baked.

The shape the generalisation should take, when it is done:

- **`infra` owns a base image.** One `Dockerfile` here, built on the host as
  `gsrpi-dev-base:<tag>` — Debian slim, Node, Claude Code, gh, screen/abduco, sshd,
  fish, the `dev` user, the ENV block. That is the 700 shared lines, in one place.
- **Each repo's `dev/Dockerfile` becomes three lines**: `FROM gsrpi-dev-base:<tag>`
  plus whatever that repo needs on top — nothing for or3, `ansible-core` and the
  collections for this one.
- **The entrypoint, sshd config and Makefile ship in the base image** and are
  parameterised by environment, which is most of the way to how they already work.
- **`compose.yaml` and `.env` stay per-repo.** They are the six values that genuinely
  differ, and they are already the only place those values live.

Two things make it worth doing rather than tidy-minded: the layer-sharing above becomes
guaranteed instead of a convention nobody can check, and a fix to the entrypoint —
which has already been made three times — gets made once. Two things make it work to
schedule rather than now: there is no registry on this fleet, so "the base image" means
a build-order dependency between repos that has to be made obvious rather than
discovered, and it is a change to the thing you are working *inside*, which is the
category this repo's `CLAUDE.md` is most careful about.

Until then, `or3/dev` and this are the two copies to keep in step, and the *Sharing
or3-dev's layers* note above is the reason.

## Secrets

None are in git. `.env` and `.env.*` are gitignored; everything else lives in a
mode-700 directory on zero (`INFRA_SECRETS`, default `~/.infra-dev-secrets`), mounted
read-only at `/run/infra-secrets`:

| File | What it is |
|---|---|
| `authorized_keys` | public keys allowed to ssh **into** the container |
| `id_ed25519_infra_deploy` | GitHub deploy key for this repo, read-write, generated on zero |
| `id_ed25519_fleet` | reaches `zero`, `one`, `two` as `gavin`, generated on zero |
| `ssh_config.fleet` | the three `Host` blocks, lifted from zero's own `~/.ssh/config` |
| `known_hosts.fleet` | their host keys, lifted from zero's own `~/.ssh/known_hosts` |
| `tunnel.json` | Cloudflare tunnel credentials — written by the **playbook**, not `seed-secrets.sh` |

**There is no `credentials.json`, not even behind a flag.** or3-dev keeps one as a
documented bad idea: copying the phone's Claude login in does not work — claude
contacted the auth server one second after starting and wrote the file back with
zero-length tokens, and the phone's own login had by then been through a refresh it did
not initiate. An OAuth login is bound to the device that performed it. Repeating a
documented bad idea in a second container is how it stops reading as one, so the only
path here is `make login`, once, persisted in the `infra-claude` volume.

**The last two files are why `seed-secrets.sh` runs on zero and not on the phone.**
or3's version has to run on the phone because the material lives there. Everything here
is either generated on zero or lifted from zero's own working ssh setup — which is also
why it is *right*: the container reaches `one` exactly the way zero does, rather than
through a second description of the hop that is free to disagree. Nothing crosses the
radio at all.

## The three things that are load-bearing

**`sshd` is the foreground process, so the container's lifetime is the door's.**
Nothing you type can end the container — `exit` closes an ssh session, `/exit` closes a
claude, and PID 1 has not moved.

**A session that is not in `abduco` dies with the link that carried it.** On a phone
that is not a corner case: the ssh session ends at the lock screen, and an unwrapped
claude ends with it, mid-edit. `abduco -A claude claude` is the habit — `make claude`
and the ssh line above deliberately name the *same* session, so it does not matter
which way you came in. `screen` is also in the image and is better for ordinary shell
work; abduco is what you want under a full-screen program, because it is detach/attach
and nothing else, so every key goes through to what is underneath.

**`/workspace` is a bind mount of the host's clone, not a second checkout.** A `git
pull` in the container and one on zero are the same pull, on one working tree — there
is nothing that can drift. The entrypoint pulls `--ff-only` on start, best-effort: a
container that will not come up because the network is down, or because the tree has
local work, is worse than one running a slightly old checkout.

## The targets

```sh
cd ~/infra/dev
make              # the header of the Makefile: every target, one line each
make up           # build + (re)create — drops every session in the container
make restart      # stop + start; does NOT re-read compose.yaml
make status       # one screen: container, sshd, sessions, logins, fleet files, ansible
make verify       # status + the tools + the collections + the fleet
make login        # the logins, again
make fleet        # ssh to each host, then `ansible fleet -m ping`
make collections  # the image's collections vs ansible/requirements.yml
make claude       # attach (or start) the `claude` abduco session
make shell        # a fish shell in the container
make logs         # follow the container log (= sshd's)
make boot-log     # the entrypoint's lines, from the top, ANSI stripped
make tunnel-log   # what cloudflared has been saying, if the tunnel is on
```

They work with or without `sudo` — the Makefile adds one when it is not already root —
and the same set is available from the repo root as `make dev-up`, `make dev-login` and
so on. `make dev` at either level is the bring-up above.

The uid the container's `dev` user is built at comes from the **owner of the
checkout**, read with `stat`, not from `id -u`: under `sudo` that is 0, and a dev user
at uid 0 writes root-owned files into the bind-mounted clone. It refuses to build at 0
rather than doing it.

`restart` is `stop`/`start` deliberately — `up -d` re-evaluates the config and may
recreate the container, throwing away every live abduco session in it. The corollary: a
change to `compose.yaml` only lands on `up`. This is the same rule
[`../CLAUDE.md`](../CLAUDE.md) states for the stacks, for the same reason.

`make down-volumes` takes `CONFIRM=yes`, because the volumes hold the claude and gh
logins and the sshd **host key**: dropping them asks every client to accept a changed
host key, which is the moment a real one would be waved through.

`logs` follows sshd's output. When the question is why a start went wrong, use
`boot-log`: the top of the log, where the entrypoint's lines are.
