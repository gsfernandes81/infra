# Working conventions for agents

Human docs live in `docs/` — keep them short, specific, and free of anything inferable.
Put process detail here instead.

## Privileged commands

`gavin` does not use `!` in-session and is not in the `docker` group. Anything needing
`sudo` or the Docker socket is **handed over as a copy-paste block or a reviewable
script**, run in a separate terminal, with the output pasted back.

Never assume a privileged command ran. Verify from its output, or by re-reading state
with unprivileged tools. Prefer writing results to a file the agent can read over
asking for a large paste — but `docker compose config` interpolates `.env`, so those
files contain live secrets: `chmod 600`, keep them outside the repo, delete after.

## Before committing

Two-way secret scan. The name-based one alone is not sufficient:

```sh
git ls-files -z | xargs -0 grep -nEI \
  'PRIVATE_KEY|DISCORD_TOKEN|OPENVPN_PASSWORD|ROOT_PASSWORD|PBKDF2|eyJhIjoi'
git status --porcelain --ignored | grep '\.env$'      # expect: ignored
```

Then value-based: take each live value out of the gitignored `.env` files and grep
every tracked file for it. That catches what a name pattern can't.

## Verifying changes

- Moving a file that must not change: md5 before and after.
- Changing a compose file: diff `docker compose config` output, not the files. Only
  that proves Compose *parses* them identically.
- A check must exclude values it could trivially match. See the `Session\Port` /
  `TORRENTING_PORT` case in `docs/port-forwarding.md` — a bare "did it change" test
  passed on a restart artefact and stopped watching.
- **Calibrate a check against known-good state before you trust its verdict.** On
  `zero`, a tunnel health check counting sockets on port 7844 read **0 while the tunnel
  was serving normally** — it would have rolled back a good change and then reported
  that the rollback failed too. Run the check against the working system *first*; if it
  does not read healthy, the check is wrong, not the system.
- **Proving a container was not recreated:** compare container **IDs**, not `StartedAt`.
  `StartedAt` necessarily changes across a legitimate `stop`/`start`, and "is it
  running" passes for a recreated container too — the exact wrong-reason pass above.
- Use `stop`/`start`, never `up -d`, when the intent is only to cycle a container. `up`
  re-evaluates config and may recreate.
- One-shot migration scripts get deleted once run. Leaving an executable in `bin/`
  that tears down live stacks is a foot-gun, and git history keeps it.

## Shell traps that have actually bitten here

- **`cmd > file` truncates `file` before `cmd` runs.** `ssh host 'cat cfg' > ~/.ssh/config`
  emptied the config, so ssh then had no `Host` block and could not resolve the host.
  Write to a temp file and `mv` into place.
- **`[ -d /path ]` runs unprivileged.** On root-only paths (a btrfs top level, `/media/immich-db`
  at mode 700) it returns false for directories that demonstrably exist. Use `sudo test -d`.
  A guard built on the wrong answer silently skips the work it was meant to do.
- **`a | b || c`** tests `b`'s exit status, not `a`'s. A fallback after a pipeline
  never fires; `grep -c` returning `0` also exits 1 and breaks `&&` chains.
- **Do not run `git worktree prune` from the host** on a repo bind-mounted into a
  container. Worktrees registered as `/workspace/...` do not resolve host-side, so all
  of them read `prunable` and would be unregistered.

## Changing the thing you are connected through

Restarting a tunnel, sshd, or networking is only safe when your session does not
traverse it. Establish that from **your** shell — `echo $SSH_CONNECTION` — not from a
long-lived agent process, whose value is a fossil of the SSH session that started it
and never changes. Getting this wrong once produced an entire detached self-healing
worker to solve a problem that did not exist.

Safe positions: a second path in (bastion, LAN), and a `screen`/`tmux` session whose
parent chain reaches `init` with no sshd in it (`cat /proc/<pid>/stat` up the tree).

Procedure, in two phases, with the risky half separated from the reversible half:

