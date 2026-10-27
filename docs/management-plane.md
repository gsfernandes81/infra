# The management plane

> **Status: phases 0 through 2i done or in progress; 3 onwards queued** — see *Sequencing*
> for the table, which is the record. This line said "Phase 1 written and unrun" until
> 2026-08-29, eight days and ten phases after that stopped being true.
> below for what that means precisely. This is the argument, written down before the work,
> so the work can be argued with rather than reverse-engineered. Sections marked
> **DECIDED** are settled unless someone argues with the reason. Sections marked **OPEN**
> are genuinely undecided and must not be quietly resolved by whoever implements first.
>
> Written 2026-08-21, out of the question "add or3's dev container to infra", which turned
> out not to be about or3's dev container.

## The problem, stated exactly

**There is no single record of what runs where.** Every fact about a host's workloads is
stored three to five times, by hand, in prose. So every one of them has drifted:

| Fact | Where it is recorded | State on 2026-08-21 |
|---|---|---|
| `zero` runs `or3-dev` on port 2224 | ~~nowhere in this repo~~ → `ansible/playbooks/client-home-ssh-config.yml`'s registry table | **closed 2026-08-28** |
| 2222 = `dd-dev`, 2223 = `ds-dev`, 2224 = `or3-dev` | a **comment in or3's `dev/compose.yaml`** | the port registry for `zero` lives in the newest claimant's app repo |
| `zero`'s dev containers | `README.md` says "two" and names `dd-dev`, `dd-mysql`, `ds-dev`; [`recovery.md`](recovery.md) names only `dd-dev` and `dd-mysql` | two records, both wrong, wrong differently |
| `zero` and `two` are onboarded | [`roadmap.md`](roadmap.md) §1 says they "aren't in it yet — only placeholder dirs" | stale; both have symlinks |
| — | `roadmap.md` links `hosts/zero/HANDOFF.md` and `hosts/two/setup/root-setup.sh` | neither file exists |

`recovery.md` is the document you read from a ship link when a box has rebooted, and it
hard-codes both the per-host deployment list and the port grep. It is the most-drifted
file in the repo and the one where drift costs most.

Three frictions follow from that one gap, and they are the three that prompted this:

- **Nothing here can name a workload it does not own.** So the only way to make `or3-dev`
  visible in this repo was to move it in — which breaks `make dev` from a fresh or3 clone
  and inverts the dependency. That is a false choice created by the missing record, not a
  real trade.
- **Moving a deployment between hosts** is: relink `hosts/<host>/`, recreate `.env` by
  hand on the new box, edit two prose port lines, edit `recovery.md`, and — if the target
  is `two` — discover that it runs podman, not docker. Nothing checks any of it.
- **Bring-up from nothing** exists as a numbered manual for `two` only.
  [`host-setup.md`](host-setup.md) is explicitly topic-organised, not order-organised, and
  names no per-deployment prerequisites — secrets directories, deploy keys, tunnels, or
  the ordering of the mount guards against the first deployment start.

## What is not changing — DECIDED

Most of what follows touches settled ground, so the parts that survive intact are worth
naming first. Nothing below is weakened by this document.

- **[`decisions.md`](decisions.md): no key on `zero` authorising it to reach `one` or `two`.** The
  direction this document adds is `two` → `zero`/`one`, which is the direction that entry
  already blesses: *"the lifeboat direction is the safe one: `two` reaches out, because
  `two` exposes nothing."*
- **`check-system-drift` and `hw-inventory` still refuse to operate on a host you are not
  standing on.** Their reason is that they read the **local** `/etc` and `/sys` and would
  mislabel it as another host's — "confident fiction". Ansible gathers facts *from the
  target over SSH*, so it reads the right box. Ansible is a different mechanism, **not an
  exception to that rule**, and nothing here licenses pointing those two tools at a remote
  host.
- **Claude dev containers stay in their own app repos.** The rule was always right; it
  simply had no way to *record* the thing it excluded. This document supplies the record
  and moves no files. `make dev` from a fresh app clone is untouched.
- **`gavin` is not in the `docker` group, and nothing privileged runs from an agent
  session.** Ansible does not change this: playbooks are run by a person, from a control
  node, in their own terminal.
- ~~**`bin/compose` stays docker-only and stays refusing `destiny-director` by name.**~~
  **Reversed, and `bin/compose` deleted 2026-10-25** — see *`bin/compose` goes, at Phase
  3* below. Struck rather than deleted, because this list is what the document promises it
  is not disturbing, and quietly dropping a line from it would make the promise
  unfalsifiable.

## The control plane — DECIDED

⚠︎ **SUPERSEDED 2026-10-25: the phone is the only control node.** `two`'s half below was
Phase 8, and the owner dropped it: no control node inside the fleet. Kept because the
read-only/mutating split is still the right shape if a second one is ever argued for.

**Two control nodes, split by what they are allowed to do.**

| Control node | Runs | Key |
|---|---|---|
| `two` | scheduled, **read-only** playbooks — drift reports, health, inventory | its own, revocable alone |
| laptop / phone (Termux) | interactive, **everything that changes anything** | separate key, revocable alone |

Neither is a fallback for the other; they have different jobs. `two` gives you an
always-on reporting path that survives your laptop being shut. The laptop gives you the
mutating path and survives `two` being dead — which matters, because `two` is the
lifeboat, and a design where losing `two` also loses the management plane would make two
independent things fail together.

**The read-only/mutating split is what makes two control nodes safe.** Ansible has no
locking. Two control nodes running mutating playbooks concurrently interleave changes with
nothing to detect it. Restricting `two` to playbooks that change nothing removes the race
by construction rather than by a lock that has to be correct — and it matches this repo's
existing posture, where `check-*` reports and `install-system-file` writes, and the split
is the point.

**Verified prerequisite (2026-08-21, on `two`):** Alpine `armhf` — which is ARMv6, which is
what a Pi 1 B+ runs — does carry the packages.

```
ansible-14.0.0-r0
ansible-core-2.21.0-r0
py3-cryptography-47.0.0-r0
```

This was the question that decided whether `two` could be a control node at all, and it
was worth asking first: `py3-cryptography` needs Rust to build from source, and Rust's
armv6 support is where Alpine ports usually stop. It is packaged, so nothing is built on a
700 MHz core.

**`two` must be running no containers for this.** Its container workload — the
`destiny-director` test bot — moves off, which `decisions.md` already anticipated:
*"if `two`'s lifeboat jobs are built, they take precedence and this stack moves or goes."*
Management-node duty is close enough to lifeboat duty to trigger that clause. What `two`
runs afterwards is `cloudflared`, `crond`, `sshd`, Ansible on demand, and eventually
roadmap §5.

**SD-card wear is the cost to watch.** The lifeboat argument rests on that card outliving
the boxes it watches — the board is a decade old, the card is not, so the budget is real
but not nearly spent. Scheduled Ansible runs write logs and a fact cache; both
must go to tmpfs or be disabled, and no scheduled run may be frequent. This is a
constraint on the implementation, not a detail — record what was chosen and why.

## Why Ansible and not an orchestrator — DECIDED

Nomad and Consul were considered seriously and rejected. Recorded here so it is not
re-derived; argue with the reasons, not from scratch.

- **Nomad ships no 32-bit ARM build.** `linux_arm` was deprecated in 1.6 and 2.0.5 ships
  `linux_amd64` and `linux_arm64` only. Consul 2.0.3 still ships `linux_arm`. Cross-
  compiling Nomad for `two` was on the table and is the wrong move: it would put the only
  non-stock binary in the fleet on the box whose entire job is working when the others do
  not. **It is also unnecessary** — once the bot leaves `two`, `two` is not a scheduler
  node, and the question disappears rather than being answered.
- **A compromised Nomad server is arbitrary code execution on every client it serves.** A
  server on `zero` — the internet-facing box — scheduling onto `one` is strictly worse
  than the SSH key `decisions.md` refuses, and would be that entry reversed rather than
  amended. There is no third host to put it on: `two` cannot run it and should not.
- **A scheduler earns its keep in proportion to the interchangeable placements it can
  choose between.** For the pinned workloads that number is one — Immich is bolted to a
  bcache array, torrents to `/dev/net/tun` and a shared network namespace,
  destiny-director to its image architecture. Nomad would express the pinning as
  constraints and then never schedule anywhere else.
- **It makes bring-up-from-nothing worse**, which was one of the three problems. Recovery
  today is `sudo docker compose up -d` in the deployment's directory, which works with
  nothing else running. Under Nomad it starts with bootstrapping a control plane, its
  gossip key and its ACLs, before any workload starts, on a box you may be reaching from
  mid-ocean.
- **Dev containers are the worst fit of all.** They are `restart: no` *because* they hold
  live sessions and uncommitted worktrees. A scheduler's premise is that it owns the
  lifecycle and will reschedule. The job would have to be written to ask Nomad not to act
  on it.

**What was conceded, and why Ansible still wins.** The mobility argument is real: three
dev containers and two bots are not hardware-pinned, and their placement today is manual
habit rather than constraint. Five mobile workloads is enough to want *something*. Ansible
gives placement-by-playbook without a control plane, without a fleet-wide trust domain,
without excluding `two`, and without a scheduler that would have to be told never to
schedule.

**What is given up by not having a scheduler, stated plainly:** nothing rebalances on its
own, nothing restarts a workload on a surviving host when one dies, and "which host has
capacity" is a judgement rather than a computation. All three are acceptable on a
three-box fleet where two boxes are not interchangeable and the third runs nothing.

## Secrets — DECIDED

**Ansible Vault, in this repo, and that is the whole mechanism.**

Secrets are encrypted in `infra` (which is private — verified 2026-08-21). The vault
password lives on the control nodes. A move becomes: run the playbook against the new
host, which renders its `.env`; tear down on the old host and delete its copy.

