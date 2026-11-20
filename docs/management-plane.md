# The management plane

> The phase table below is the record of what is done and what is next; the open items
> under it are everything filed without a phase. **Done work is struck through**: a
> struck row says when, and where its record now lives. Settled reasoning is in
> [`decisions.md`](decisions.md). The text before the 2026-11-20 tidy is at commit `970cbd2`.

## Phases

Done phases keep their labels and are ordered by date. Future phases are numbered in the
order they run.

| # | Phase | Touches | Waits on | State |
|---|---|---|---|---|
| ~~0~~ | ~~Control node on Termux, inventory, `ansible fleet -m ping`~~ | | | done 2026-08-21 → [`ansible/README.md`](../ansible/README.md) |
| ~~1~~ | ~~Read-only fleet inventory, `server-generate-fleet-inventory.yml`~~ | | | done 2026-08-21 → [`fleet-inventory.md`](fleet-inventory.md) |
| ~~1b~~ | ~~Fleet packages standardised, `server-install-packages.yml`~~ | | | done 2026-08-21 → the play |
| ~~2~~ | ~~README and `recovery.md` cite the generated inventory~~ | | | done 2026-08-21 → [`history/2026-08-phase-1-2-plan.md`](history/2026-08-phase-1-2-plan.md) |
| ~~2b~~ | ~~`infra-dev` and the Cloudflare edge in front of it~~ | | | done 2026-08-22 → [`dev/README.md`](../dev/README.md) |
| ~~2f~~ | ~~`cloudflared`'s init script logs somewhere~~ | | | done 2026-08-23 → the headers of `hosts/*/system/cloudflared` |
| ~~2c~~ | ~~`one`'s array: both "broken services" were the SP900, pulled~~ | | | done 2026-08-24 → CLAUDE.md § *Mount guards*; `decisions.md` § *From the management plane* (`ionic-traces` stays down) |
| ~~2h~~ | ~~`cloudflared` autoupdate staggered: `one` 6 h, `two` 72 h, `zero` 240 h~~ | | | done 2026-08-24 → `hosts/*/system/cloudflared`; `decisions.md` § *One cloudflared build on all three* |
| ~~2d~~ | ~~One base image for the dev containers~~ | | | done 2026-08-29 → [`dev/README.md`](../dev/README.md) § *Four copies of this* |
| ~~2e~~ | ~~The fleet's own tunnel tokens rotated~~ | | | done 2026-08-29 → `decisions.md`; [`recovery.md`](recovery.md) |
| ~~2g~~ | ~~Every tunnel locally managed, its ingress in git~~ | | | done 2026-08-29, dashboard sweep 2026-10-25 → `decisions.md`; [`cloudflare.md`](cloudflare.md) § *Safe to delete* |
| ~~2i~~ | ~~The `ssh-zero-dev-*` rules and `anchor-two` retired~~ | | | done 2026-10-25 → `decisions.md` |
| ~~3~~ | ~~`send2ereader` adopted with its own connector; `bin/compose` deleted~~ | | | done 2026-10-25 → `decisions.md` § *Sidecar, not baked-in*; [its README](../deployments/send2ereader/README.md) |
| ~~6~~ | ~~`destiny-director` off `two`~~ | | | dropped 2026-10-25 → [infra#11](https://github.com/gsfernandes81/infra/issues/11) |
| ~~8~~ | ~~`two` as the scheduled read-only control node~~ | | | dropped 2026-10-25 → `decisions.md` (no control node inside the fleet) |
| ~~5~~ | ~~Dev hub: one compose file, the hub, its sidecar tunnel~~ | | | done 2026-10-27 → `decisions.md` § *Dev containers: one compose file*; what is left is under *Open items: dev* |
| ~~9~~ | ~~The November visit: `one` and `three` on Leap, `zero`'s encrypted disk swap, the daily pull~~ | | | done 2026-11-20 → [`plans/visit-runbook.md`](../plans/visit-runbook.md) § *What the visit did*; the remainder is phase 11 |
| 10 | **The dev hub moves from `zero` to `one`.** Docker as it is, no pool; `zero`'s copy removed after about three days | `zero`, `one` | nothing | In progress: [`plans/dev-hub-to-one.md`](../plans/dev-hub-to-one.md), PR #24 |
| 11 | **The backup proven.** Slice 4: the whole tree compared through the restore module, Immich's database started from `three`'s copy, `syncthing-three`'s login, a lock and an unlock. Then `zero`'s old `media-immich-data` and `media-immich-db` deleted (measured first), PR #22's change list (in [`plans/three-backup-pull.md`](../plans/three-backup-pull.md)) merged or closed, and a watch on `TIMELINE_LIMIT_HOURLY`: hourly snapshots are kept 24 hours, so a pull from Singapore longer than that meets snapper's cleanup; raise it to 48 if one does | `three`, `zero` | nothing; runs over the tailnet | Open: [`plans/visit-runbook.md`](../plans/visit-runbook.md) § *Slice 4* |
| 12 | **`zero` to Leap 16.1 Immutable**, its own design. Before it: the first boots' lessons ([`leap/README.md`](../leap/README.md) § *What the November visit's first boots taught*), the first-boot script made safe to re-run, `leap/README.md` and `firstboot.sh` no longer overstating the rollback (writes to `/home`, `/usr/local`, `/root` and `/var` survive a failed run), bcache and the LUKS member assembling on Leap, `RequiresMountsFor=` guards for Immich, subvolume ids recorded, the recreate puzzle answered (open items), and maybe Combustion's config on a partition of the card itself. Slice 4 runs again after | `zero` | 10, 11 | Open. Needs hands at the stack: the owner says whose |
| 13 | **Rootless podman on `one`**: declared memory limits proven to bind, the dev build key under podman, the dev containers' autostart, the `containers.podman` collection. Was 7 | `one` | 10 settled | Open. Notes below |
| 14 | **Fleet monitoring: a dead man's switch**, designed first. Covers `three`'s daily pull (its alert was deferred here), garmin-mcp's login lapsing, host uptime, "`zero` rebooted while you were away", and with uptime known, the gated `server-update-cloudflared.yml` becomes usable. Candidates: a prebuilt mesh (the owner's direction), the Worker with cron and email (proposed 2026-10-25), `two`'s lifeboat job ([`roadmap.md`](roadmap.md) §5) | fleet | nothing | Open |
| 15 | **Vault**: `torrents`' VPN login, each host's tunnel credentials file, the dev containers' secrets. Not in Vault, by design: the Cloudflare API token (one per machine), Access service tokens (one per client), anything that rotates as it is used. Was 4 | `one`, all hosts, dev | nothing | Open. Mechanism: `decisions.md` § *From the management plane* |
| 16 | **`zero`'s encryption protection on**: prove the passphrase on keyslot 1, take `data-4` out of `hosts/zero/system/dmcrypt`, `luksKillSlot <device> 0`; from then on every boot leaves the array closed until the owner opens it over ssh. Any older header backup destroyed and a new one taken | `zero` | 12, 14 | Open: `decisions.md` § *`zero`'s encrypted member*; [`roadmap.md`](roadmap.md) §4 |
| 17 | **Podman on `zero`**, once `one` has answered the two questions in *Notes for the phases ahead* | `zero` | 12, 13, 14 | Open |

