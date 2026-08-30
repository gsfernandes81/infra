# infra — Project Rules

Container and system config for three Raspberry Pis — `zero` (Pi 5, Immich + Syncthing,
**critical and remote**), `one` (Pi 4, torrents + send2ereader) and `two` (Pi 1 B+,
armv6, the `destiny-director` test bot on rootless podman). **Config only — no source,
no secrets, no data.** Alpine + OpenRC on all three today; `one` and `zero` are headed
for openSUSE MicroOS. Docker Compose on `one`/`zero`, `podman-compose` on `two`, Ansible
as the management plane, and a handful of Python tools in `bin/`.

> **Two places this repo is worked on, and neither can touch the fleet from an agent
> session.** The owner's **phone (Termux)** is the control node — the only machine with a
> route to every box, and the only one on a metered connection. **`infra-dev`**, a
> container on `zero`, is where Claude usually runs: free data, `git`/`gh`/`ansible`
> present, **no route to `zero`, `one` or `two` by decision** (`docs/management-plane.md`
> § *A control node inside the fleet*). In both, `gavin` is not in the `docker` group and
> `sudo` wants a password. Anything that changes a box is **handed over**, not run — see
> *Privileged commands*.

## Layout map — read before changing anything

Full orientation is `README.md`; the reasoning is `docs/decisions.md`. Quick map:

- **`deployments/<stack>/`** — what a stack *is*: `compose.yaml`, `.env` (gitignored,
  host-specific values live there and never `$HOME`), `SOURCE` (the upstream URL and the
  deployed sha — **it records, it never pulls**; a URL-only `SOURCE` means
  registry-deployed, see `destiny-director/SOURCE`). Canonical; hosts symlink in.
- **`hosts/<host>/`** — where it runs: symlinks into `deployments/`, plus `system/` —
  tracked copies of `/etc` files, each carrying an `infra-` header that says where it
  installs (`hosts/zero/system/README.md`). `hosts/two/setup/` is the whole build of
  `two`, one reviewed root script, on no PATH.
- **`bin/`** — `compose` (docker stacks only; refuses `destiny-director` by name),
  `check-sources`, `check-system-drift` (reports, never writes), `install-system-file`
  (writes, never restarts), `check-boot-layout`, `check-mount-guards`, `hw-inventory`.
  `_infra.py` is their shared header parser. **Not wrapped in the Makefile yet, on
  purpose** — the Makefile header says why; do it as its own change or not at all.
- **`ansible/`** — inventory, playbooks, the audit. **Runs from the phone, never from a
  Pi**: there is no `ansible` on the boxes and there must not be. `infra-dev` carries it
  as a *development* tool (syntax-check, `--check` against stubs), not a control plane.
- **`dev/`** — the `infra-dev` container. Lifecycle is `dev/Makefile` only (it computes
  `HOST_UID` from the checkout's owner; a second copy of that guard is how root-owned
  files end up in the bind mount). The top-level `Makefile` forwards `dev-*` to it.
- **`docs/`, `plans/`, `docs/handoff/`** — see the next section. **`docs/history/`** holds
  one finished plan, kept as a record of how the design was arrived at and marked *do
  not follow*; it is not a destination.

## Docs, plans and handoffs — the three-folder regime

**`docs/` is for humans. This file is for process.** A doc is short, specific, and free of
anything inferable from the repo; a rule about *how to work* goes here, not there.

- **`docs/decisions.md`** is where a decision lands the moment it is made — a row with
  the *because*, in the same commit as the change it explains. Rows are never deleted:
  mark a reversed one ⚠︎SUPERSEDED and say what replaced it. Argue with the reason there,
  never from scratch.
- **`docs/roadmap.md`** and the phase table in `docs/management-plane.md` are the index of
  what is next. **Findings get filed into the phase table; they do not start work.**
- **Where a doc and a generated artefact disagree, the artefact wins** —
  `docs/fleet-inventory.md` over the README's port table, `curl 127.0.0.1:20241/config`
  over `docs/cloudflare.md`. That disagreement is the signal those artefacts exist to
  give; fix the doc, do not argue with the box.
- **Docs change in the same commit as the thing they describe.** A commit that changes a
  playbook, a compose file or a `bin/` tool and leaves its README or doc describing the
  old behaviour is incomplete, and does not merge (see *Git & workflow*).