**This is a portability mechanism, not a security one, and the distinction changed the
design.** An earlier draft of this argument aimed at "secrets never at rest on `zero` and
`one`", which required reworking every deployment from `env_file:` onto mounted secrets
and rendering values into tmpfs. That goal was not the actual requirement, and dropping it
removed all of that work.

The security posture nonetheless improves incidentally, which is worth stating so nobody
later mistakes the simplification for a regression. Today a `.env` exists **only** on the
box: gitignored, so a box loss loses it and nothing records what the value should have
been. Encrypted in a private repo it is versioned, reviewable and recoverable, and the
two-way secret scan ritual in [`../CLAUDE.md`](../CLAUDE.md) retires with it.

**It also dissolves the per-host `.env` problem without a design of its own.** Today
`deployments/<name>/.env` is one file, so a deployment carrying host-specific values
cannot be *defined once* and run on two hosts.

**Nothing exercises this today, and the near-miss is worth stating so it is not
mis-read.** Syncthing runs on both `zero` and `one`, which looks like the case — it is
not. They are two different services that happen to be the same software: `zero`'s
(`deployments/syncthing/`, `syncthing.gsrpi.uk`, `/media/syncthing`) syncs the general
share, and `one`'s (a service inside `deployments/torrents/`, `syncthing-torrents.gsrpi.uk`,
`/media/torrents`) distributes completed torrents. Two definitions because there are two
jobs, not because one definition could not stretch to two hosts.

So the limit is **latent rather than worked around** — no deployment in this repo runs on
two hosts at all, and the first one that wants to will meet it. That is exactly the
mobility this document is for, and `host_vars/` / `group_vars/` is what removes it.

Two costs to record rather than discover:

- **Vault ciphertext in git makes rotation historical.** An old commit keeps the old
  ciphertext, so a leaked vault password reaches history, not just `HEAD`. Mitigated by
  the repo being private, and by rotating the vault password on a different schedule from
  the secrets themselves. It is a stated trade, not a footnote.
- **A finding that is now a note rather than a blocker:** Compose resolves `env_file:` and
  `environment:` at container *create* time and writes the values into
  `/var/lib/docker/containers/<id>/config.v2.json`, and into `docker inspect`. So a secret
  passed as an environment variable is at rest on the host regardless of where the file
  lived. `ionic-traces`, `immich` and `destiny-director` all do this. **`or3-dev` already
  does not** — it mounts a mode-700 directory read-only at `/run/or3-secrets` and its
  entrypoint reads from it. If the requirement ever becomes a security one, or3-dev's
  shape is the pattern and Compose's `secrets:` block is the standard spelling of it.

## Addressing — DECIDED

**`cloudflared` runs inside each dev container, not on the host.**

A tunnel whose identity is inside the container travels with it: move the container to any
host and its hostname follows, with no ingress rule to update and no port published on any
host at all. That is better than today's `127.0.0.1:2224` bind, not merely equivalent to
it, and it makes "accessible regardless of placement" fall out of the arrangement rather
than needing to be maintained.

From Termux and the laptop the way in becomes:

```
ProxyCommand cloudflared access ssh --hostname %h
```

which retires or3's `ProxyCommand ssh zero nc %h %p` work-around and the
`AllowTcpForwarding no` friction on `zero` entirely — see or3's `dev/README.md` §
*"`ProxyJump zero` does not work, and must not be made to"*, which stops being a problem
rather than being worked around a second time.

**Chosen over Tailscale deliberately.** Tailscale would do the same job and slightly more,
but `cloudflared` is already on all three hosts and already the way in, and Tailscale would
mean standing it up on Termux for this reason alone. Not a technical verdict against
Tailscale; a preference for not adding a second overlay.

### How it is actually built — DECIDED 2026-08-22

Settled with the owner, and `infra-dev` is the first and so far only one built.

**Provisioning is a playbook**, `ansible/playbooks/server-create-dev-container.yml` (its
edge half, `_dev-container-tunnel.yml`), creating three objects over the Cloudflare API:
the tunnel, the CNAME and an Access application; each client then adds its own service
token to that application's policy when `client-home-ssh-config.yml` runs there (since
2026-10-04 — before that this play minted one shared token and printed its secret). It
was written as a shell script first and that
was the wrong instinct — the same one that put `bin/compose` in this repo, and the second
time the owner has had to point at it. Being in the plane rather than beside it buys
parsed JSON instead of a hand-rolled extractor, a real `--check`, `no_log` as a mechanism
rather than as discipline, and an API token that could have become a Vault variable at Phase 4
with no rewrite (it will not: it stays one per machine, decided 2026-10-25). It is not a one-off either: three more dev containers want the same four
objects, and rotating the host tokens below wants most of them.

**One scoped API token replaces the dashboard.** A browser is needed exactly once, to
mint it. `cloudflared tunnel login` would have been the same single visit and would cover
only tunnels and DNS, leaving Access as clicking — which on a phone is the thing this is
avoiding. After the token, every Cloudflare object in this fleet is reviewable code.

**The Access policy is a service token, and there is no identity provider.** The
application carries `allowed_idps: []`, `auto_redirect_to_identity: false`, and one
`decision: non_identity` policy. No account is linked to anything. This answers the
owner's constraint directly — Proton publishes no OIDC/SAML for personal accounts, so it
could never be an IdP here, and the arrangement needs none. If a human path is ever
wanted, Access's built-in one-time PIN emails a code to any address, Proton included, and
still configures no IdP.

`non_identity` is not interchangeable with `allow`. `allow` with a `service_token`
include still expects an identity and sends a headless client to a login page it cannot
complete, which presents as the tunnel being broken rather than as the wrong policy type.

**The client binary is required with or without Access**, because an `ssh://` ingress is
not raw TCP at the edge. Whether it runs on Termux — bionic, which refuses glibc-linked
builds — was the real question and was measured rather than assumed on 2026-08-22:
`cloudflared 2026.8.2 linux-arm64` is 37,404,344 B and **fully static**, no INTERP
segment and no dynamic section. It is hash-pinned in `dev/Dockerfile` and the 35.7 MiB is
priced in or3's `docs/data-ledger.md`.

**⚠︎ The loopback publish is gone (2026-10-04).** This paragraph used to argue for keeping
`127.0.0.1:222x` so that `docker exec` on zero — needing sudo — was not the only fallback.
The owner weighed the sudo prompt against the port bookkeeping and chose `make shell`
over `ssh zero`: both paths went through zero's sshd anyway, so the port never bought an
independent route, only a passwordless one. See [`decisions.md`](decisions.md).

**Three secrets, three homes, and the rules are asymmetric.** The API token lives in
`~/.config/cloudflare/api-token` on each machine that runs playbooks (since 2026-10-04;
before that prompted, in memory, for one run) and specifically NOT into the secrets directory,
because that directory is mounted into the container and a container able to rewrite the
Access policy in front of itself is not protected by it. The tunnel credentials are a
read-only file rather than `--token`, which is the containerised form of the rule
restated below. Each client's service token belongs to that client and must not be in the
container, because it authorises *reaching* the container.

### A control node inside the fleet — ⚠︎ DECIDED 2026-10-25: no

**The owner's call: no control node inside the fleet.** `infra-dev` stays a development
container with no route to the fleet, for good; the reasoning below is why, and it is kept.
**It retires Phase 8 too**, the owner said the same day: `two` is inside the fleet, and it would
have needed Ansible on a Pi and a key on `two` reaching `zero` and `one`, both refused here.
The phone is the only control node.


`infra-dev` was being built as a second control node — `ansible-core` and the collections
in the image, an ssh key reaching all three hosts — and that was stepped back from on
2026-08-22 before it was used. **By default the container now has no route to `zero`,
`one` or `two` at all.** It develops this repo; running playbooks against the fleet stays
on the control node. One variable turns it on (`INFRA_DEV_FLEET=1`), off is the default, and the
argument is here rather than in whoever next runs the script.

The objection is structural, not squeamish: it puts the control plane **inside a container
on one of the boxes the control plane controls**.

- **It cannot fix the thing it lives in.** zero wedged means the control node is wedged
  with it, and the box you most want to reach is the one you cannot. The phone has no such
  problem, which is most of the argument for the phone staying the real control node.
- **The blast radius is circular.** A key reaching all three hosts as an account in
  `wheel`, in a container that runs a claude, on the box that runs Immich and the
  Cloudflare tunnel. Compromise the container and you have the fleet, its own host
  included.
- **It is a third control node nobody sized for.** The section above names two — Termux
  now, `two` at Phase 8 — and `two` was chosen on the reasoning that a control node should
  be the box with the least on it. zero is the box with the most.

The argument the other way is real and is why this is open rather than closed: **an
inventory run from Termux is metered end to end to reach boxes sitting on zero's own LAN,
and from inside the container it is free.** That saving recurs every run, and Phase 8's
answer to it — scheduling from `two` — no longer waits on Phase 7's rootless podman (owner,
2026-10-25): it starts with what needs no root, and the container half stays interactive.

Three things would change the answer, and it is worth knowing which one you are waiting
for rather than revisiting this on a feeling:

1. **Phase 7 and 8 landing.** If `two` becomes the scheduled read-only control node, the
   metered-audit argument mostly evaporates and this stays off for good.
2. **A read-only split.** The inventory play needs no `become` on `one` and `two`. A
   container holding a key that can only read, with the mutating half staying on the
   phone, answers the blast-radius objection without giving up the saving. Nothing in the
   repo does this today and `ansible.cfg`'s `become: False` default is the right half of
   it already.
3. **The dev containers moving hosts** (Phase 5). A control node that follows the
   container to whichever box has room is a different proposition from one pinned to zero,
   and the objection about living inside what it controls stops being a constant.

Until one of those, it is off, and the container is a development container that happens
to have ansible in it for editing playbooks.

### The fleet's own tunnels — ✔ DONE 2026-08-29, Phase 2e

