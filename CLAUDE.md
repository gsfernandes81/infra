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

## Mount guards (`zero`, and due on `one`)

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

- **Never `apk del containerd`.** `docker-engine` hard-depends on it; `/usr/bin/containerd`
  and `containerd-shim-runc-v2` are what dockerd's own containerd and every running shim
  exec from. Removing it kills every container at the next start. The standalone
  `containerd` *service* is unused and safe to drop from the runlevel — the package is not.
- **"Exited" is not "absent".** A stack with an exited container, a registered compose
  project, or surviving named volumes must be torn down properly. Deleting its files
  first orphans them permanently.
- **Measure before deleting.** A subvolume flagged as a dead remnant turned out to hold
  ~340 GiB. It was still the right call, but the size should have been in the ask.

## Repo invariants

No `..` in compose files · every compose file declares `name:` · host-specific values
in gitignored `.env` (never `$HOME`) · `/etc` copies under `hosts/<host>/system/` are
read-only references, never applied.