**`plans/`** stores deferred and in-progress plans, one `plans/<topic>.md` each. A plan is
a proposal, not a decision: when it is *taken*, its reasoning moves to `decisions.md`.
**When a plan is executed completely, ALWAYS remove it from `plans/`.** If it was only
partly executed, ask the owner whether to keep, trim, or delete it — never silently leave
a plan that reads as open when it is mostly done. Finished plans are deleted, not archived
(`docs/history/` is the one exception, kept for how it shows the reasoning, and stays
at one file).

**`docs/handoff/`** holds session handoff notes, `YYYY-MM-DD-<topic>.md`, written at the
end of a session for the next one. Two rules, both of which have bitten:

- **A handoff's opening instructions are the next session's first orders.** If it says
  *read this, report, and stop*, then the first reply states where things stand and waits
  — no edits, no commits, no playbook runs until the owner picks something. Findings go
  into the phase table, not into work.
- **A note is deleted once its open items are all closed *and* nothing in it is the only
  record of a decision.** Move the durable reasoning to `decisions.md` or the relevant doc
  first, then delete. A handoff that outlives its items becomes a second, stale source of
  truth.

## Git & workflow

- **`main` is the only long-lived branch, and it is what the boxes run.** The checkouts
  on the hosts (`~gavin/infra` on **both** `zero` and `two`) track `main`; a bad
  `main` is a bad fleet.
- **Merge to `main` as soon as the work is complete and non-breaking. This is strongly
  encouraged, not merely allowed.** Small, frequent, finished commits straight to `main`,
  pushed, are the default. Work sitting on a branch is work the next session (or the
  owner, from the phone) cannot see.
  - *Complete* means: the change, its doc, its `decisions.md` row if it decided
    something, and its plan removed from `plans/` if it finished one — all in the commit.
  - *Non-breaking* means: every tracked `/etc` copy still carries a valid `infra-` header
    and installs cleanly in a dry run; every compose file still parses identically
    (`docker compose config` diff, not a file diff); nothing on `main` describes a state
    the fleet is not in without saying so.
- **Worktrees are the exception, not the workflow.** Use one only when the work will
  *span sessions in a breaking state*, when several agents are editing in parallel, or
  when it is an experiment the owner may reject outright. When you do:
  - Name the branch for the work (`cloudflared-update-staging`, `two-podman-iptables`),
    never an opaque harness hash. If you land on a `worktree-…` or hash-named branch,
    `git branch -m <name>` before the first commit.
  - Merge it into `main` the moment it is complete and non-breaking, then delete the
    branch and the worktree. A worktree that outlives its work is the same stale-truth
    problem as a handoff that does.
  - **In `infra-dev`, an Ansible change made in a worktree is not what your test runs.**
    The image sets `ANSIBLE_CONFIG=/workspace/ansible/ansible.cfg`; a relative
    `inventory =` inside that file resolves against *its own* directory, and Ansible
    reads the variable before the cwd — so `cd` into the worktree and `ansible-playbook`
    still loads the MAIN checkout's `inventory`, `group_vars` and `host_vars`. It fails in the
    most confusing available way: a var you just added reads undefined while its
    neighbours in the same file resolve, because the file being read is the other copy.
    Prefix the run with `ANSIBLE_CONFIG=<worktree>/ansible/ansible.cfg`. Ad-hoc `ansible`
    and `ansible-inventory` mislead here too — their playbook dir is the cwd, so they
    load the worktree's `group_vars` and report the new value the playbook cannot see.
  - **Never run `git worktree prune` from a host** on a repo bind-mounted into a
    container. Worktrees registered as `/workspace/...` do not resolve host-side, so all
    of them read `prunable` and would be unregistered — live sessions included.
    **And not from the container either, blanket.** The same asymmetry runs both ways: a
    worktree created host-side is registered under a path that does not resolve *in* the
    container, so a prune in here unregisters it. Prune only entries whose path is under
    `/workspace` and is actually gone. Found live in a dev-container supervisor on
    2026-08-24, where it would have run on every daemon start.