`zero`'s and `one`'s tunnel tokens were world-readable in a 755 init script for months and
`recovery.md` says both must be assumed disclosed. Rotation was deferred there to "when
physically present", which from a ship is months away.

**A session that does not cross the tunnel being restarted is what makes that a remote
operation**, and the mesh gives every box one: the two-phase procedure in `CLAUDE.md`
§ *Changing the thing you are connected through* (prepare and prove inert, then restart
with an end-to-end probe and automatic rollback) can be satisfied from another box.
`infra-dev` cannot serve: it has no route to the fleet (no fleet key, no
`ssh_config.fleet`).

The order, once `infra-dev` has been up long enough to be trusted:

1. `zero`: **done 2026-08-23**, with the session held on the **`two` bastion**. `/ready`
   turned out to be insufficient alone (`recovery.md`).
2. `one` — same, with the session held on **`one` reached by a jump from `two`**.
   An earlier draft said "held on `zero` over the LAN", which cannot be done:
   `recovery.md` documents that LAN path in the other direction (`one` → `zero`), and
   `decisions.md` refuses a key on `zero` authorising it to reach `one` at all. `two` is
   the bastion for both boxes — the lifeboat direction, which is the one that entry
   blesses. Confirmed reachable 2026-08-23.
3. `two`: **done 2026-08-29.** Its token had moved to `/etc/cloudflared/two.json` on
   2026-08-23 (the init script runs `--config`, not `--token`), and 2g deleted the tunnel
   on 2026-08-29, which voided the unchanged secret. Nothing disclosed is live on this
   fleet.

**All three are done.** It was deliberately not bundled with the dev
container work at the time, because it is churn on the boxes you are connected through
and the whole point of doing `infra-dev` first was to have somewhere safe to stand. That
turned out to be the right order twice over: every one of these was cut over from a mesh
route, and `two`'s took four attempts.

**Two things travel with this decision.** A tunnel credentials file per dev container — a
secret, which is what the Vault path above is for. And [`host-setup.md`](host-setup.md)'s
**token-in-argv leak**, flagged there as applied on no host: `supervise-daemon` logs its
child's full command line to syslog, so a live tunnel token sits in `/var/log/messages` at
mode 640 `root:wheel`. More tunnels means more instances of it, so it stops being
deferrable. **Rule, restated: secrets never go in `command_args`.**

## Placement — what can move and what cannot

| Workload | Host | Mobile? | Pinned by |
|---|---|---|---|
| Immich (+ db, ml, redis) | `zero` | no | the bcache-fronted btrfs array |
| Syncthing | `zero`, `one` | no | the data it syncs |
| torrents (gluetun + qBittorrent) | `one` | no | `/dev/net/tun`, shared network namespace |
| ionic-traces (**stopped** — see 2c) | none — off `hosts/one/` since 2026-10-25; exited containers and data still on `one` | **yes** | habit |
| send2ereader | `one` | **yes** | habit |
| destiny-director (test bot + pg) | `two` | **yes**, and must | armv6 images today — see OPEN |
| `dd-dev` + `dd-mysql` | `zero` | **yes** | habit |
| `ds-dev` (dossier) | `zero` | **yes** | habit |
| `or3-dev` | `zero` | **yes**, with a caveat | habit; see below |

**The `or3-dev` caveat is a design decision in or3, not an accident.** `/workspace` is a
bind mount of *zero's* clone, so a `git pull` in the container and one on the host are the
same pull on one working tree — "there is nothing that can drift", per its README. A
movable container gives that up and owns its own clone. That is a real trade and it should
be made knowingly, in or3, not implied by a placement decision made here.
**Made, 2026-10-27, by the owner:** every dev container's workspace, or3's included, is its
own clone in a volume ([`decisions.md`](decisions.md), *No workspace is a bind mount*).

**Ports stopped being a registry problem on 2026-10-04**, when addressing became tunnel
hostname only: `infra-dev` publishes nothing on zero, the break-glass path is `ssh -t zero
'cd ~/infra/dev && make shell'`, and the registry in
[`../ansible/playbooks/client-home-ssh-config.yml`](../ansible/playbooks/client-home-ssh-config.yml)
lists containers and repos, no ports. The other three containers' repos still publish
`2222 dd-dev`, `2223 ds-dev`, `2224 or3-dev`; dropping those is each repo's own change.
The drift row at the top of this document, whose worked example was these ports living in
or3's compose file, closes by there being nothing left to drift.

## Dev containers: what the credential experiment established

The design leans on a dev container being movable without a fresh interactive login. That
was tested rather than assumed, on `zero`, 2026-08-21.

**Reading the Claude Code CLI bundle first:**

- On Linux the credential storage backend is `plaintext` — a file, no OS keyring. The
  keychain paths (`security delete-generic-password`, `ioreg -c IOPlatformExpertDevice`)
  are macOS-only.
- The stored credential is
  `{accessToken, refreshToken, expiresAt, scopes, subscriptionType, rateLimitTier}` —
  **nothing host-derived**.
- The config's `machineID` is **not** the machine's ID. It is a random 32-byte value
  generated once and persisted in the config file; the box's `/etc/machine-id` is a
  different value of a different length. Every `/etc/machine-id` read in the bundle is
  inside vendored OpenTelemetry resource detectors, and every `deviceId` is in the
  analytics event schema. Neither is in the auth path.
- `CLAUDE_CONFIG_DIR` relocates **both** `.credentials.json` and `.claude.json`. or3 sets
  it to `/home/dev/.claude`, which is the `or3-dev_or3-claude` volume — so the volume holds
  the complete credential state and nothing lives outside it.

**The test:** snapshot `or3-dev_or3-claude`, restore into a fresh volume, run a throwaway
container against it with the real container down. Result:

```json
{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max", ...}
```

**So a move does not cost a `make login`** — provided the volume moves with the container.

### The rule that comes with it

**Exactly one holder at a time. Teardown before bring-up is a hard ordering, never a
convention.** or3's README records what duplication costs: the phone's credentials were
copied into the container, and `claude` rewrote the file one second later with zero-length
tokens. That was never device binding — OAuth refresh tokens rotate, so two concurrent
holders means the second refresh invalidates the first, and the loser writes empties. A
migration has one holder; a copy has two. **The failure mode of getting this wrong is
logging out the source device**, which on the phone is the thing you use to fix it.

### Two findings worth keeping

**The volume is not a login — it is 22 MB of working history.** The snapshot tarball came
to 22,171,662 bytes, holding `projects/` (40 entries), `sessions/`, `history.jsonl`,
`uploads/`, `daemon/` and `telemetry/`. The credential is tens of KB of that. Every move
copies the whole pile through whatever staging path is used, each copy is a disclosure
surface, and nothing prunes it. OPEN 1, decided 2026-10-25: the history moves with it.

**A guard that fails does not stop the operation it guards.** The test's
`mkdir -p /root/cred-test && chmod 700` ran unprivileged and failed — and the next command,
`docker run -v /root/cred-test:/out`, had the daemon create that directory as root at mode
755 anyway. The tarball landed world-readable. This is
[`../CLAUDE.md`](../CLAUDE.md)'s *"a backup inherits both the secret and the permissions"*
with a new wrinkle: the guard printed an error, and the sensitive step ran regardless. Any
playbook that stages a credential must **fail the run** when its permission step fails,
not warn.

**And the calibration lesson, again.** The first run of this experiment returned
`loggedIn: false` and was wrong. Compose prefixes named volumes with the project name, so
the volume is `or3-dev_or3-claude`; the command named `or3-claude`, and Docker **silently
created a new empty volume** rather than failing. An empty config dir is correctly not
logged in. `CLAUDE.md` says to calibrate a check against known-good state before trusting
its verdict; that step was skipped, and the result was a **failure for the wrong reason** —
the same defect as a pass for the wrong reason, and harder to notice because a red result
looks like information.

## The status board

<https://claude.ai/code/artifact/0133f388-9fd7-4392-8d2c-0e1b18610784>

The phase table below rendered for reading on a phone — every phase exactly once, grouped
done / in flight / open / gated. **The table is the record and the board is the view**: if
they disagree, the board drifted.

**Update it IN PLACE**, by passing that URL to the Artifact tool as `url`. Publishing
without it creates a second board and orphans this one, which is the failure this note
exists to prevent.

## Sequencing, and where podman fits

Ordered by risk, not by appeal. **Phases 0–2 change nothing on any host**, and they are the
ones that answer the question this document started from.

