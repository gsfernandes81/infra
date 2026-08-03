# Brief: bring `zero` into this repo

Temporary. Delete this file when `zero` is onboarded.

You are doing for `zero` what was already done for `one`. Read the repo root
`README.md`, `docs/decisions.md` and `CLAUDE.md` first — they carry the conventions
and the working agreement, and are not repeated here.

---

## Hard rules

**1. The two Claude dev containers must NOT restart. Not once, not briefly.**
Not `down`, not `up -d`, not `restart`, not `--force-recreate`, and not as collateral
from `--remove-orphans` or a project rename. **Gavin gives an explicit go-ahead before
any action that touches them.** If a step you want to take would recreate them, stop
and ask instead.

**2. Every container on `zero` is critical, and the box is remote.** Immich (with its
database and machine-learning containers) and Syncthing. There is no "it's only
`one`, downtime is fine" here — that was true on the last host and is not true on this
one. Assume no downtime is authorised until told otherwise, per stack.

**3. Plan first. Change nothing.** Phase 1 is inventory and a written plan for Gavin to
approve. No file moves, no `git init`, no container operations beyond read-only
inspection. Do not start Phase 2 until the plan is approved.

**4. Privileged commands are handed over, never run by you.** Gavin does not use `!`
in-session and is not in the `docker` group. Produce a copy-paste block or a reviewable
script; he runs it and pastes back. Never assume it ran — verify from output.

---

## Phase 1 — what to establish

Read-only. `docker ps`, `docker inspect`, `docker compose config`, reading files.

- **Every container**: name, image, compose project and service label, status,
  `StartedAt`, restart policy, published ports.
- **Which compose files exist and where.** Check whether any declares `name:` — a file
  without one derives its project from the directory, which is how `one` ended up with
  two stacks silently sharing a project. Check for collisions across all files.
- **Every bind mount and named volume**, and what backs it. For Immich specifically:
  where the library actually lives, where the database data directory lives, and
  whether either sits on a removable or late-mounting disk.
- **The bcache topology.** `zero`'s data disk is fronted by an SSD cache, so the real
  device is `/dev/bcache0`, not the disk you might expect from `lsblk` at a glance.
  Record which device is backing and which is cache, and the cache mode
  (`cat /sys/block/bcache0/bcache/cache_mode`). In `writeback` the SSD holds dirty
  blocks that are not yet on the backing disk — it is live data, not a disposable
  accelerator, and that changes what is safe to unplug and what has to be backed up.
- **Secrets**: which `.env` files exist, what keys they hold. Do not print values. On
  `one` there were four secrets and one of them was somewhere nobody expected
  (a plaintext tunnel token in an OpenRC init script).
- **The Claude dev containers**: what they are, what state they hold, what would be
  lost by a restart, and whether anything is uncommitted inside them. This determines
  how carefully the eventual restart has to be sequenced.
- **Boot safety**: `/etc/fstab`, whether the data mounts carry `nofail`, whether
  `/etc/crypttab` or LUKS exist. On Alpine + OpenRC a missing disk is survivable; on
  systemd it is not. See `../../docs/recovery.md`.
- **Nested git checkouts**: branch, clean/dirty, unpushed commits. On `one` one repo
  had an uncommitted Dockerfile fix that the running image had been built from — it
  would have been lost.

## Then

Write a plan covering: proposed layout under `deployments/` and `hosts/zero/`, what
moves versus what is copied, which stacks need a recreate and why, what downtime each
needs, and the verification for each step. Get it approved before touching anything.

---

## Traps that cost real time on `one`

These are specific and they will recur.

- **"Exited" is not "absent".** Two stacks recorded as having no containers actually
  had exited containers and registered compose projects. Deleting their compose files
  would have orphaned them permanently; they needed a real `compose down` first.
- **A check that can pass for the wrong reason is worse than no check.** The
  port-forward verification asked only "did the value change" and passed within seconds
  on an unrelated restart default. Exclude the values a check could trivially match.
- **Diff `docker compose config`, not the files.** Only that proves Compose *parses*
  them identically. Note it interpolates `.env`, so its output contains live secrets —
  `chmod 600`, keep it outside the repo, delete it after.
- **md5 before and after** anything that is supposed to move verbatim.
- **Scan for secrets two ways** before the first commit: by name pattern, and by taking
  each live value out of the gitignored `.env` files and grepping every tracked file
  for it. The second catches what the first cannot.
- **`docker compose config` output is the baseline** — capture it *before* moving
  anything, or you cannot prove the move was clean.

## Trap specific to `zero`

**The empty-directory trap is the one that loses data here.** If a volume fails to
mount, a container bind-mounting that path starts happily against an empty directory
and writes into it. On `zero` that means Immich coming up with a blank library and
beginning to populate it, or Postgres initialising a fresh cluster over nothing.

Establish during inventory whether any Immich mount could fail independently of the
container starting. That answer shapes the whole migration, and it is the reason
`RequiresMountsFor=` is mandatory once these become systemd units.

**Databases are not disposable the way the `one` stacks were.** On `one` every stack
kept its state on bind mounts and containers could be recreated freely. Do not assume
that here until the Immich database's storage is confirmed and a backup exists.

---

## Context

`zero` is a Pi 5 currently on Alpine. The fleet is moving to **openSUSE MicroOS**
(immutable root, btrfs snapshots, auto-rollback) with Podman and Quadlet — but that is
later work, and `one` goes first as the guinea pig. Compose files are distro-agnostic,
so onboarding `zero` now does not commit to anything.

`two` (Pi 1 B+, armv6) stays on Alpine as the lifeboat — serial console, power-cycle,
watchdog and boot-integrity monitoring for the other two.

If `zero` gains an encrypted data volume later, the traps are already written up in
`system/README.md` in this directory — the non-interactive unlock requirement is the
one that could strand the box.
