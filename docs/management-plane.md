# The management plane

> **Status: in progress. Phase 0 done, Phase 1 written and unrun** — see *Sequencing*
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
| `zero` runs `or3-dev` on port 2224 | nowhere in this repo | absent |
| 2222 = `dd-dev`, 2223 = `ds-dev`, 2224 = `or3-dev` | a **comment in or3's `dev/compose.yaml`** | the port registry for `zero` lives in the newest claimant's app repo |
| `zero`'s dev containers | `README.md` says "two" and names `dd-dev`, `dd-mysql`, `ds-dev`; [`recovery.md`](recovery.md) names only `dd-dev` and `dd-mysql` | two records, both wrong, wrong differently |
| `zero` and `two` are onboarded | [`roadmap.md`](roadmap.md) §1 says they "aren't in it yet — only placeholder dirs" | stale; both have symlinks |
| — | `roadmap.md` links `hosts/zero/HANDOFF.md` and `hosts/two/setup/root-setup.sh` | neither file exists |

`recovery.md` is the document you read from a ship link when a box has rebooted, and it
hard-codes both the per-host stack list and the port grep. It is the most-drifted file in
the repo and the one where drift costs most.

Three frictions follow from that one gap, and they are the three that prompted this:

- **Nothing here can name a workload it does not own.** So the only way to make `or3-dev`
  visible in this repo was to move it in — which breaks `make dev` from a fresh or3 clone
  and inverts the dependency. That is a false choice created by the missing record, not a
  real trade.
- **Moving a stack between hosts** is: relink `hosts/<host>/`, recreate `.env` by hand on
  the new box, edit two prose port lines, edit `recovery.md`, and — if the target is `two`
  — discover that `bin/compose` refuses. Nothing checks any of it.
- **Bring-up from nothing** exists as a numbered manual for `two` only.
  [`host-setup.md`](host-setup.md) is explicitly topic-organised, not order-organised, and
  names no per-stack prerequisites — secrets directories, deploy keys, tunnels, or the
  ordering of the mount guards against the first stack start.

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
  **Reversed** — see *`bin/compose` goes, at Phase 3* below. Struck rather than deleted,
  because this list is what the document promises it is not disturbing, and quietly
  dropping a line from it would make the promise unfalsifiable.

## The control plane — DECIDED

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
  today is `bin/compose immich up -d`, a command that works with nothing else running.
  Under Nomad it starts with bootstrapping a control plane, its gossip key and its ACLs,
  before any workload starts, on a box you may be reaching from mid-ocean.
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
`one`", which required reworking every stack from `env_file:` onto mounted secrets and
rendering values into tmpfs. That goal was not the actual requirement, and dropping it
removed all of that work.

The security posture nonetheless improves incidentally, which is worth stating so nobody
later mistakes the simplification for a regression. Today a `.env` exists **only** on the
box: gitignored, so a box loss loses it and nothing records what the value should have
been. Encrypted in a private repo it is versioned, reviewable and recoverable, and the
two-way secret scan ritual in [`../CLAUDE.md`](../CLAUDE.md) retires with it.

**It also dissolves the per-host `.env` problem without a design of its own.** Today
`deployments/<stack>/.env` is one file, so a stack carrying host-specific values cannot be
*defined once* and run on two hosts.

**Nothing exercises this today, and the near-miss is worth stating so it is not
mis-read.** Syncthing runs on both `zero` and `one`, which looks like the case — it is
not. They are two different services that happen to be the same software: `zero`'s
(`deployments/syncthing/`, `syncthing.gsrpi.uk`, `/media/syncthing`) syncs the general
share, and `one`'s (a service inside `deployments/torrents/`, `syncthing-torrents.gsrpi.uk`,
`/media/torrents`) distributes completed torrents. Two definitions because there are two
jobs, not because one definition could not stretch to two hosts.

So the limit is **latent rather than worked around** — no stack in this repo runs on two
hosts at all, and the first one that wants to will meet it. That is exactly the mobility
this document is for, and `host_vars/` / `group_vars/` is what removes it.

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