| # | Phase | Touches | Gated on | State |
|---|---|---|---|---|
| 0 | Control node on Termux, inventory, `ansible fleet -m ping` | nothing | — | **done** 2026-08-21 |
| 1 | Read-only inventory playbook (`server-generate-fleet-inventory.yml`) | nothing | 0 | **done** 2026-08-21 — run against all three; `docs/fleet-inventory.md` is generated and committed |
| 1b | Fleet package standardisation — `playbooks/server-install-packages.yml` | all three | 1 | **done** 2026-08-21 |
| 2 | `README.md` + `recovery.md` cite the generated inventory | docs only | 1 | **done** 2026-08-21 |
| 2b | `infra-dev` container, and the Cloudflare edge in front of it | `zero`, edge | 2 | **done** 2026-08-22 |
| 2c | `one`'s array — both "broken services" were the SP900 in bay 0 | `one`'s enclosure | — | **done 2026-08-24** — disk pulled, unattended boot proven |
| 2d | One base image for the four dev containers — `dev/README.md` § *Four copies of this* | `zero`'s dev containers | 2b | **DONE 2026-08-29.** All four converted to `gsrpi-dev-base`, `2026.08.25` built (arm64 + amd64, `sha256:f25cb8de…`, from `2f05f2e`) — the tag with **no remote control anywhere**, every container ssh + abduco and the supervisors deleted, plus `offload-idle-claude.sh`, which stops a detached idle claude and leaves it resumable; one held 1,146 MB. `infra-dev` and `or3-dev` run it. **`dd-dev` and `ds-dev` are converted but not started** — that is a `make dev-up` in each app repo whenever the owner wants them, not phase work, and they are down for unrelated reasons. ⚠︎ A container cannot report which base tag it is running: nothing is baked in and no marker file exists, so the two that do run it are owner-reported rather than read. Worth an `/etc/dev-base-version` next time the base is touched |
| 2e | Rotate the fleet's own tunnel tokens | `zero`, `one`, `two`, edge | 2b | **DONE 2026-08-29.** `zero` and `one` on 2026-08-23, one's by retiring its tunnel under 2g; `two`'s the same way on 2026-08-29 — deleting tunnel `bdb4a988` voided the credential that had been inline in its 755 init script, which is stronger than rotating it. No disclosed credential is left on this fleet |
| 2f | `cloudflared`'s init script logs nowhere | `zero`, `one`, `two` | — | **done on all three, 2026-08-23** |
| 2g | All three tunnels become locally-managed — new tunnels, ingress in git | `zero`, `one`, `two`, DNS | 2f | **DONE on all three.** `one` and `zero` 2026-08-23, `two` 2026-08-29 over the `two-one` mesh. Every host's routing is now a tracked file, and `ansible/2g` — the wrapper written for this migration — is deleted, as its own header said it should be. **The dashboard sweep, its manual tail, was done by the owner on 2026-10-25** and its plan deleted; how to tell a live service token from an orphan is in `cloudflare.md` § *Safe to delete* |
| 2h | cloudflared: staggered autoupdate, `one` 6h → `two` 72h → `zero` 240h | all three | — | **done 2026-08-24** — the staggered frequencies are installed and live on all three |
| 2i | Retire the `ssh-zero-dev-*` rules, and `anchor-two` with them — doors nothing is behind | `zero`'s host tunnel, DNS | nothing | **Done 2026-10-25.** `dd` and `ds` came out of `hosts/zero/system/cloudflared-config.yml` and `anchor-two` out of `two`'s on 2026-08-29. On 2026-10-25 the owner deleted all four CNAMEs (`ssh-zero-dev-dd`, `-ds`, `-or3` and `anchor-two`, verified NXDOMAIN on two resolvers), then installed both files and cycled both connectors, each from a session that did not cross its own tunnel (`two-one` for `two`, `zero-two` for `zero`); `ssh` through each tunnel works afterwards (owner-reported). `dd-dev` and `ds-dev` are reached through `ssh zero` and their loopback ports until Phase 5 gives them tunnels. The dashboard sweep's service-token half was finished the same day (owner-reported), and its plan deleted |
| 3 | First deployment adopted: `send2ereader` on `one`, **with its connector in the deployment** | one deployment, non-critical box, `one`'s ingress | 2 | **Done 2026-10-25, the cutover included (owner-reported).** `send2ereader` has its own tunnel and a `cloudflared` sidecar, publishes no port, keeps its name `bookit` through `subdomain:` in `edge.yml`, and is started by `server-deploy-send2ereader.yml` (since deleted, 2026-10-26: the redeploy play does it), the second deployment a play starts after `garmin-mcp`. That play's first run was the cutover ([its README](../deployments/send2ereader/README.md)), and the owner reports it, with the host-config install after it, complete. `bin/compose` is deleted, and `recovery.md` brings deployments back with stock `docker compose`. The connector pattern itself was set on 2026-10-24 by `calibre-web` (decisions.md, *Sidecar, not baked-in*) |
| 4 | Vault: `torrents`, the hosts' tunnel credentials files, and the dev containers' secrets (retargeted 2026-10-25; was `send2ereader`, then `ionic-traces`) | `torrents`' `.env`, `/etc/cloudflared/<host>.json` on all three, each dev container's secrets dir | 3 | **Retargeted 2026-10-25, the owner's call.** The old targets had nothing left to vault: `send2ereader`'s `.env` holds only its tunnel id and a path, and `ionic-traces` is stopped. The new ones are what a rebuild cannot otherwise get back without a person: the VPN login, each host's own tunnel (the MicroOS migration, a dead SD card), and a dev container's deploy key and tunnel credentials wherever Phase 5 moves it. **Not in Vault, by design:** the Cloudflare API token (one per machine), Access service tokens (one per client), and anything that rotates as it is used (Garmin's session, Claude logins), which a stored copy would make stale or log out. `immich`'s database password is not needed: root on `zero` can reset it and its dumps restore under any password. Mechanism unchanged: Ansible Vault, in this repo ([`decisions.md`](decisions.md)) |
| 5 | Mobile workloads — dev containers + in-container `cloudflared` | `zero` | 4 (OPEN 1 decided, OPEN 3 moot, 2026-10-25) | Phase 3 now tests the mechanism first, on a disposable deployment. **Owner's leaning, 2026-10-25: the sidecar model here too**, as Phase 3 settled it for deployments, in place of `infra-dev`'s connector started from its own entrypoint — likely, not yet decided. **[`plans/dev-pool.md`](../plans/dev-pool.md), decided 2026-10-25** — one memory pool (a parent cgroup) for every dev container, `claude-sessions` rewritten as a hub container that manages every container's sessions over ssh, and one sidecar tunnel. **Hub, compose and sidecar built 2026-10-26 on a branch, not on the fleet** ([`decisions.md`](decisions.md), *The hub, as built*): one `dev/compose.yaml`, `ssh dev` to a containers-first menu, workspaces in volumes. Left (claude-sessions `v0.5.0` released and pinned, everything on `main`, 2026-10-27): the App made, and the owner's one cutover for all four ([`handoff/2026-10-26-dev-hub.md`](handoff/2026-10-26-dev-hub.md)), the pool file with it. **Findings, 2026-10-27, filed not started:** (a) no file-transfer path through the hub — scp and sftp to a container go as a stream (`ssh dev ssh <c> 'cat f' > f`), since the hub's sshd forwards nothing and so cannot be a jump host; (b) the fleet-access plumbing in the base (`ssh_config.fleet`, `known_hosts.fleet`, `make fleet`, login's step 2) serves a control node the owner declined on 2026-10-25, and could go; (c) **move each workspace off `/workspace` into `~`** (owner, 2026-10-27: "an artifact of how we used to work"), now that it is a volume and not a bind of a host clone — but **the child repos go first**: dd's and ds's Dockerfiles COPY `pyproject.toml` and `uv.lock` into `/workspace` and their `child-init.sh` installs the project from it, or3's likely the same, so each child moves its paths and bumps its `BASE_TAG`, then the base and `compose.yaml` follow (the entrypoint's clone and env links, `in-workspace`, the trust seeding, `config.fish`, `ANSIBLE_CONFIG`, the claude-sessions agent's workspace, `DEV_ENV_FILES`), with the old volumes mounted at the new path, and `CLAUDE_CODE_PROJECT_DIR_NAME` set to the old project key (`-workspace`; check `ls ~/.claude/projects`), because Claude Code files each repo's auto memory and its conversation transcripts under a key derived from the repository's path, so without it the move would orphan every memory and every resumable conversation. After the cutover, its own change; (d) the base entrypoint warns "no id_* keys" for a container that was never meant to have any (invective-dev, nibbles-dev, ionic-dev), which reads as a fault; (e) a token check by `git ls-remote` passes on a public repo with no token at all, so infra-dev's `login.sh` (and any child copying it) reports GitHub good when the hub's token is missing; `gh api installation/repositories`, as invective's login uses, is the honest check |
| 6 | ~~`dd` off `two`~~ | `two`, `one` | arm64 CI, upstream | **Dropped 2026-10-25**, the owner's call: moving `destiny-director` follows its own needs, not this plan — [gsfernandes81/infra#11](https://github.com/gsfernandes81/infra/issues/11), which may or may not end in a PR. The number is kept so the others do not shift |
| 7 | **Rootless podman on `one`** — roadmap §2 | `one` | 3, MicroOS on `one` | **Deferred to MicroOS, 2026-10-25** — the owner's call, so `one` converts once, with memory limits, instead of on OpenRC without them and then again ([`decisions.md`](decisions.md)) |
| 8 | ~~`two` as the scheduled read-only control node~~ | `two` | ~~6, 7~~ — none since 2026-10-25 | **Dropped 2026-10-25**, the owner's call: no control node inside the fleet. It needed Ansible on a Pi and a key on `two` reaching `zero` and `one`, which this repo refuses, and its one unique benefit, alerting with nobody at the phone, goes to the proposed Cloudflare Worker monitor (see 2h's notes), which needs no key on the fleet. The number is kept. |

**Filed 2026-10-27, no phase number — dev's build key under podman.** `dev/Makefile` runs
Compose with `BUILDX_BAKE_ENTITLEMENTS_FS=0` so buildx may read or3-dev's deploy key, which is
outside the checkout ([`decisions.md`](decisions.md), the dev section). It is Docker-only and
inert under podman, whose build reads the key path itself. What the podman move must check is
the other half: that `podman-compose` passes a service's `build.ssh` through at all.