- **`git checkout origin/main -- <file>` does not "drop a file from your branch".** It
  adopts whatever `origin/main` is *at that instant*, diffed against your commit's own
  parent — so if `main` has moved since you branched, you silently author someone else's
  newer work into your commit. It happened on PR #1: twenty-eight lines of the reviewer's
  own edit landed inside the contributor's commit, in the file they had just agreed was
  the reviewer's. Use `git rebase origin/main`, and when the superseded text is the
  plausible-looking one, confirm with `cmp` rather than by reading hunks. Cross-repo
  conversions (`dd`, `ds`) will meet this again.
- **Commit messages are one lowercase sentence saying what changed and why**, with an
  area or phase prefix when there is one (`2g phase 3: retire the old tunnel, with the
  guard that matters`, `cutover: refuse to cycle the tunnel we came in through`,
  `zero: routes into the repo`). Not conventional commits; the *why* is the point, and
  `type(scope):` has no room for it.
- **Never rewrite `main` history, never force-push.** The hosts pull it.
- **Read `git diff --stat` before every commit** and revert any file the change has no
  business touching.

### Before committing — the two-way secret scan

The name-based scan alone is not sufficient:

```sh
git ls-files -z | xargs -0 grep -nEI \
  'PRIVATE_KEY|DISCORD_TOKEN|OPENVPN_PASSWORD|ROOT_PASSWORD|PBKDF2|eyJhIjoi'
git status --porcelain --ignored | grep '\.env$'      # expect: ignored
```

Then value-based: take each live value out of the gitignored `.env` files and grep
every tracked file for it. That catches what a name pattern can't. **Never commit a
`docker compose config` dump** — it interpolates `.env`, so it *is* the secrets.

## Privileged commands

`gavin` does not use `!` in-session and is not in the `docker` group. Anything needing
`sudo` or the Docker socket is **handed over as a copy-paste block or a reviewable
script**, run in a separate terminal, with the output pasted back.

- **Write handover blocks for fish and a TTY.** `ssh host 'sudo …'` hangs — no TTY, so
  `sudo` cannot prompt. Give the owner `ssh host` first, then a block to paste *inside*
  that shell. From the phone, `ssh -t zero 'cd ~/infra/dev && make up'` is the documented
  shape for the dev container, and the `-t` is why it works.
- **Never assume a privileged command ran.** Verify from its output, or by re-reading
  state with unprivileged tools.
- Prefer writing results to a file the agent can read over asking for a large paste —
  but `docker compose config` interpolates `.env`, so those files contain live secrets:
  `chmod 600`, keep them outside the repo, delete after.
- **Never deploy, restart, or cut over anything on the fleet on your own initiative.**
  Deploys are the owner's to drive. A playbook that changes a box runs only when the
  owner has been asked in that exchange and said yes; `--check` is not a substitute,
  and a bootstrap play cannot even dry-run the half that depends on what the first half
  would create (Ansible templates a *skipped* task's arguments, so ids only a write could
  produce are undefined — the fix is an inline filler in the write, never a `set_fact`,
  which makes the id look defined to the reads too).

## Verifying changes

- **Calibrate a check against known-good state before you trust its verdict.** On
  `zero`, a tunnel health check counting sockets on port 7844 read **0 while the tunnel
  was serving normally** — it would have rolled back a good change and then reported
  that the rollback failed too. Run the check against the working system *first*; if it
  does not read healthy, the check is wrong, not the system.
- A check must exclude values it could trivially match. See the `Session\Port` /
  `TORRENTING_PORT` case in `docs/port-forwarding.md` — a bare "did it change" test
  passed on a restart artefact and stopped watching.
- Moving a file that must not change: md5 before and after.
- Changing a compose file: diff `docker compose config` output, not the files. Only
  that proves Compose *parses* them identically.
- **Proving a container was not recreated:** compare container **IDs**, not `StartedAt`.
  `StartedAt` necessarily changes across a legitimate `stop`/`start`, and "is it
  running" passes for a recreated container too — the exact wrong-reason pass above.
- Use `stop`/`start`, never `up -d`, when the intent is only to cycle a container. `up`
  re-evaluates config and may recreate.
- **Verify which commit is deployed, not that a deploy reported success.**
  `bin/check-sources` for the pinned stacks; `podman inspect dd-beacon --format
  '{{.Image}}'` on `two`, where the deploy follows a moving branch tag by design.
