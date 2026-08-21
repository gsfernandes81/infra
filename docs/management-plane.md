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
- **`bin/compose` stays docker-only and stays refusing `destiny-director` by name.**

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
| ionic-traces | `one` | **yes** | habit |
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
published on a host, so nothing collides. Until then, and for the pinned stacks, the
allocation is: `zero` — 2283 Immich, 8384/22000 Syncthing, **2222 `dd-dev`, 2223 `ds-dev`,
2224 `or3-dev`**; `one` — 8080 qBittorrent, 7777 ionic-traces, 3001 send2ereader,
8384/22000 Syncthing; `two` — none published.

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
| 1 | Read-only audit playbook | nothing | 0 | written, **not yet run against a host** |
| 2 | `README.md` + `recovery.md` cite the generated inventory | docs only | 1 | |
| 3 | First stack adopted: `send2ereader` on `one` | one stack, non-critical box | 2 | |
| 4 | Vault: `send2ereader`, then `ionic-traces` | secrets for two stacks | 3 | |
| 5 | Mobile workloads — dev containers + in-container `cloudflared` | `zero` | 4, OPEN 1 & 3 | |
| 6 | `dd` off `two` | `two`, `one` | arm64 CI, upstream | |
| 7 | **Rootless podman on `one`** — roadmap §2 | `one` | 3 | |
| 8 | `two` as the scheduled read-only control node | `two` | 6, 7 | |

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