**Filed 2026-10-24, no phase number — nothing reports a stale sidecar `cloudflared`.**
A deployment's connector is pinned in its `compose.yaml` and is outside 2h's staggered
autoupdate by design, so it ages silently: `server-update-cloudflared.yml` and the hosts'
autoupdate never see it. **The fix is an updater that proposes, never one that deploys**
(owner, 2026-10-25): a bot such as Renovate opens a PR bumping the tag *and* digest in the
deployment's `compose.yaml`, and the owner merges and deploys as with any bump. What stays
ruled out is anything that updates on the box — an in-container update dies with the next
recreate, and a Watchtower-style puller would run an image git does not name. Covers the
app images too, not only the sidecar; `destiny-director` follows a moving tag by design and
stays out. `calibre-web` is the first such deployment and `garmin-mcp` the second.
**Configured 2026-10-25, and the Mend Renovate app installed by the owner the same day (owner-reported; no Renovate pull request had opened when this was written):**
`renovate.json` for the pinned deployments. Dependabot ran first and was replaced; its
first run proved a digest moves under a fixed tag and that ignore names carry no registry,
and proposed a Postgres 14 to 16 bump for Immich that was closed ([`decisions.md`](decisions.md)).
The floating images were pinned on 2026-10-25 to the digest each box was running
(`gluetun`, `qbittorrent`, both `syncthing`s, Immich's server and machine learning at
v3.0.1 — bumped to v3.3.5 in the repo later that day and deployed by the owner through
the redeploy play by 2026-10-26), each tag checked against the registry first, so Renovate can now propose their
bumps. Left unpinned: `ionic-traces`' `mysql:8`, stopped and switched off in
`renovate.json`.

**Filed 2026-10-25, no phase number — a large image pull starves `zero`.** Immich v3.3.5's
pull, two images at once, put `zero`'s load at 11.2 and dropped the redeploy play's ssh
session. `/var/lib/docker` is on the SD card, beside every container's root filesystem. The
play now pulls one image at a time and detached
([`_deploy-compose-one.yml`](../ansible/playbooks/_deploy-compose-one.yml)). The daemon's own
side is open: `max-concurrent-downloads` in `/etc/docker/daemon.json` (default 3 layers of
one image at once) would lower it further. dockerd reloads that setting on SIGHUP (moby
`daemon/reload.go`), so it touches no container and can be done any time, as a new tracked
`hosts/zero/system/daemon.json`. Moving `/var/lib/docker` off the SD card is the larger fix,
and belongs with the MicroOS move. **`one` did it first, on Alpine, on 2026-10-26**
([`decisions.md`](decisions.md)): a subvolume mounted over `/var/lib/docker`, copied with every
container id intact, which proves the procedure on the box where breakage costs nothing.
**`zero` followed the same day**, onto the SSD's `sda2` rather than its array, so the SD
card no longer carries image pulls on either box; the pull throttling above stays, as the
smaller fix for what is left.

**Filed 2026-10-26, no phase number — 7.3 GB of a dead containerd store on `one`'s SD card.**
`/var/lib/containerd` is the standalone containerd service's root, and its `meta.db` was last
written 2026-08-23. Docker does not use it: dockerd runs its own containerd, whose store is
`/var/lib/docker/containerd`. `/var/lib/rancher` exists as well, so k3s was on this box at
some point. Neither is read by anything running. Deleting them is its own decision, measured
first (CLAUDE.md § Landmines), and the containerd *package* stays either way.

**Filed 2026-10-26, no phase number — `bin/install-system-file`'s backups land wherever `$HOME`
is.** `BACKUP_ROOT` is `Path.home() / ".infra-backups"`, so the same install backs up to
`~gavin/.infra-backups` run as `gavin` (the script calls `sudo` itself for each write) and to
`/root/.infra-backups` run under `sudo` or from a `sudo su` shell, which is how `one`'s fstab
backup of this date reached `/root`. A backup should be in one known place, and a backup of
a secret-bearing file belongs in a root-only directory, not one `gavin` owns. **The fix, the
owner's call:** always `/root/.infra-backups/<host>/<stamp>/`, created with
`sudo install -d -m 700` since an unprivileged `mkdir` cannot make it, and the README's
restore steps pointed there. Before it lands, look for older backups under
`~gavin/.infra-backups` on every host, so none is forgotten in the old place.

**Filed 2026-10-24, no phase number — nothing alerts when `garmin-mcp`'s Garmin login lapses.**
The cached Garmin session lasts about six months. When it ends, the tools fail while `/healthz`
stays green, and the only signal is a failed tool call in claude.ai. **`/readyz` cannot answer
it**: upstream decides login state once, at start-up, so a running server reads `ready` with
dead tokens. The signal has to be a real Garmin call (an authorised `tools/call get_full_name`),
or a scheduled restart followed by `/readyz`. Same class as the missing uptime monitoring in
2h's row.

**Proposed route, recorded 2026-10-25 at the owner's ask — not built.** Mail goes out through
Cloudflare: gsrpi.uk already has Email Routing (its MX is Cloudflare's), and a Worker with a
`send_email` binding can send from a gsrpi.uk address to any destination verified there — the
owner's own inbox, which is all an alert needs. The probe runs on `one`, inside the
`garmin-mcp` project, calling Taxuspt over the compose network so it needs no way through the
OAuth shim. On failure it POSTs to the Worker, behind a service token, and the Worker sends
the mail. A Worker probing from outside would have to automate that OAuth login instead.

**Closed 2026-10-25, no phase number: the dev containers' service tokens expired a year
after minting.** `_client-dev-ssh.yml` minted each `<container>-<client>` token with only
a name, and Cloudflare's API gives a token one year (8760 hours) unless told otherwise, so
the tokens minted on 2026-10-04 would have lapsed around 2027-10-04 with `websocket: bad
handshake`, the August symptom. The owner set the existing tokens to never expire by hand
the same day. The play now mints with `duration: forever`, sets it on an existing token
before rotating, and reads the token back before admitting or writing it, as
`_client-fleet-token.yml` does for the fleet's. Found by the Fable review of the fleet ssh
gate's plan.

**2b–2e were off this list until 2026-08-22.** They come out of the `infra-dev` handoff.
As filed, two of them outranked Phase 3: `one`'s broken services were the only things on
the fleet *failing* rather than merely unbuilt, and Phase 3 adopts a deployment that
currently works. 2c was then diagnosed on 2026-08-23 and briefly looked blocked on
physical access; the disk was pulled on 2026-08-24 and it closed. 2d was ranked as
maintenance cost rather than risk, to wait for whichever of the four images next needed a
change; it was built on 2026-08-24 instead.

⚠︎ Everything above this line is the ranking as it was argued, kept because the argument
is the useful part. The phase table is the record of where things stand.

**2g, filed 2026-08-23 — DECIDED, not optional-but-nice.** The owner's reason, and it is
the deciding one: *"I'm not interested in leaving more config than I have to in a web
dashboard."* That is the same argument as everything else in this document — ingress rules that
can be reviewed, diffed and recovered from git rather than clicked into a UI nobody can
audit. It is not fixing a fault; zero's actual security problem was closed by 2e.

**It cannot be done in place.** `config_src` is create-time only (see
[`cloudflare.md`](cloudflare.md)), so each host gets a **new** tunnel created with
`config_src: local`, and its CNAMEs are repointed to the new UUID.

**For `one`, this absorbs 2e entirely.** A new tunnel arrives with fresh credentials in a
tunnel credentials file and no token in argv, so both phases are satisfied by construction
— and retiring the old tunnel is *stronger* than rotating its secret, because deleting a
tunnel kills the disclosed credential outright rather than superseding it. Do not run 2e's
two phases on `one` first; that work would be thrown away.

**Method, which is what keeps it cheap.** Both tunnels run at once — the new connector
comes up alongside the old one, on its own metrics port, serving nothing until DNS points
at it. Then repoint **one hostname at a time**, verifying between each, each independently
reversible by pointing the CNAME back. There is no cutover moment and no window where
everything is down together. Repoint by API with a `Zone:DNS:Edit` token rather than by
hand: eight records is twenty minutes of clicking and about a minute scripted, and the
scripted version is reversible the same way.

**`one` goes first, as a rehearsal.** It is the non-critical box, it needs tunnel work
regardless, and it has far fewer hostnames — capture them with
`curl -s 127.0.0.1:20241/config`, which nobody has done. It also picks up
`torrents.gsrpi.uk` already: its CNAME was found on 2026-08-23 to point at one's tunnel
all along, so there is nothing to move and one less DNS change than planned.

**`two` is in scope and is the special case.** Its token was never moved out of the
init script at all — `grep -c eyJ /etc/init.d/cloudflared` returns 1, confirmed
2026-08-23 — so it is a live disclosed credential in a world-readable file, and retiring
that tunnel is the cleanest remediation available. It is also the smallest job, one
hostname. `two` is in `sys` mode — an ordinary writable install — so there is no `lbu
commit` complication today, whatever the planned diskless switch would later add. It is
still the lifeboat, so: do it last, and not on the same evening as either of the others.

Estimated 1.5–2.5 hours per host, most of it verification. **`one` is smaller than first
thought** — five hostnames, not eight, so closer to an hour. Two unknowns that could
stretch it: whether those CNAMEs are freely editable or tunnel-managed, and whether Access
applications follow hostnames cleanly across a tunnel change — they bind to hostnames
rather than tunnels, so they should, but that is unverified.

**2h, filed 2026-08-23, and it is two findings rather than a plan.**

**Autoupdate was on and live.** All three cloudflared binaries were rewritten on 14–15
August, the day `2026.8.2` released, on a fleet where it was installed by hand six months
earlier. A boot-path binary on the internet-facing box, replaced with unverified bytes on
a 24-hour cycle — the same thing `dev/Dockerfile` refuses inside a container, where the
argument is *weaker*. The first answer was `--no-autoupdate` in all three tracked init
scripts — and that reversed the same day, for the reason below.

**All three run the 32-bit `arm` build, and two of them are `aarch64`.** Identical SHA256
across hosts, and `two` is `armv6l`, so nothing else executes on all three. It arrived by
accident — `host-setup.md` documented a per-architecture install using an asset name that
does not exist, so `curl -L` without `-f` would have written GitHub's 404 over the binary,
and one working copy was evidently distributed to all three instead.

**It is now a decision rather than a defect**, and the reasoning is in
[`decisions.md`](decisions.md) § *One cloudflared build on all three*. Briefly: the
rollout order only tests what later hosts will actually run, so per-architecture builds
would leave `two` as the first and only host ever to run the `arm` binary — the lifeboat
as canary for its own architecture. Uniform means every host runs something an earlier
host already survived. The cost is a dependency on the kernel's AArch32 support on `zero`
and `one`, recorded there as the thing to watch.

So 2h is only the autoupdate half — and it reversed once the same day, which is worth
recording. Autoupdate was turned off on the grounds that it replaces a boot-path binary
with unverified bytes. Then the owner's point: the reason updates were not happening was
that nobody was free to ssh in, and a fleet that drifts out of Cloudflare's support
window goes down all at once. **Autoupdate is justified here; what it lacked was a
stagger.**

So it stays on, at different check frequencies: `one` 6h, `two` 72h, `zero` 240h. A
host that checks rarely is simply behind, so a release that breaks `one` has days before
it reaches `zero`. What this does not give: guaranteed order (zero's check can land just
after a release, a few percent per release) or a health gate (a bad version reaches all
three eventually). `playbooks/server-update-cloudflared.yml` — explicit, hash-verified, each
stage refusing while an earlier one is unhealthy — exists and is not used; **revisit once
uptime monitoring exists**, e.g. `ping.<host>.gsrpi.uk`, because a gate is only worth
building when something can tell you a host is down, and today nothing can.
**The same Worker could be that monitor** (recorded 2026-10-25, not built): a Cron Trigger
probing each host's public endpoint and mailing on failure, as proposed for `garmin-mcp`'s
lapsed login below the phase table. Unlike a check on a box, it still reports when the box is
the thing that is down.

**2i, filed 2026-08-24, and it is a consequence of 2d rather than a plan of its own.**
It was found by the or3 session while converting `or3-dev`, and written into
[`cloudflare.md`](cloudflare.md) rather than left implied — which is the only reason it
is here at all.

**The fault is two doors, not a stale rule.** `or3-dev` is reached today through a rule on
**zero's host tunnel**, `ssh-zero-dev-or3.gsrpi.uk` → `ssh://127.0.0.1:2224`. Once it has
its own in-container connector on its own hostname, the old rule does not stop working —
it becomes a *second* public route to the same container, and only the new one is behind
Access. Retiring it is therefore not cleanup, and calling it cleanup is how it would sit
there for months.

**The window is real, but it is not opened by the merge — and that is the whole
sequencing.** An earlier draft of this entry said the clock starts when 2d lands. It does
not. The or3 agent's correction, verified against this repo's own code on 2026-08-24: the
in-container tunnel is *additive*, `dev/entrypoint.sh` starting a connector only when
`DEV_TUNNEL_HOSTNAME` is set **and** a tunnel credentials file exists, so an unset
hostname means no second door. The window therefore opens when the owner sets that
variable, which is a knob he holds rather than a consequence he inherits.

**So do this first and there is no window.** Retiring the rule early costs nothing,
because the break-glass path does not use the tunnel: it reaches `127.0.0.1:2224` through
**zero's sshd**, and that is the same origin the ingress rule points at. (It was the
`<alias>-lan` alias when this was written; the alias is gone and the hop is typed, which
changes nothing about the argument.) Dropping the
public hostname leaves the way in through zero untouched.