**Provisioning is a playbook**, `ansible/playbooks/cloudflare-dev-tunnel.yml`, creating
four objects over the Cloudflare API: the tunnel, the CNAME, an Access service token and
an Access application with one policy. It was written as a shell script first and that
was the wrong instinct — the same one that put `bin/compose` in this repo, and the second
time the owner has had to point at it. Being in the plane rather than beside it buys
parsed JSON instead of a hand-rolled extractor, a real `--check`, `no_log` as a mechanism
rather than as discipline, and an API token that becomes a Vault variable at Phase 4 with
no rewrite. It is not a one-off either: three more dev containers want the same four
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

**The loopback publish stays.** Dropping `127.0.0.1:222x` once the tunnel works would
leave `docker exec` on zero — needing sudo, on a box you may be trying to reach because
something is wrong — as the only fallback. The two paths fail independently, which is the
only reason neither is a single point of failure.

**Three secrets, three homes, and the rules are asymmetric.** The API token goes nowhere
— prompted, in memory, for one run — and specifically NOT into the secrets directory,
because that directory is mounted into the container and a container able to rewrite the
Access policy in front of itself is not protected by it. The tunnel credentials are a
read-only file rather than `--token`, which is the containerised form of the rule
restated below. The service token belongs to the phone and must not be in the container,
because it authorises *reaching* the container.

### A control node inside the fleet — OPEN, deliberately

`infra-dev` was being built as a second control node — `ansible-core` and the collections
in the image, an ssh key reaching all three hosts — and that was stepped back from on
2026-08-22 before it was used. **By default the container now has no route to `zero`,
`one` or `two` at all.** It develops this repo; running playbooks against the fleet stays
on the phone. One variable turns it on (`INFRA_DEV_FLEET=1`), off is the default, and the
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

The argument the other way is real and is why this is open rather than closed: **an audit
from Termux is metered end to end to reach boxes sitting on zero's own LAN, and from
inside the container it is free.** That saving recurs every run, and Phase 8's answer to
it — scheduling from `two` — is blocked behind Phase 7's rootless podman.

Three things would change the answer, and it is worth knowing which one you are waiting
for rather than revisiting this on a feeling:

1. **Phase 7 and 8 landing.** If `two` becomes the scheduled read-only control node, the
   metered-audit argument mostly evaporates and this stays off for good.
2. **A read-only split.** The audit needs no `become` on `one` and `two`. A container
   holding a key that can only read, with the mutating half staying on the phone, answers
   the blast-radius objection without giving up the saving. Nothing in the repo does this
   today and `ansible.cfg`'s `become: False` default is the right half of it already.
3. **The dev containers moving hosts** (Phase 5). A control node that follows the
   container to whichever box has room is a different proposition from one pinned to zero,
   and the objection about living inside what it controls stops being a constant.

Until one of those, it is off, and the container is a development container that happens
to have ansible in it for editing playbooks.

### Still to do: the fleet's own tunnels — PLANNED, Phase 2e

`zero`'s and `one`'s tunnel tokens were world-readable in a 755 init script for months and
`recovery.md` says both must be assumed disclosed. Rotation was deferred there to "when
physically present", which from a ship is months away.

**`infra-dev`'s tunnel is what makes that a remote operation.** It is a way into zero that
does not traverse zero's own tunnel, and it holds the fleet key — so the two-phase
procedure in `CLAUDE.md` § *Changing the thing you are connected through* can finally be
satisfied for `zero`: prepare and prove inert from a session that does not cross the
tunnel being restarted, then restart with an end-to-end probe and automatic rollback.

The order, once `infra-dev` has been up long enough to be trusted:

1. ~~`zero`~~ — **done 2026-08-23**, but not the way this said. The session was held on
   the **`two` bastion**, not inside `infra-dev`: that container has no route to zero at
   all (no fleet key, no `ssh_config.fleet`, `INFRA_DEV_FLEET` unset), so it is a safe
   place to stand and a useless place to work from. The claim above that it "holds the
   fleet key" was wrong. `/ready` also turned out to be insufficient alone — see
   `recovery.md`.