- **Anything whose response cannot be fetched again is printed the moment it is
  created** — a Cloudflare service token's secret was lost to `no_log` on a task that
  failed only because the API answered 201 and `uri` accepts 200 by default.
  The same `no_log` also censors the *failure*: a refused write reports a status code
  and nothing else, while the API put the reason in the response body. So a `no_log`
  write that can be refused carries `failed_when: false`, then a task that prints the
  body's error list (never the invocation — that is where the Authorization header is),
  then an `assert` that stops the play. Accept every 2xx the operation could answer
  with, and prove the outcome with a check, not with the status code.
- One-shot migration scripts get deleted once run. Leaving an executable in `bin/`
  that tears down live stacks is a foot-gun, and git history keeps it.

## Shell traps that have actually bitten here

- **`cmd > file` truncates `file` before `cmd` runs.** `ssh host 'cat cfg' > ~/.ssh/config`
  emptied the config, so ssh then had no `Host` block and could not resolve the host.
  Write to a temp file and `mv` into place.
  **And a redirection follows a symlink, truncating the target.** A dev container whose
  `child-init.sh` symlinked `~/.ssh/config` at the host's gitignored one would have had
  that host file overwritten by the base's own assembly on the SECOND boot — the first
  boot writes a regular file, `stop`/`start` reuses the filesystem, and the write lands
  through the link. Caught in review, not in production. `rm -f` before a write to any
  path something else may have re-pointed.
- **`[ -d /path ]` runs unprivileged.** On root-only paths (a btrfs top level, `/media/immich-db`
  at mode 700) it returns false for directories that demonstrably exist. Use `sudo test -d`.
  A guard built on the wrong answer silently skips the work it was meant to do.
- **`pkill -f <pattern>` matches the shell you are running it from.** A command from an
  agent session arrives as `bash -c '<the whole command>'`, so the pattern is sitting in
  that shell's own argv: `pkill -f 'abduco -n faketest'` signalled the script mid-run,
  everything after it never happened, and the only symptom was an exit code (144) with no
  output. It happened twice in one session before the cause was obvious. Kill by pid from
  a list you built first, and skip `$$`.
- **`a | b || c`** tests `b`'s exit status, not `a`'s. A fallback after a pipeline
  never fires; `grep -c` returning `0` also exits 1 and breaks `&&` chains.
  **`set -o pipefail` is the wrong fix when you meant `a`.** It answers "did anything in
  the pipeline fail", so the branch now also fires when `a` SUCCEEDED and `b` died — in
  `dev/entrypoint.sh` that meant a good `git pull` reporting "the checkout is unchanged",
  a false statement about the tree from the fix for a false statement about the tree.
  `${PIPESTATUS[0]}`, read on the very next line, asks the question actually being asked.
- **An Ansible `register` is overwritten by a skipped task.** The guard that read it
  afterwards was disarmed — the `retire` playbook's history has the commit. Register
  into a different name, or `when:` the consumer on the producer's own condition.
- **An Ansible `debug` task reports `ok`, and `ansible.cfg` sets `display_ok_hosts =
  False`** — so a message a playbook exists to print does not print at all. It silently
  swallowed the Access service token banner, the one thing on this fleet that cannot be
  fetched again. Every `debug` whose output is the point carries `changed_when: true`;
  the reason is in `ansible.cfg` beside the setting. Prove a new one displays by running
  it, not by reading it.

## Changing the thing you are connected through

Restarting a tunnel, sshd, or networking is only safe when your session does not
traverse it. Establish that from **your** shell — `echo $SSH_CONNECTION` — not from a
long-lived agent process, whose value is a fossil of the SSH session that started it
and never changes. Getting this wrong once produced an entire detached self-healing
worker to solve a problem that did not exist. `ssh-zero.gsrpi.uk` *is* zero's tunnel:
a session that arrived that way cannot restart it.

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

`bin/install-system-file` is phase 1 and refuses to be phase 2 — see *Repo invariants*.

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