**It cannot be done from `or3-dev`, and the reason is the standing-position rule.** The
work is an edit to [`hosts/zero/system/cloudflared-config.yml`](../hosts/zero/system/cloudflared-config.yml),
`bin/install-system-file cloudflared-config.yml`, then **cycling zero's cloudflared** —
stop, poll until 20241 is free, start; never `rc-service restart`. `ssh-zero.gsrpi.uk`
*is* that tunnel, and so is every dev-container hostname riding on it. **The owner will
run it over a mesh route** (`zero-one` or `zero-two`), which does not traverse the tunnel
being cycled and is the position `CLAUDE.md` § *Changing the thing you are connected
through* asks for. Delete the CNAME as well as the ingress rule: the rule alone leaves a
record pointing at a tunnel that answers it with the catch-all 404.

**2g: `one` and `zero` are done, 2026-08-23.** Both run new tunnels created with
`config_src: local`, with their ingress rules in
`hosts/<host>/system/cloudflared-config.yml` and their old tunnels deleted. Retiring
`one`'s old tunnel is what finally voided its disclosed credential, so 2e closed for that
host as a side effect rather than as a rotation.

Three things the rehearsal was worth, none of which were the plan:

- **A tunnel carries objects the dashboard does not show.** Zero's old tunnel had a WARP
  private-network route, which the cutover left pointing at a connector-less tunnel and
  which no check would have caught. It surfaced only because deleting the tunnel failed.
  See [`cloudflare.md`](cloudflare.md).
- **The review step earns its place.** Both hosts' generated configs contained a rule
  that had to come out: `ionic-traces.gsrpi.uk` on one, retired; and on zero a
  `torrents.gsrpi.uk` rule that had never routed, which carried across would have moved
  one's torrent UI onto zero. The cutover now refuses to repoint a record that points
  somewhere else already.
- **The cutover must not arrive through the tunnel it cycles.** It severed its own
  connection on `one` and left the host half-migrated. It now refuses on a loopback
  client address and names the mesh alias to use — which is the same standing-position
  rule as `CLAUDE.md` § *Changing the thing you are connected through*, learned again.

**`two` was migrated on 2026-08-29, and 2g is done on all three.** What follows was
written while it was still deferred; it is kept because the reasoning held and because
what the migration cost is worth reading before the next one.

Four attempts, and every one of them found a real defect rather than bad luck:

1. **`~/.ssh/cp` did not exist on the laptop**, so the first play against a fleet host
   died with `unix_listener: cannot bind`, reported as UNREACHABLE — which reads like the
   box being down. `_client-fleet-ssh.yml` created `~/.ssh/cm` and not ansible.cfg's own socket
   directory; the phone had it only because someone once made it by hand.
2. **The host's checkout was stale**, so `install-system-file` installed the old config as a
   no-op, the credentials were then swapped to the new tunnel, and cloudflared could not
   authenticate a tunnel its config did not name. The guard that should have caught it
   read `lookup('file', …)`, which runs on the **control node** — it compared phase 1's
   output against the machine that produced it.
3. **The API token was invalid**, and Cloudflare answers that with `9109` on whatever
   endpoint you reach, so it looked like a missing permission on the zone lookup. The
   response body said otherwise and `no_log` was hiding it.
4. The run that worked.

The plays now verify the token first, check the host's own checkout and the **installed**
config before swapping credentials, print refusal bodies, and restore the config as well
as the credentials on rollback. `docs/decisions.md` carries each one.

Two hostnames, the smallest job, on the box with the least margin and no bastion of its
own — and it still took four goes. The deferral was right.

**On `two` this is one job with 2e and the Cloudflare dashboard sweep, decided 2026-08-24.**
Not three items that happen to be adjacent — three that close each other, in the order they
already have to run. The new tunnel arrives with credentials in a 0600 file, so 2e is
satisfied by *construction* rather than performed; deleting the old tunnel then **voids**
the credential that was inline in `two`'s 755 init script until 2026-08-23, which is
stronger than rotating it. **That move ended the exposure, not the disclosure** — the
tunnel secret itself never changed, so whoever read that world-readable file still holds a
working credential for tunnel `bdb4a988`. Only the delete ends that, which is why this is
still 2e's last host and why the correction does not make it less urgent. The orphaned Access service tokens and
applications left by the failed runs of 2026-08-22 are objects on the same tunnel and the
same dashboard visit — [`cloudflare.md`](cloudflare.md) § *Safe to delete* is the list.
Tracking them apart invites the half-done state this repo keeps meeting: a tunnel migrated
and its old credential still live somewhere nobody swept.

**The sweep stays a human step inside that job.** It needs judgement about which token the
phone currently holds, and that is not a fact any check on a box can establish.

**It did, and phase 1 run for real WAS the rehearsal.** All three plays were
substantially rewritten in the 2026-08-24 review (block/rescue rollbacks, the
originRequest assert, the re-run guard) and have not run since. A `--check` of phase 1
cannot rehearse them — the `uri` create is skipped in check mode and everything after it
dies on undefined, the exact bootstrap trap `_dev-container-tunnel.yml`'s header
documents. But phase 1 for real is inherently consequence-free: it creates a tunnel
nothing points at, abandoned by one delete. Running it against `two` exercises the new
guards — and the originRequest assert is checking the one tunnel nobody has ever
inspected, so if it fires, it fired before anything moved. Read the generated config at
leisure; phase 2 was a separate decision on a separate day, and was taken over `two-one`
rather than the wrapper's default `two-zero` — `one` was idle and the laptop was off the
LAN. **Reach `two` over the mesh for phase 2** — its tunnel is the thing being cycled,
which is how it went dark once already.

**2f, filed 2026-08-23.** `/etc/init.d/cloudflared` declares `stdout_log` and
`stderr_log`, which `supervise-daemon` does not act on. `/var/log/cloudflared.err` was
last written 2026-01-04 and `cloudflared.log` has been 0 bytes since 2025-12-24, through
a service that has restarted many times since — so the tunnel on the mission-critical box
has been logging into nothing for eight months, and the tracked file asserts otherwise.
It cost real time on 2026-08-23: six consecutive crashes produced no output, and the
cause was only found by reproducing it in the foreground.

**The script is hand-written, and that is the part to investigate rather than assume.**
`host-setup.md` installs the binary straight from GitHub, so Alpine packages no init
script — this one was written by hand after the generated service (`cloudflared service
install`) *would not work*, per the owner. **Why it would not work is not recorded
anywhere**, which is the actual risk: the obvious future "fix" is to throw away the
custom script for the generated one, and whoever does that will meet the same wall with
nothing to read. Establish and write down the original failure before changing the
script — then fix the log directives, on both hosts.