### Open items, no phase

One line each; each says where its detail is. Struck when closed, deleted at the next tidy.

**`zero`**
- No btrfs scrub on the array since 2026-08-03, and nothing schedules one: [#25](https://github.com/gsfernandes81/infra/issues/25).
- When the WD Elements (devid 3) is replaced: a new bcache backing device, LUKS2 with Adiantum as `data-luks-3`, a second `dmcrypt` entry, `btrfs replace start -r 3`; then `sda1`, the cache, still holds plaintext from before, so it is detached, `blkdiscard`ed and made again. Waits on its errors, or the array passing about 60 %.
- `hardware.md` regenerated with `bin/hw-inventory` (last 2026-08-21, before the disk swap).
- Subvolume ids recorded by `hw-inventory`, since Leap mounts data by `subvolid=` (before phase 12).
- `cloudflared` still updates itself on Alpine (`zero` 240 h, `two` 72 h), against *Updates are by hand*; each host's init script carries `--no-autoupdate` instead, by the two-phase procedure. `zero`'s ends at phase 12; `two`'s remains.
- Docker's `max-concurrent-downloads`, left at its default when Docker moved off the SD card.

**Tools and plays**
- `server-install-packages.yml` uses `apk` and Alpine's package names, so a fleet-wide run fails on a Leap host.
- The repo's callback prints only a looped debug's label, so `server-install-system-files.yml --check` shows file names, not the diffs or the refusal reasons (`ansible/callback_plugins/infra.py`, `v2_runner_item_on_ok`).
- `server-deploy-compose.yml -e deployment=all` planned to recreate `zero`'s `immich` and `syncthing` though neither had changed (2026-11-18, declined); first look: a `docker compose config` diff against the running containers. Before phase 12.
- `_cf-tunnel.yml`'s reads fail censored on a 403: the zone read still has no `failed_when`.
- `install-system-file` keeps its backups under `$HOME` (`BACKUP_ROOT = Path.home()`), so under sudo they land in `/root/.infra-backups`, unswept.
- An adversarial review of `argon-fan` (the first-boot script's half is phase 12).

**Leap hosts**
- `three` refused a new ssh for a few seconds while Docker first started at the unlock, twice in simulation (a firewalld reload as Docker registers its zone, likely); a watch.
- `one` keeps the failed first runs' snapshots (#6, perhaps #2 to #4) and a dirty FAT boot partition from pulled power, to clean up.
- firewalld's `public` zone on `one` allows `cockpit`, and `tailscale0` is in no zone: does Cockpit listen, and should the zone drop it?
- `PermitOpen` in every `sshd-infra.conf` names `three` at `192.168.86.103`; `three` is now in Singapore on DHCP, so that mesh route no longer exists. Keep, or drop on the next edit?
- The Sabrent's link downshifts, seen on `three`; a watch.

**Dev containers** (after phase 10 unless said)
- No file transfer through the hub: scp and sftp go as a stream, `ssh dev ssh <c> 'cat f' > f`.
- The fleet-access plumbing in the base (`dev/ssh_config`, `entrypoint.sh`, `status.sh`, login's step 2) serves a control node the owner declined, and could go.
- Each workspace moves from `/workspace` to `~`, the child repos first, with `CLAUDE_CODE_PROJECT_DIR_NAME` set to the old project key so memories and transcripts are not orphaned.
- `entrypoint.sh` warns "no id_* keys" for containers meant to have none.
- `login.sh`'s `git ls-remote` check passes without a token.
- The owner's OAuth login in each container's `gh` volume: done in `infra`, the others still to check.
- The deploy probe hook does not read `make verify`.
- `dev-smoke` runs Compose v2.38, not the fleet's v5.6.1.
- Each base bump rebuilds all nine images; needs a design decision first.
- A container cannot report which base tag it runs: an `/etc/dev-base-version` next time the base is touched.
- [`plans/dev-pool.md`](../plans/dev-pool.md) step 1 is written for `zero`'s OpenRC, and the hub moves to `one` with no pool: re-scope it as a systemd slice on `one`, or delete it (the owner's call).

**Cloudflare**
- The `Restricted` and `or3-dev` Access applications, carried from the visit's handoff unexamined.

**Docs**
- README's Fleet table has no row for `three`.
- `host-setup.md`'s `zram-init` claim is out of date.

**Housekeeping**
- Renovate: no PR since 2026-10-25; check it still runs: [#26](https://github.com/gsfernandes81/infra/issues/26).
- Delete the branches `send-receive`, `ci-speed` and `plan-three-send-receive`, and the session worktrees under `.claude/worktrees/` (prune only entries under `/workspace` that are gone, CLAUDE.md § *Git & workflow*).
- `one`'s dead containerd store: moot now the Alpine card is retired; confirm, then strike.

### Old labels

Labels in commit messages and in `decisions.md` before 2026-11-20 are unchanged, except:

| Old | Now |
|---|---|
| 4 (Vault) | 15 |
| 7 (rootless podman on `one`) | 13 |
| 9's remainder | 11 |

## The status board

<https://claude.ai/code/artifact/0133f388-9fd7-4392-8d2c-0e1b18610784>

The phase table rendered for reading on a phone. **The table is the record and the board is
the view**: if they disagree, the board drifted. Update it in place, by passing that URL to
the Artifact tool as `url`; publishing without it creates a second board.

## Why Ansible, in brief

There was no single record of what runs where, so every fact about a host's workloads was
kept by hand in three to five places and had drifted. Ansible gives placement by playbook,
read from the target over ssh, with no control plane, no fleet-wide trust domain and no
scheduler that would have to be told never to schedule. Why not Nomad, how secrets are kept,
and why there is no identity provider: `decisions.md` § *From the management plane*.

## What is not changing

- **No key on `zero` authorising it to reach `one` or `two`** ([`decisions.md`](decisions.md)).
- **`check-system-drift` and `hw-inventory` still refuse to operate on a host you are not
  standing on.** Ansible reads the target over ssh, so it is a different mechanism, not an
  exception to that rule.
- ~~Claude dev containers stay in their own app repos.~~ Every dev container is now in one
  `dev/compose.yaml` here (`decisions.md` § *Dev containers: one compose file*).
- **`gavin` is not in the `docker` group, and nothing privileged runs from an agent
  session.** Playbooks are run by a person, from the phone, in their own terminal.

### A control node inside the fleet: no

The owner's call, 2026-10-25: `infra` stays a development container with no route to the
fleet, and the phone is the only control node. The argument, and what would change it, is
in `decisions.md` § *From the management plane*.

## Placement

| Workload | Host | Mobile? | Pinned by |
|---|---|---|---|
| Immich (+ db, ml, redis) | `zero` | no | the bcache-fronted btrfs array |
| Syncthing | `zero`, and `torrents`' own on `one` | no | the data it syncs |
| `syncthing-three` | `three` | no | the backup array it shares |
| torrents (gluetun + qBittorrent) | `one` | no | `/dev/net/tun`, a shared network namespace |
| send2ereader, calibre-web, garmin-mcp | `one` | yes | habit |
| pearl-wallet | `zero` | yes | habit |
| destiny-director (stopped) | `two` | yes | armv6 images today ([infra#11](https://github.com/gsfernandes81/infra/issues/11)) |
| ionic-traces (stopped) | none | yes | `decisions.md` § *From the management plane* |
| The dev hub and every dev container | `zero`, moving to `one` (phase 10) | yes | habit |

What actually runs where is [`fleet-inventory.md`](fleet-inventory.md), which wins over this
table when they disagree.

## Notes for the phases ahead

### What rootless podman costs on OpenRC

| | `docker` group removed | memory limits |
|---|---|---|
| docker, today | no | yes |
| rootless podman on OpenRC | **yes** | **no** |
| rootful podman on OpenRC | no | yes |
| rootless podman on systemd (Leap) | **yes** | **yes** |

On OpenRC you pick one; on systemd you get both, because systemd delegates the cgroups.
Rootless with the `cgroupfs` manager is not a supported path for resource limits, upstream
says ([podman#8330](https://github.com/containers/podman/issues/8330),
[discussion #19158](https://github.com/containers/podman/discussions/19158)). Since `one` and
`three` moved to Leap, the OpenRC rows matter only for `two`. Autostart is a small script
running `podman start --all` as the user on OpenRC, and a user service on systemd.

### The limit that would go quiet

A compose file's `deploy.resources.limits.memory` is enforced by Docker, and would be
silently ignored by rootless podman without delegation: still in the file, still read as
protection, enforcing nothing. Any host that converts proves its declared limits bind, or
deletes them.

### `oom_score_adj` is a mitigation, not a replacement

It decides who dies once the box is already out of memory; a memory cap makes a runaway fail
inside its own cgroup first. `two` uses it for the job it is good at, pinning `cloudflared`
to −1000 to keep the way in alive. Moving the dev containers off the box serving Immich
(phase 10) removes the constraint without any cgroup configuration.

### What `one` must answer before `zero` is considered

Two questions, answered on the disposable box before phase 17:

- **Can an existing Postgres data directory be adopted, or does it need a dump and
  restore?** That is the difference between a migration and a maintenance window on
  `zero`.
- **Does `--userns=keep-id` map correctly onto the `/media` bind mounts, or does ownership
  on disk have to change?** A change of ownership is a change to the data itself.

A throwaway Immich on `one` answers both and risks nothing.