1. **Prepare, no restart.** Back up the file. Make the change. Then prove the new
   configuration expands to something byte-identical to the running one — e.g. source
   the new `/etc/conf.d/<svc>` as OpenRC would, expand `command_args`, and compare
   SHA-256 against the original command line. Never print the secret. If the hashes
   differ, revert and stop; nothing has restarted.
2. **Restart, watching, with automatic rollback.** Poll an *end-to-end* probe, not a
   proxy for one. After a bounded wait, restore the backup and restart again.

## Mount guards (`zero` and `one` — both applied)

Docker's init declares only `need sysfs cgroups net` — it starts whether or not
`/media/*` mounted, so a container with `restart: always` will populate an empty
mountpoint. Immich writes a blank library; Postgres runs `initdb` over nothing.

Two layers, and neither can prevent boot:

- **`nofail`** on every `/media/*` fstab entry.
- **`chattr +i` on the bare mountpoints** — the directories *underneath* the mounts.
  Shadowed while mounted; if the mount fails, writes return EPERM even to root.

Applying it: stop consumers → `umount` → **confirm the bare mountpoint is empty**
(if not, the trap has already fired: tar it off-array, verify the tarball, then empty
it — `+i` only blocks *new* entries, so pre-existing ones stay writable) → `chattr +i`
→ **prove it by attempting a write and requiring failure** → remount → restart.

An OpenRC guard service was tried and rejected: new boot-path code, a new way for the
box to come up with no containers, and a false-failure mode (renaming a Syncthing share
would have stopped Docker on the next reboot). `chattr +i` makes the bad write
impossible rather than detected. On MicroOS, `RequiresMountsFor=` replaces it.

**Both layers are live on `one` as well, verified 2026-08-23**, and this is no longer
theory: `one`'s array went missing, `mysql-ionic` restarted into the bare
`/media/ionic-mysql` under `restart: always`, and `chattr +i` refused it — the container
logs read `chown: changing ownership of '/var/lib/mysql': Operation not permitted`, once
a minute, for days. The database on the unmounted `sdb1` was untouched and the bare
mountpoint stayed empty. Worth knowing what the guard *looks like* when it fires: not an
alert, but a service in a crash loop for a reason that reads like the service's own bug.

`sudo bin/check-mount-guards` verifies both. It bind-mounts `/` to see the real
mountpoints — `lsattr -d` on a *mounted* path reports the mounted filesystem's root,
answering a different question.

## Backups of secret-bearing files

**A backup inherits both the secret and the permissions.** Moving the Cloudflare token
out of `/etc/init.d/cloudflared` (755, world-readable) left
`/etc/init.d/cloudflared.bak-token` — same mode, same token — so the exposure the whole
exercise existed to remove was still there afterwards, and every check said PASS
because they all looked at the file being fixed, not the copy beside it.

Two rules:

- Back up **outside the directory**, at mode 600. Never `foo.bak` next to `foo`.
- Never in `/etc/init.d`: anything executable there is an OpenRC service, so the backup
  appears in `rc-status` as a phantom stopped service on the boot path.

Then grep the *directory*, not the file, before declaring it done:
`grep -rlE '\-\-token [A-Za-z0-9_=-]{40,}' /etc/init.d/`

## Landmines

- **Never `apk del containerd` on its own.** `docker-engine` hard-depends on it, and so
  does `k3s`; `/usr/bin/containerd` and `containerd-shim-runc-v2` are what dockerd's own
  containerd and every running shim exec from. Removing it kills every container at the
  next start. The standalone `containerd` *service* is unused and safe to drop from the
  runlevel — the package is not. **The exception, which is only an exception because it
  is a different operation:** removing it in one `apk del` transaction with every
  dependent, after stopping the services, is how docker leaves `two` entirely
  (see `hosts/two/setup/README.md`). apk resolves the order itself; containerd is
  never removed alone. The trap that comes with it: `iptables` is on that box only as an
  auto-installed dependency of docker/k3s, `apk del` reclaims orphans, and netavark
  needs `iptables` while **not** depending on it — so it must be installed explicitly
  *before* the removal or rootless podman networking breaks days later, for a reason
  nobody would connect back to a docker cleanup.