**Done on `one` and `zero`, 2026-08-23.** The names are `output_logger` / `error_logger`,
which take a *command* rather than a path — copied from `/etc/init.d/docker`, a stock
Alpine script using the same supervisor, in the default runlevel, demonstrably writing its
log. `containerd` was the other candidate and was passed over because CLAUDE.md records
that service as unused, and a script that may never have run is not known-good state.

**`two` was done at the same sitting, 2026-08-23**: `hosts/two/system/cloudflared`
declares `output_log` and `error_log`, both pointing at `/var/log/cloudflared.log`.

**It is a different fix from the other two, which is presumably why this paragraph
survived.** `zero` and `one` pipe through `log_proxy`, which arrived with docker; `two`
runs neither docker nor containerd, so it uses OpenRC's plain file variables — `output_log`
and `error_log` map to `--stdout` and `--stderr` in that box's own
`supervise-daemon.sh`. The cost is no rotation, which was measured and accepted: 1 MB in
seven months on 27 GB free.

**The stale version cost something.** During `two`'s cutover on 2026-08-29 this paragraph
was read as current, twice, and used to tell the owner the lifeboat logs nowhere and that
a foreground run was the only way to see a connector error. There was a log the whole
time, and it would have shown the credential/config mismatch directly instead of it being
inferred from a 503.

Two is not a copy-paste of the other two: it runs no docker, so
`/etc/init.d/docker` is not there to model on, and whether `log_proxy` exists at all needs
checking before assuming the same block works. `two` tracks `cloudflared`,
`cloudflared-config.yml` and `sshd-infra.conf`, each carrying an `infra-` header; and
`python3` is in `base_packages` with `ansible_python_interpreter` pinned to it fleet-wide,
so `check-system-drift` and `install-system-file` have always been able to run there. 2g's
cutover depends on the latter, which is why it was worth proving rather than inheriting.

**2c narrowed on 2026-08-23, and then turned out to be one fault rather than two.** The
owner's call on the first half: `ionic-traces` **stays down**. Very few users, and only
its database is worth anything, so repair is deferred indefinitely rather than scheduled.
Nothing is deleted — the compose file, the `SOURCE` pin and the `.env` all stay. The three
containers were stopped and taken off `restart: always` the same day.

**Both symptoms are the SP900.** `one`'s array has been unmounted for days. `mysql-ionic`
was not crash-looping because MySQL was broken, and Syncthing was not `exited` for a
reason of its own — both bind-mount subvolumes on `/dev/sdb1`, and `sdb` has not
enumerated since the bridge died. What the first audit recorded as *two broken services on
`one`* is one failing disk in bay 0, which [`recovery.md`](recovery.md) has described since
2026-08-04. The audit was right about the symptoms and had no way to see they shared a
cause; that is an argument for the inventory, not against it.

**The mount guard did its job, and this is the first time it has been observed doing it.**
`mysql-ionic` restarted into the bare `/media/ionic-mysql` once a minute for days under
`restart: always`, and `chattr +i` refused every attempt — `chown: changing ownership of
'/var/lib/mysql': Operation not permitted`. The database on the unmounted `sdb1` was never
touched, the bare mountpoint stayed empty, and the SD card had not moved off 37%. All four
guards on `one` report `chattr +i effective`. `CLAUDE.md` described them as *due* on `one`;
they were applied, and that heading is corrected.

An earlier draft of this entry, written before the diagnosis, argued that the crash loop
endangered the database and that ending it was the urgent part. **That was wrong, and
wrong in the direction of alarm.** It is recorded rather than quietly replaced because the
guard is the reason it was wrong: `+i` is what made a crash loop harmless, which is
exactly the outcome it was installed for. What looked like a service destroying its own
data was a service being prevented from doing so.

**There will be no backup of `/media/ionic-mysql`**, decided 2026-08-23 — `sdb1` is
healthy and `sda` holds nothing, so a second copy answers a risk that is not the one in
play.

**Syncthing is still a repair, and it is blocked on the disk**, not on anything in its own
configuration. It cannot start until `/media/torrents` and `/media/syncthing-config` are
mounted; starting it before then writes a blank config into a guarded mountpoint and fails
the same way MySQL did.

**Closed 2026-08-24: the SP900 was pulled**, with help at the enclosure — whose power
cycle, the one lever software could never reach, is also what un-wedged the bridge.
The MX500 enumerates as `sda` now (only disk); everything mounts by UUID so the rename
cost nothing. The close-out was demonstrated, not declared: an unattended reboot brought
back all four mounts, every container, healthy Syncthing reading its real config, and
four tunnel connections, with no hands. The array survived eleven days unmounted and a
crash loop against its guarded mountpoint without losing a byte — the `chattr +i` layer's
first live firing, and its full vindication. `ionic-traces` stays down by decision, as
before; that was never the disk's question.

**2e carries a check that belongs before it, not during it.** The order in *Still to do:
the fleet's own tunnels* holds `zero` first precisely because a session inside `infra-dev`
does not cross zero's own tunnel. That claim is the entire safety argument, and it is not
self-evident from inside the container: `infra-dev`'s connector and zero's host
`cloudflared` are two processes on the same box. `CLAUDE.md` § *Changing the thing you are
connected through* says to establish this from the owner's shell — `echo $SSH_CONNECTION`
— and never from a long-lived agent process, whose value is a fossil of the SSH session
that started it. Prove which connector carries the session before either token is touched.

**The Cloudflare API token is closed, not deferred.** The owner deleted the
dashboard-minted token on 2026-08-22. Nothing stored it, so nothing breaks; the next
provisioning run mints a new one, which is what *How it is actually built* above already
assumed. What is worth carrying forward is the scoping: that token was *All accounts / All
zones* against the five permissions it actually needed, and the place to fix that is at
mint time, not by deleting it again afterwards.

⚠︎ **Superseded 2026-10-25, twice: 7 stopped gating 8, and then 8 was dropped.** Phase 7 stays
for its own reasons (rootless podman on `one` with memory limits, at MicroOS). The reasoning
below was about Phase 8 and is kept as history.

**Phase 7 moved.** Rootless podman was going to be a follow-on; it is a **precondition of
Phase 8**, because `podman ps` as the connecting user needs no sudo.
`server-generate-fleet-inventory.yml` takes `-K` today only because `gavin` is not in the
`docker` group and NOPASSWD sudo is refused, and a scheduled run cannot type a password.
`decisions.md` said this in one line long before Ansible existed here: *"`gavin` not in
`docker` group | Root-equivalent. **Rootless Podman removes the need.**"*

**But it only removes it for `one`.** `zero` keeps needing sudo until MicroOS — see the
table below — so Phase 8 starts out able to audit `one` unprivileged and `zero` not at all
on a schedule. That is a partial unblock, and calling it a full one is the mistake to
avoid.

**And since 2026-10-25 Phase 7 waits for MicroOS on `one`**, the owner's call — which is
part of why Phase 8 stopped waiting on it the same day. On MicroOS rootless podman keeps its memory limits (the trade table below);
on OpenRC it would not, and the conversion would be done twice.

`one` first is also roadmap §2's own answer, for its own reason: it is the non-critical
box, its deployments are disposable, and it is where `recovery.md`'s
docker-vs-podman-compose commands finally get tested against something real.

### What Phases 1–2 actually bought

Three things, and none of them was the plan's stated goal — which is the argument for
having run the read-only phase before the writing ones.

- **The audit found live faults nobody had reported.** `one`'s Syncthing is `exited`,
  `mysql-ionic` is `restarting` in a crash loop, and two containers on `zero` report
  uptimes in the 1970s because they started before NTP. None of that is in any prose in
  this repo, and none of it would have been found by reading it.
- **A `--check` run stopped a change rather than confirming one.** `docs` was in
  `base_packages` for a day; the dry run showed it expanding to the entire TeX Live
  documentation set on a 1 GB Pi. It was removed before anything was applied. Every
  earlier dry run in this repo had agreed with the real one, which is how a dry run
  becomes a formality — this is the one that paid for the habit.
- **Standardising packages deleted two divergences that had been read as facts.** The
  netstat branch in `server-generate-fleet-inventory.yml` existed because `ss` was on one host
  out of three, and `one`'s `hardware.md` looked hand-edited because `usbutils` was on two
  out of three. Both are gone, and the fallbacks stay: a host built tomorrow has not run
  `server-install-packages.yml` yet.

Phase 2's own corrections were smaller and all of the same shape — the docs asserted
ports that were not listening (`8384/22000` on `one`, `2222` on `zero`) and a dev
container count that was two when it is three. The fix is not better prose; it is that
`README.md` and `recovery.md` now say **what the compose files ask for** and point at
the generated inventory for **what the boxes are doing**, so the two can be compared
instead of quietly disagreeing.

### What rootless podman costs on OpenRC — the trade table

| | `docker` group removed | memory limits |
|---|---|---|
| docker — today | no | yes |
| rootless podman on OpenRC | **yes** | **no** |
| rootful podman on OpenRC | no | yes |
| rootless podman on MicroOS | **yes** | **yes** |

On Alpine you pick one. On MicroOS you get both, because systemd performs the cgroup
delegation. Rootful podman is not a middle path — it does not buy the thing rootless was
for.