2. `one` — same, with the session held on **`one` reached by a jump from `two`**.
   An earlier draft said "held on `zero` over the LAN", which cannot be done:
   `recovery.md` documents that LAN path in the other direction (`one` → `zero`), and
   `decisions.md` refuses a key on `zero` authorising it to reach `one` at all. `two` is
   the bastion for both boxes — the lifeboat direction, which is the one that entry
   blesses. Confirmed reachable 2026-08-23.
3. `two` — check first whether the token is even still inline: `recovery.md` says
   "check before assuming" and nobody has.

Not started, and deliberately not bundled with the dev container work: it is churn on the
boxes you are connected through, and the whole point of doing `infra-dev` first is to
have somewhere safe to stand while doing it.

**Two things travel with this decision.** A tunnel token per dev container — a secret,
which is what the Vault path above is for. And
[`host-setup.md`](host-setup.md)'s **token-in-argv leak**, flagged there as applied on no
host: `supervise-daemon` logs its child's full command line to syslog, so a live tunnel
token sits in `/var/log/messages` at mode 640 `root:wheel`. More tunnels means more
instances of it, so it stops being deferrable. **Rule, restated: secrets never go in
`command_args`.**

## Placement — what can move and what cannot

| Workload | Host | Mobile? | Pinned by |
|---|---|---|---|
| Immich (+ db, ml, redis) | `zero` | no | the bcache-fronted btrfs array |
| Syncthing | `zero`, `one` | no | the data it syncs |
| torrents (gluetun + qBittorrent) | `one` | no | `/dev/net/tun`, shared network namespace |
| ionic-traces (**stopped** — see 2c) | `one` | **yes** | habit |
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

**Ports stop being a registry problem** once addressing is by tunnel hostname: nothing is
published on a host, so nothing collides. That is the destination, not the present — every
dev container still publishes an sshd on zero's loopback, and each one's `<alias>-lan` is
the break-glass path that reaches it. The allocation is: `zero` — 2283 Immich, 8384/22000
Syncthing, **2222 `dd-dev`, 2223 `ds-dev`, 2224 `or3-dev`, 2225 `infra-dev`**; `one` — 8080
qBittorrent, ~~7777 ionic-traces~~ (stopped, 2c), 3001 send2ereader, 8384/22000 Syncthing;
`two` — none published.

**Since 2026-08-28 that list is a copy, not the record.** The registry is the table in
[`../ansible/playbooks/this-client.yml`](../ansible/playbooks/this-client.yml), which is
the file that *consumes* the numbers — every `<alias>-lan` block written onto every client
is built from them, so a wrong one is noticed the next time somebody uses the rescue path
rather than the next time somebody reads a comment. This closes the drift row at the top
of this document, whose worked example was exactly these ports living in or3's compose
file where nothing here could contradict them. **2225 was missing from this paragraph
until the registry moved** — which is the argument, made by the paragraph itself.

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
surface, and nothing prunes it. See OPEN 1.

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

## Sequencing, and where podman fits

Ordered by risk, not by appeal. **Phases 0–2 change nothing on any host**, and they are the
ones that answer the question this document started from.