- **Install `smartmontools`; never add `smartd` to a runlevel on `one`.** The two are
  not the same act. `bin/hw-inventory` polls once, when a person runs it, and honours
  `smart_skip` in that host's `hw-inventory.toml` — which is why `one`'s failing bay-0
  SP900 is named there and never touched. `smartd` is a daemon, knows nothing about that
  file, and polls **every** disk on a schedule. On `one` that means periodically issuing
  the INQUIRY that stalls the Sabrent bridge, which takes `sdb` and therefore the array
  with it: a ten-minute outage, on a timer, for a reason nobody would connect to a
  package installed months earlier. Alpine does not add it to a runlevel on install, so
  the package is safe; the trap is the obvious next step, someone seeing `smartd` and
  thinking "monitoring, good".
  **`smartmontools` is now fleet-wide** — it is in `base_packages` in
  `ansible/group_vars/fleet.yml`, so `ansible/playbooks/packages.yml` puts it on all
  three, and the comment there says why installing a tool is not enabling it. That makes
  this landmine *more* live, not less: the tool is now present on `one` by policy, so the
  only thing standing between the fleet and a ten-minute array outage is nobody running
  `rc-update add smartd`. If `rc-status --all | grep smartd` ever returns a line on `one`,
  that is the incident, and the fix is `rc-update del smartd` before anything else.
- **"Exited" is not "absent".** A stack with an exited container, a registered compose
  project, or surviving named volumes must be torn down properly. Deleting its files
  first orphans them permanently.
- **Measure before deleting.** A subvolume flagged as a dead remnant turned out to hold
  ~340 GiB. It was still the right call, but the size should have been in the ask.

## Repo invariants

No `..` in compose files · every compose file declares `name:` · host-specific values
in gitignored `.env` (never `$HOME`).

`/etc` copies under `hosts/<host>/system/` each declare where they install, in an
`infra-` header carried by **both** the repo copy and the live file — see
[`hosts/zero/system/README.md`](hosts/zero/system/README.md).

Two programs, and the split is the point: `check-system-drift` reports and never
writes; `install-system-file` writes and never restarts. Earlier wording here said
these copies are "never applied", which was already untrue — `bcache-register` was
installed by hand from the repo on 2026-08-03, and the ad-hoc block that did it left
its backup in `/etc/init.d/`, where OpenRC picked the backup up as a service.

`install-system-file` does the **reversible half only**. It writes a file, sets its
mode, validates, and rolls back a failure. It cannot start, stop or restart anything,
so it cannot be used to skip the two-phase procedure below. It also does not
*generate*: the bytes that reach `/etc` are the reviewed bytes in the repo. Generating
boot-path content from templates is still rejected.

```sh
bin/install-system-file <name>                     # dry run: shows the diff, writes nothing
bin/install-system-file <name> --commit            # header-only changes
bin/install-system-file <name> --commit --allow-content-change
```

A change beyond the `infra-` header needs the third form, so "just adding a comment"
can never be cover for a real edit to a boot-path file. Activating what you installed
stays a separate, human step.

**When adding a validator to it, calibrate against known-good state first.** The fstab
UUID check failed twice before it was right: `/dev/disk/by-uuid` alone reported the
live, mounted array as unresolvable (the btrfs *filesystem* UUID never gets a symlink
here — the array assembles via `btrfs-scan` from the bcache devices, and only the
bcache *component* UUIDs appear there), and the mountpoint-based fix that replaced it
passed a typo'd root UUID, because every entry on a running box is mounted.
`/sys/fs/btrfs/<fs-uuid>/` is the registry that answers this correctly, unprivileged.
`blkid -U` cannot: without root it exits 0 with no output for real and nonsense UUIDs
alike.
