# Handoff — 2026-08-24, after the 2c–2h sweep

## Read this, report state, then STOP

Per the standing convention: say where things stand, give your view of what is worth
doing next, and wait for the owner to pick. No edits, no commits, no playbook runs
until then. Handoff notes are deleted once their open items close; nothing here is the
only record of anything — the phase table in
[`../management-plane.md`](../management-plane.md) § *Sequencing* is the durable one.

## The base image, and what is verified about it

The rebuild happened on 2026-08-24 and `infra-dev` runs
`ghcr.io/gsfernandes81/gsrpi-dev-base:2026.08.24`. Checked from inside that session:
abduco, gh, screen, claude, cloudflared and `in-workspace` all answer, and the three
collections match `ansible/requirements.yml`. **`make verify` from the host is still
worth running** — it covers the docker-side state and the fleet hop, which cannot be
seen from in here.

~~**The pin has since moved to `2026.08.24.1` and nothing is running it yet.**~~
**Overtaken 2026-08-24 17:14**: the workflow was dispatched, `2026.08.24.1` is on ghcr
(`sha256:400a4873…`, arm64 + amd64), and infra-dev and or3-dev both run it. The pin has
since moved again — to `2026.08.24.2`, for the `child-init.sh` seam dd-dev and ds-dev
needed — and *that* tag is the one not built yet. Same two owner-fired steps as before:
`gh workflow run dev-base.yml`, then a rebuild per repo, each dropping that container's
sessions. The phase table's 2d row is the durable record.

## The status board is a live artifact

https://claude.ai/code/artifact/0133f388-9fd7-4392-8d2c-0e1b18610784

Eighteen phases, grouped done / in flight / open / gated, each appearing exactly once. Update it IN PLACE by
passing that URL as `url` to the Artifact tool — publishing without `url` creates a
second artifact and orphans this one. It was current as of 2d's CI landing; if the
phase table has moved since, the board is what drifted.

## Where things stand (2026-08-24)

Done and verified this sweep: **2c** (SP900 pulled, unattended boot proven, mount
guards' first live firing — zero bytes lost), **2e** (zero rotated; one's credential
voided by tunnel retirement), **2f** (cloudflared logs on all three, first time since
December), **2g on one and zero** (locally-managed tunnels, routes in git, old tunnels
deleted), **2h** (staggered autoupdate live: one 6h → two 72h → zero 240h), and
**2d's infra side** (base image + CI + ghcr; other repos not converted).

Also: the ssh mesh (any box through any other, `ProxyJump`, `PermitOpen`-scoped), both
client ssh configs ansible-managed, `system-files.yml` as the fleet deploy path with
the reviewed-commit assert, and a 16-finding adversarial review of all of it applied.

## Open, in the order the owner ranked them

1. **`two`'s 2g, ~a week out (from 2026-08-23).** The rehearsal plan is written in the
   2g entry: `./2g new two` run for real IS the rehearsal (--check structurally cannot
   be), the originRequest assert is checking the one tunnel nobody has inspected, and
   the cutover must arrive over the mesh (`./2g cut two` picks `two-zero` itself).
   Two hostnames. Retiring the old tunnel kills `two`'s inline-token exposure — the
   last disclosed credential on the fleet.
2. **Cloudflare dashboard tidy** — orphaned Access service tokens and applications
   from the 2026-08-22 failed runs. Manual, five minutes, `docs/cloudflare.md` § *Safe
   to delete* is the list. The owner deferred it twice; do not nag, do not do it for
   him (it needs judgement about which token the phone holds).
3. **The Access decision** — fleet ssh hostnames rely on browser JWTs that expire
   (`ssh zero` broke once already). A service token would end that. A decision, not a
   task; raise it when tunnels come up anyway.
4. **Phase 3** — `send2ereader` adopted, `bin/compose` retired. The front of the
   original queue. Its public name is `bookit.gsrpi.uk`.
5. **or3-dev's conversion is done and merged** (2026-08-24, `cca66fd`) — but the image
   is not built and no container runs it yet: `dev-base.yml` is dispatch-only. See 2d.
   Still parked: `dd`/`ds` conversions (each drops that repo's sessions); the
   workflow's Node-20 action bumps
   (cosmetic until GitHub hard-cuts); uptime monitoring (`ping.<host>.gsrpi.uk` was
   floated — it would let the gated cloudflared-update play replace the stagger).

## What will bite you if you skip the reading

- `~/.claude/.../memory/` has the operational rules: command formatting for the
  owner's phone, `infra-dev` cannot reach the fleet, cloudflared ignores local ingress
  on remotely-managed tunnels, handoffs mean stop.
- `CLAUDE.md` grew entries this sweep: write-the-address-not-the-name, the defused
  smartd landmine, mount guards live on both hosts.
- Cycling any cloudflared: stop, poll 20241 free, start. Never `rc-service restart`,
  never from a session that arrived through the tunnel being cycled. Two outages
  taught this; the playbooks now refuse, paste blocks cannot.