| # | Phase | Touches | Gated on | State |
|---|---|---|---|---|
| 0 | Control node on Termux, inventory, `ansible fleet -m ping` | nothing | — | **done** 2026-08-21 |
| 1 | Read-only audit playbook | nothing | 0 | **done** 2026-08-21 — run against all three; `docs/fleet-inventory.md` is generated and committed |
| 1b | Fleet package standardisation — `playbooks/packages.yml` | all three | 1 | **done** 2026-08-21 |
| 2 | `README.md` + `recovery.md` cite the generated inventory | docs only | 1 | **done** 2026-08-21 |
| 2b | `infra-dev` container, and the Cloudflare edge in front of it | `zero`, edge | 2 | **done** 2026-08-22 |
| 2c | `one`'s array — both "broken services" were the SP900 in bay 0 | `one`'s enclosure | — | **done 2026-08-24** — disk pulled, unattended boot proven |
| 2d | One base image for the four dev containers — `dev/README.md` § *Four copies of this* | `zero`'s dev containers | 2b | **All four converted, and `2026.08.25` is built** (2026-08-25, `sha256:f25cb8de…`, arm64 + amd64, from `2f05f2e`). That tag is the one with **no remote control anywhere** — every container is ssh + abduco, the supervisors deleted — and with `offload-idle-claude.sh`, which stops a detached idle claude and leaves it resumable; one held 1,146 MB. **Nothing runs it yet**: `make up` here, `make dev-up` in destiny-director and dossier, `make up` in or3, each dropping that container's sessions |
| 2e | Rotate the fleet's own tunnel tokens | `zero`, `one`, `two`, edge | 2b | **`zero` and `one` done 2026-08-23** — one's by retiring its tunnel under 2g. **`two`'s half is no longer a task of its own**: it is folded into 2g, which voids that token rather than rotating it |
| 2f | `cloudflared`'s init script logs nowhere | `zero`, `one`, `two` | — | **done on all three, 2026-08-23** |
| 2g | All three tunnels become locally-managed — new tunnels, ingress in git | `zero`, `one`, `two`, DNS | 2f | `one` and `zero` **done 2026-08-23**; **`two` deferred ~a week, and on `two` it is one job with 2e and the dashboard sweep** |
| 2h | cloudflared: staggered autoupdate, `one` 6h → `two` 72h → `zero` 240h | all three | — | **done 2026-08-24** — the staggered frequencies are installed and live on all three |
| 2i | Retire the `ssh-zero-dev-*` rules — each dev container's second, unprotected door | `zero`'s host tunnel, DNS | nothing | **or3's ingress rule is gone** (`7bb2075`, 2026-08-24); its CNAME and whether the connector was cycled are **unverified — nothing tracked records either**. `ssh-zero-dev-dd` and `ssh-zero-dev-ds` rules are **still live** in `hosts/zero/system/cloudflared-config.yml`, and now that every container has its own tunnel they are second doors on the same argument. Client-side all three aliases are gone from `ssh-fleet-block.j2` (2026-08-28): `dd-dev` and `ds-dev` are not running until they are deployed with a connector of their own, so an alias for the old door would name a hostname with nothing behind it. Dropping an alias does not close a door — the rules are still on zero, and this row is what closes them |
| 3 | First stack adopted: `send2ereader` on `one`, **with its connector in the stack** | one stack, non-critical box, `one`'s ingress | 2 | |
| 4 | Vault: `send2ereader`, then `ionic-traces` — second target now questionable, see 2c | secrets for two stacks | 3 | |
| 5 | Mobile workloads — dev containers + in-container `cloudflared` | `zero` | 4, OPEN 1 & 3 | Phase 3 now tests the mechanism first, on a disposable stack |
| 6 | `dd` off `two` | `two`, `one` | arm64 CI, upstream | |
| 7 | **Rootless podman on `one`** — roadmap §2 | `one` | 3 | |
| 8 | `two` as the scheduled read-only control node | `two` | 6, 7 | |

**Closed 2026-08-28 — one command now writes every ssh block this repo owns.**
`playbooks/this-client.yml` composes `ssh-client.yml` with one `dev-client.yml` import per
dev container, and carries the registry that says which containers exist, on which ports,
behind which hostnames. It runs on the phone and in WSL, writes both sides of the laptop
from the latter, and takes `-e prompt_for_token=false` so a container whose tunnel is not
provisioned yet is skipped by name instead of stopping the run with a prompt for a
credential nobody can produce.

Both clients are done. The phone and the laptop each ran their reorder and both one-shot
scripts are deleted, per this repo's rule that they go once they have run. What the laptop
found on the way is worth more than the scripts were: the Windows ProxyCommand wrapper was
unusable because cmd.exe miscounts byte offsets in an LF-only batch file; `IdentitiesOnly`
alongside an `IdentityFile` that does not exist gives `Permission denied (publickey)` on a
client whose key lives in an agent; and `authorize-dev-client.yml` exists at all because
the key that admits a client is a fact about the container, not something the client holds.
All three are in [`decisions.md`](decisions.md) and [`ssh-clients.md`](ssh-clients.md).