**The limits half is upstream's position, not an inference from `two`.** Rootless with the
`cgroupfs` manager is not a supported path for resource limits; the maintainer's answer to
exactly this question is to use the systemd cgroup driver. Manual delegation is the obvious
workaround and is documented failing: a non-root user cannot write
`/sys/fs/cgroup/cgroup.subtree_control`, and even after `chown`-ing a subtree by hand the
runtime still cannot write `cgroup.procs`.
([podman#8330](https://github.com/containers/podman/issues/8330),
[podman discussion #19158](https://github.com/containers/podman/discussions/19158).)

**Autostart is *not* on this list, and an earlier draft wrongly said it was.** `podman-restart`
covers rootful, and rootless on OpenRC is a small `local.d` or init script running
`podman start --all` as the user. Not built in the way systemd user services and lingering
are, but a few lines written once. The objection also differs in kind from the one
`decisions.md` actually upheld: the mount-guard service was refused for adding *a new way
for the box to come up with no containers* plus a false-failure mode, whereas an autostart
script that fails leaves a booted, reachable box with no containers — the same state a
power cut leaves today, since the dev containers are already `restart: no`. Degraded, not
stranded. Confirm the mechanism against Alpine's own Podman wiki page before writing it.

### The limit that would go quiet

`deployments/syncthing/compose.yaml` declares `deploy.resources.limits.memory: 768M`, and
Compose v2 enforces it. Under rootless podman on OpenRC that limit would be **silently
ignored** — still in the file, still read as protection, enforcing nothing. A declared
limit that does not bind is worse than no limit, for the reason this repo already knows: it
stops you looking. Any host that converts must have its declared limits either proven to
bind or deleted from the compose file.

### `oom_score_adj` is a mitigation, not a replacement

It decides **who dies once the box is already out of memory**. A memory cap makes the
runaway fail inside its own cgroup, where nothing else notices. Everything between "started
allocating" and "OOM killer fires" is thrashing and swap — which is where Immich's latency
goes and where Postgres starts timing out — and the kernel's victim choice is a heuristic.
It protects survival, not service. `two` already uses it correctly, pinning `cloudflared`
to −1000 to keep the only way in alive; that is the job it is good at.

**The better answer is the work already in flight.** `or3-dev` carries
`mem_limit: 1536m` precisely so a build cannot reap Immich. Move the dev containers to a
host that is not serving Immich — Phase 5 — and the constraint disappears without any
cgroup configuration at all. Mobility solves this more cleanly than delegation would.

### `bin/compose` goes, at Phase 3 — DECIDED

**Done 2026-10-25.** `bin/compose` is deleted, `recovery.md` brings deployments back with
stock `sudo docker compose up -d` in each deployment's directory, and `send2ereader` is
the second deployment a play starts (`server-deploy-send2ereader.yml`, since deleted, 2026-10-26).

Ansible drives deployments through `community.docker`, and `bin/compose` is deleted rather
than wrapped. An earlier draft here said the opposite — that the playbook should call
`bin/compose` so "how a deployment is driven" had one spelling — and that was the wrong
read of which spelling is worth keeping.

**The deciding argument is that stock tooling is knowledge that transfers.** `docker
compose --project-directory … -f …` is longer to type than `bin/compose immich up -d`, and
it is known to every operator, every agent and every search result in the world.
`bin/compose` is known to this repository. On the box you reach at 3am from a ship link,
the command that needs no local knowledge is worth more than the one that is short.

What it did turns out to be covered already, which is why this is cheap:

- **`--project-directory` pinning** was belt-and-braces. `hosts/<host>/<name>` is a
  symlink to the same directory, so `.env` is literally the same file, and the project
  name cannot drift because *every compose file declares `name:`* — a repo invariant that
  predates the wrapper.
- **Refusing `destiny-director` by name** is error-message quality, not a guard. That
  deployment interpolates variables that exist only on `two`, so running it elsewhere
  fails regardless — just less legibly.

**The work is not the deletion.** It is rewriting [`recovery.md`](recovery.md)'s bring-back
commands in the same commit, so the document read when a box has rebooted never names a
script that no longer exists. Do both together or neither.

### Phase 3 also moves `send2ereader`'s connector into the deployment — DECIDED 2026-08-24

⚠︎ **The open question below — sidecar or baked-in — was settled on 2026-10-24, and not
here:** `calibre-web` was built with a sidecar first, as a new deployment with nothing to
move. [`decisions.md`](decisions.md) § *Sidecar, not baked-in* has the pattern;
`send2ereader` follows it, and the rest of this section stands.

Phase 3 was "adopt a deployment". It now also carries **phase 5's mechanism**, on the
deployment being adopted: `send2ereader` gets its own `cloudflared` inside its compose
project instead of being served by `one`'s host tunnel.

**What it actually removes is the published port, and that is the reason to do it.**
Today `bookit.gsrpi.uk` is a rule in
[`hosts/one/system/cloudflared-config.yml`](../hosts/one/system/cloudflared-config.yml)
pointing at `http://127.0.0.1:3001`, and `deployments/send2ereader/compose.yaml` publishes
`3001:3001` *only* so the host tunnel can reach it. A connector on the compose network
reaches `send2ereader:3001` directly, so the ingress rule comes out of the host file and
the port publication goes with it — the service stops listening on `one` at all. Moving
the connector without deleting the port would be motion for its own sake.

**It is done here because this is the cheapest place to be wrong.** The mechanism has one
precedent, `infra-dev`, which is a dev container holding a live agent session — breaking it
costs the session that would be fixing it. `send2ereader` is a disposable deployment on
the non-critical box, and its outage is a book that arrives later. Phase 5 then converts
the dev containers against a pattern that has already run somewhere.

**The shape is the open question, and `infra-dev` does not answer it.** `infra-dev` runs
`cloudflared` inside its *own* image, started from its entrypoint — available to it because
the base image is ours to build. An upstream application image is not, so `send2ereader`
wants a second service in the compose project instead. Sidecar versus baked-in is the first
thing to settle in phase 3, and it is a pattern decision for every deployment after it,
not a detail of this one.

**The connector moved on its own, on 2026-10-25, by the owner's call.** This section
used to put it in the same commit as `bin/compose`'s deletion and `recovery.md`'s rewrite.
That pairing exists so `recovery.md` never names a script that is gone, and the sidecar
does not change whether `bin/compose` exists. So the connector did not need to wait. The
deletion and the rewrite went together, in one commit, the same day.

### What `one` must answer before `zero` is considered

Two questions, and they are why the test happens on the disposable box:

- **Can an existing Postgres data directory be adopted, or does it need a dump and
  restore?** That is the difference between a migration and a maintenance window on the
  critical, remote box.
- **Does `--userns=keep-id` map correctly onto the `/media` bind mounts, or does ownership
  on disk have to change?** If ownership must change, that is a change to the data itself,
  not merely to how it is served.

A throwaway Immich on `one` answers both and risks nothing.

## Decision reversals this requires — record in `decisions.md`

Two entries change. Neither is a small edit and both should carry their reason.

1. **"Fleet work is done *on* the box it concerns"** gains an exception for Ansible, with
   the distinction spelled out: the rule's reason is about a tool reading *local* state and
   mislabelling it, which Ansible does not do. `check-system-drift` and `hw-inventory` keep
   the rule in full.
2. **openSUSE MicroOS as the target for `one` and `zero`** (roadmap §3) is deferred, not
   abandoned — the fleet stays on Alpine for now. **The honest reason must be recorded**:
   not "Quadlet leaves out `two`", which stops being true the moment the bot leaves `two`,
   but that the management plane is being built on Alpine today and an OS migration is a
   separate change with its own risks. MicroOS's actual argument — an immutable root with
   automatic rollback on a failed boot, on a box you cannot physically reach for months —
   is untouched by anything here and should not be quietly lost.

`decisions.md`'s **"Claude dev containers stay in their own app repos"** is *not* reversed.
It gains a sentence saying where they are now recorded.

## A principle to apply more widely, later

**Prefer the interface an outsider already knows over the one this repo invented.** It is
why `bin/compose` went at Phase 3, why the hand-rolled `apk` loop went, and — the owner's
own example — why `make` carries so much of the project management in these repos instead
of bespoke scripts. A `Makefile` is an interface every developer and every agent can read
on sight; a script in `bin/` is knowledge that exists only here, and has to be learned
before anything can be done with it.

Not a sweep to run now, and deliberately not scoped: `bin/` currently holds
`check-sources`, `check-system-drift`, `check-boot-layout`, `check-mount-guards`,
`hw-inventory` and `install-system-file`, and several of those earn their place by doing
something no standard tool does. The rule is not "delete scripts", it is "when a standard
tool would do, the standard tool wins, even when it is more to type". Applying it host by
host is a later pass with its own review.

## OPEN — do not resolve these by implementing

1. ✔ **DECIDED 2026-10-25 (owner): a moved dev container carries its history** — the whole
   credential volume moves, not only the login. The cost is accepted: every move copies the
   growing pile through a staging path, so that path is a disclosure surface and must fail the
   run if its permission step fails (*Two findings worth keeping* above). The original
   question follows.

   **Does a moved dev container carry its history, or start clean with only the login?**
   22 MB of transcripts and uploads per move, growing without bound, versus a seamless
   move. "Login only, history stays put" is cheap and keeps transcripts on one box;
   "carry everything" is seamless and drags a growing pile around the fleet. This is a
   decision, not a detail.
2. **Where `destiny-director` lands when it leaves `two`, and who builds its arm64
   images**: moved to
   [gsfernandes81/infra#11](https://github.com/gsfernandes81/infra/issues/11) with Phase
   6, 2026-10-25.
3. ✔ **MOOT, the owner's call 2026-10-25:** if a moved container's Claude Code login ever stops
   working, re-logging in is an acceptable cost, and a move between the three Pis does not
   change the public IP anyway. The original question follows.

   **Does the auth server mind a changed source IP?** Untested. Client-side there is
   nothing to mind and a home IP changes anyway, so this is judged low risk — but it is
   assumed, not established, and the two-host half of the experiment would settle it.

## Before any of this is trusted

- **Calibrate every check against known-good state first**, per `CLAUDE.md`, and record the
  calibration. The credential experiment above is the argument for that rule, not an
  illustration of it.
- **A dry run that changes nothing is the first deliverable**, not the last. Ansible's
  `--check` against all three hosts, reporting drift only, is what proves the inventory is
  right before anything writes.
- **The drift listed at the top of this document is fixed**: its rows carry their
  closures, Phase 2 landed on 2026-08-21, and the two dead links it named are gone. It
  stays there as evidence, not a changelog.