**This recurred, and the check above was what found it.** On 2026-08-23,
`/etc/init.d/cloudflared.bak-token` was still present on `one` — 755, dated 20 July, the
token inline — more than a month after the move it was a backup of, and after this
section was written describing exactly that outcome. Recording a lesson is not applying
it: the cleanup happened on whichever host the problem was noticed, and nothing swept the
others. `zero` was clean. **When a rule here is about a class of file, check every host
that has one.**

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
- **`smartd` on `one` — a landmine DEFUSED on 2026-08-24, kept as the type specimen.**
  From Aug 2026 until then, adding `smartd` to a runlevel on `one` would have taken the
  array down on a timer: the failing SP900 in bay 0 stalled the USB bridge on the exact
  INQUIRY a SMART poll issues, and `smartd` polls every disk on a schedule, knowing
  nothing about the `smart_skip` list that kept `bin/hw-inventory` safe. The disk has
  been pulled and the hazard is gone — `rc-update add smartd` is now merely a choice,
  not an incident. The entry stays because it is the cleanest example of two rules this
  file keeps re-learning: **installing a tool is not enabling it** (smartmontools went
  fleet-wide as a package precisely while its daemon was a loaded gun on one host), and
  a landmine's trigger can be an innocuous act — someone seeing `smartd` and thinking
  "monitoring, good" — months after and miles away from the thing that armed it.
- **Write the address, not the name.** `localhost` resolves to `::1` before `127.0.0.1`,
  and a great deal on this fleet binds IPv4 only — so the name reaches a listener that
  is not there and the error names something else entirely. It has cost time twice:
  zero's cloudflared spent months logging `dial tcp [::1]:8384: connect: connection
  refused` for a Syncthing that was running, and the laptop's `adb forward` hop failed
  with `kex_exchange_identification: Connection refused` while `adb forward --list`
  showed the forward plainly up. Both times the service was fine and the message pointed
  away from the cause. This applies to `HostName` in ssh_config, to `service:` in a
  cloudflared ingress, and to anything else where a literal costs nothing.
- **cloudflared prefers a tunnel's REMOTE configuration whenever one exists, and ignores
  local ingress silently** — no error, no log line, and an ignored local config looks
  identical to one in force at `127.0.0.1:20241/config`. So on a remotely-managed tunnel
  the dashboard is the authority and the repo's copy is a dated snapshot.
  **⚠︎ NO TUNNEL ON THIS FLEET IS REMOTELY MANAGED ANY MORE** — 2g finished on
  2026-08-29 and `hosts/<host>/system/cloudflared-config.yml` *is* the routing on all
  three. This entry used to name zero specifically and say the opposite of what is now
  true, which would have you go to the dashboard rather than install the tracked file.
  Kept because the rule still governs any remotely-managed tunnel you meet, and because
  `config_src` is create-time only: the way back to one is by accident, not by choice.
- **"Exited" is not "absent".** A stack with an exited container, a registered compose
  project, or surviving named volumes must be torn down properly. Deleting its files
  first orphans them permanently.
- **Measure before deleting.** A subvolume flagged as a dead remnant turned out to hold
  ~340 GiB. It was still the right call, but the size should have been in the ask.
- **Never call an improvising agent against infrastructure.** The Railway connector's
  `railway-agent` is the worked example (it restarted a live bot when told to remove a
  deployment); the rule is general. Direct tools, one named action each.

## Repo invariants

No `..` in compose files · every compose file declares `name:` · host-specific values
in gitignored `.env` (never `$HOME`) · `${VAR:?message}`, never `:-`, for anything whose
absence should stop Compose · the deployed image is a literal in `compose.yaml`, not a
variable · nothing boot-path is generated from a template.

**A dev container's tunnel hostname is `<alias>.<dns_zone>` and is never written beside
the alias it is built from.** `dns_zone` is in `ansible/group_vars/all.yml`; both ends
derive it — `create-dev-tunnel.yml` when it creates the CNAME, `configure-client-dev.yml`
when it writes the client block — so the two cannot name different hostnames. Adding a
fifth container is an alias and a port, nothing else. `-e hostname=` overrides for one
that does not follow the pattern, and `prepare-dev-host.yml`'s `tunnel_hostname` stays
explicit because absence is a setting there. The general rule: derive where the value is
a name, never where absence carries meaning.

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
so it cannot be used to skip the two-phase procedure above. It also does not
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

## Conventions

- Match the surrounding style: prose comments that say *why*, file headers that say what
  the file is for and what not to do to it, `make help` that is the Makefile's own header.
- A script that refuses is better than one that guesses — `bin/compose` refusing
  `destiny-director` by name, the Makefile failing with `docker: not found` off-host
  rather than silently ssh-ing. Keep that shape.
- Secrets live in gitignored `.env` files and on the boxes — never in git, never in a
  `.bak` beside the original, never in a handover block that will sit in scrollback.