**Still open, and not this phase's:** `dd-dev` and `ds-dev` have no tunnel of their own, so
`this-client.yml` skips them by name until Phase 5; and 2i's rules are still live on zero.

**Filed 2026-08-25, no phase number — the two client plays now cover Windows, and the
phone's own block is behind them.** `dev-client.yml` had no Windows half at all: run from
WSL it configured WSL and left Windows untouched, which is why a laptop that reaches
`zero` from PowerShell could not reach `infra-dev` from anywhere. It now writes both sides
of the laptop in one WSL run, and both client plays refuse to run with no inventory rather
than exiting 0 with an empty recap. Two things this turned up on the **live phone**, which
the repo cannot fix for it:

- Its `infra-dev` block still carries a **bare** `cloudflared` in the `ProxyCommand` — the
  output of the pre-2026-08-24 `| default('cloudflared', true)`, and the exact bug that
  fix existed to remove. A bare name resolves in an interactive shell and then fails
  inside ssh's `/bin/sh`, presenting as the tunnel being down. Re-running the play rewrites
  the block in place with the absolute path and does not ask for the token again.
- `Host or3-dev` is defined **twice** — the managed block at the top of the file and a
  hand-written `nc`-through-zero block below it. First-value-wins gives
  `HostName or3-dev.gsrpi.uk` from the first and `Port 2224` from the second (confirmed
  with `ssh -G`). Inert while the ProxyCommand is `cloudflared access ssh --hostname %h`,
  which ignores the port — and a live trap the moment it is not. The hand-written block is
  fully superseded and should be deleted.

**2b–2e were off this list until 2026-08-22.** They come out of the `infra-dev` handoff.
As filed, two of them outranked Phase 3: `one`'s broken services were the only things on
the fleet *failing* rather than merely unbuilt, and Phase 3 adopts a stack that currently
works. **2c has since gone the other way** — it was diagnosed on 2026-08-23 and is blocked
on physical access, so it can no longer be ranked at all; see below. The rotation still
outranks Phase 3, because the reason it was deferred, "when physically present", stopped
being true the day `infra-dev` came up. 2d was ranked as maintenance cost rather than
risk, to wait for whichever of the four images next needed a change; it was built on
2026-08-24 instead.

**Which left 2e and Phase 3 as the next actionable work**, in that order. As of 2026-08-24
both have moved: 2e's last host is inside 2g on `two` (below), so the next actionable work
is **`two`'s tunnel, then Phase 3**.

**2g, filed 2026-08-23 — DECIDED, not optional-but-nice.** The owner's reason, and it is
the deciding one: *"I'm not interested in leaving more config than I have to in a web
dashboard."* That is the same argument as everything else in this document — routes that
can be reviewed, diffed and recovered from git rather than clicked into a UI nobody can
audit. It is not fixing a fault; zero's actual security problem was closed by 2e.

**It cannot be done in place.** `config_src` is create-time only (see
[`cloudflare.md`](cloudflare.md)), so each host gets a **new** tunnel created with
`config_src: local`, and its CNAMEs are repointed to the new UUID.

**For `one`, this absorbs 2e entirely.** A new tunnel arrives with fresh credentials in a
credentials file and no token in argv, so both phases are satisfied by construction — and
retiring the old tunnel is *stronger* than rotating its secret, because deleting a tunnel
kills the disclosed credential outright rather than superseding it. Do not run 2e's two
phases on `one` first; that work would be thrown away.

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
three eventually). `playbooks/cloudflared-update.yml` — explicit, hash-verified, each
stage refusing while an earlier one is unhealthy — exists and is not used; **revisit once
uptime monitoring exists**, e.g. `ping.<host>.gsrpi.uk`, because a gate is only worth
building when something can tell you a host is down, and today nothing can.

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
`DEV_TUNNEL_HOSTNAME` is set **and** a credentials file exists, so an unset hostname means
no second door. The window therefore opens when the owner sets that variable, which is a
knob he holds rather than a consequence he inherits.

**So do this first and there is no window.** Retiring the rule early costs nothing,
because the break-glass path does not use the tunnel: `dev-client.yml` writes
`<alias>-lan` as `ProxyCommand ssh zero nc %h %p`, which reaches `127.0.0.1:2224` through
**zero's sshd**, and that is the same origin the ingress rule points at. Dropping the
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
`config_src: local`, with their routes in `hosts/<host>/system/cloudflared-config.yml`
and their old tunnels deleted. Retiring `one`'s old tunnel is what finally voided its
disclosed credential, so 2e closed for that host as a side effect rather than as a
rotation.

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

`two` is deferred about a week, deliberately. Two hostnames, the smallest job, on the box
with the least margin and no bastion of its own.

**On `two` this is one job with 2e and the Cloudflare dashboard sweep, decided 2026-08-24.**
Not three items that happen to be adjacent — three that close each other, in the order they
already have to run. The new tunnel arrives with credentials in a 0600 file, so 2e is
satisfied by *construction* rather than performed; deleting the old tunnel then **voids**
the token still inline in `two`'s 755 init script, which is stronger than rotating it and is
the last disclosed credential on the fleet. The orphaned Access service tokens and
applications left by the failed runs of 2026-08-22 are objects on the same tunnel and the
same dashboard visit — [`cloudflare.md`](cloudflare.md) § *Safe to delete* is the list.
Tracking them apart invites the half-done state this repo keeps meeting: a tunnel migrated
and its old credential still live somewhere nobody swept.

**The sweep stays a human step inside that job.** It needs judgement about which token the
phone currently holds, and that is not a fact any check on a box can establish.

**When it happens, phase 1 run for real IS the rehearsal.** All three plays were
substantially rewritten in the 2026-08-24 review (block/rescue rollbacks, the
originRequest assert, the re-run guard) and have not run since. A `--check` of phase 1
cannot rehearse them — the `uri` create is skipped in check mode and everything after it
dies on undefined, the exact bootstrap trap `cloudflare-dev-tunnel.yml`'s header
documents. But phase 1 for real is inherently consequence-free: it creates a tunnel
nothing points at, abandoned by one delete. Running it against `two` exercises the new
guards — and the originRequest assert is checking the one tunnel nobody has ever
inspected, so if it fires, it fired before anything moved. Read the generated config at
leisure; phase 2 (`./2g cut two`, which picks the `two-zero` mesh path) is a separate
decision on a separate day if wanted. **Reach `two` over the mesh for phase 2** — its
tunnel is the thing being cycled, which is how it went dark once already.

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

**`two` still needs it, and it needs it more.** An earlier version of this entry said two
could be skipped because 2g replaces its tunnel wholesale. That is the same reasoning that
would have skipped `one` — where doing it first is what made zero's diagnosis possible an
hour later. Two's 2g is last of the three, so skipping means the lifeboat logs nothing for
however long that takes.

Two is not a copy-paste of the other two: it runs no docker, so
`/etc/init.d/docker` is not there to model on, and whether `log_proxy` exists at all needs
checking before assuming the same block works. It also tracks no `/etc` files yet, so this
would be the first — which pulls in the `python3`-for-`check-system-drift` question.

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

**Phase 7 moved.** Rootless podman was going to be a follow-on; it is a **precondition of
Phase 8**, because `podman ps` as the connecting user needs no sudo. The audit playbook
takes `-K` today only because `gavin` is not in the `docker` group and NOPASSWD sudo is
refused, and a scheduled run cannot type a password. `decisions.md` said this in one line
long before Ansible existed here: *"`gavin` not in `docker` group | Root-equivalent.
**Rootless Podman removes the need.**"*

**But it only removes it for `one`.** `zero` keeps needing sudo until MicroOS — see the
table below — so Phase 8 starts out able to audit `one` unprivileged and `zero` not at all
on a schedule. That is a partial unblock, and calling it a full one is the mistake to
avoid.

`one` first is also roadmap §2's own answer, for its own reason: it is the non-critical
box, its stacks are disposable, and it is where the `bin/compose` docker-vs-podman-compose
question finally gets tested against something real.

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
  netstat branch in `audit.yml` existed because `ss` was on one host out of three, and
  `one`'s `hardware.md` looked hand-edited because `usbutils` was on two out of three.
  Both are gone, and the fallbacks stay: a host built tomorrow has not run
  `packages.yml` yet.

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

Ansible drives stacks through `community.docker`, and `bin/compose` is deleted rather than
wrapped. An earlier draft here said the opposite — that the playbook should call
`bin/compose` so "how a stack is driven" had one spelling — and that was the wrong read of
which spelling is worth keeping.

**The deciding argument is that stock tooling is knowledge that transfers.** `docker
compose --project-directory … -f …` is longer to type than `bin/compose immich up -d`, and
it is known to every operator, every agent and every search result in the world.
`bin/compose` is known to this repository. On the box you reach at 3am from a ship link,
the command that needs no local knowledge is worth more than the one that is short.

What it did turns out to be covered already, which is why this is cheap:

- **`--project-directory` pinning** was belt-and-braces. `hosts/<host>/<stack>` is a
  symlink to the same directory, so `.env` is literally the same file, and the project
  name cannot drift because *every compose file declares `name:`* — a repo invariant that
  predates the wrapper.
- **Refusing `destiny-director` by name** is error-message quality, not a guard. That
  stack interpolates variables that exist only on `two`, so running it elsewhere fails
  regardless — just less legibly.

**The work is not the deletion.** It is rewriting [`recovery.md`](recovery.md)'s bring-back
commands in the same commit, so the document read when a box has rebooted never names a
script that no longer exists. Do both together or neither.

### Phase 3 also moves `send2ereader`'s connector into the stack — DECIDED 2026-08-24

Phase 3 was "adopt a stack". It now also carries **phase 5's mechanism**, on the stack
being adopted: `send2ereader` gets its own `cloudflared` inside its compose project
instead of being served by `one`'s host tunnel.

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
costs the session that would be fixing it. `send2ereader` is a disposable stack on the
non-critical box, and its outage is a book that arrives later. Phase 5 then converts the
dev containers against a pattern that has already run somewhere.

**The shape is the open question, and `infra-dev` does not answer it.** `infra-dev` runs
`cloudflared` inside its *own* image, started from its entrypoint — available to it because
the base image is ours to build. An upstream application image is not, so `send2ereader`
wants a second service in the compose project instead. Sidecar versus baked-in is the first
thing to settle in phase 3, and it is a pattern decision for every stack after it, not a
detail of this one.

**What does not change:** `bin/compose` still goes at Phase 3, and `recovery.md` is still
rewritten in the same commit. The connector adds a third thing to that commit — `one`'s
tracked ingress loses a rule — and the same rule applies to it: all of it together, or
none of it.

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
why `bin/compose` goes at Phase 3, why the hand-rolled `apk` loop went, and — the owner's
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

1. **Does a moved dev container carry its history, or start clean with only the login?**
   22 MB of transcripts and uploads per move, growing without bound, versus a seamless
   move. "Login only, history stays put" is cheap and keeps transcripts on one box;
   "carry everything" is seamless and drags a growing pile around the fleet. This is a
   decision, not a detail.
2. **Where does `destiny-director` land when it leaves `two`, and who builds its arm64
   images?** Its CI builds `linux/arm/v6` today. `one` or `zero` both work; the image build
   is an upstream change in that repo, not here.
3. **Does the auth server mind a changed source IP?** Untested. Client-side there is
   nothing to mind and a home IP changes anyway, so this is judged low risk — but it is
   assumed, not established, and the two-host half of the experiment would settle it.

## Before any of this is trusted

- **Calibrate every check against known-good state first**, per `CLAUDE.md`, and record the
  calibration. The credential experiment above is the argument for that rule, not an
  illustration of it.
- **A dry run that changes nothing is the first deliverable**, not the last. Ansible's
  `--check` against all three hosts, reporting drift only, is what proves the inventory is
  right before anything writes.
- **The drift listed at the top of this document is not yet fixed.** It is evidence here,
  not a changelog. Fixing it — the port line, the dev-container count, `recovery.md`'s
  stack lists and port greps, roadmap §1's stale paragraph and its two dead links, and the
  missing `hosts/one/syncthing` symlink — is its own commit, and should happen whether or
  not this proposal is accepted.
