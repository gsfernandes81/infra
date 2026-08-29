# Ansible

## RUN THESE FROM THE CONTROL NODE, WHICH IS THE PHONE

**There is no `ansible` on `zero`, `one` or `two`, and there should not be** — they are
the boxes being managed. Every command in this file is typed in Termux. `fish: Unknown
command: ansible-playbook` on a Pi means you are on the wrong machine, not that something
is missing from it.

**The two client plays are the exception, and only because they target the client.**
`ssh-client.yml` and `dev-client.yml` write `~/.ssh/config` on whatever machine runs them
and reach no host at all, so they are run wherever that client is — the phone, or WSL on
the laptop, where one run also configures Windows. See *The laptop is two clients* below.
That is not a second control plane: neither play can touch a Pi.

The design and the reasoning are in
[`../docs/management-plane.md`](../docs/management-plane.md); this file is how to run it.

```sh
# in Termux
cd ~/infra/ansible
ansible fleet -m ping                       # transport works
ansible-playbook playbooks/audit.yml -K     # what runs where -> docs/fleet-inventory.md
```

**Not everything here is read-only any more, and the list is longer than it looks.**
`audit.yml` still is. Everything below changes something:

| play | what it can change |
|---|---|
| `packages.yml` | installs and removes packages on all three hosts |
| `system-files.yml` | writes tracked `/etc` copies — **boot-path files** — on all three |
| `cloudflared-update.yml` | replaces the cloudflared binary and cycles the connector (marked NOT IN USE; it refuses while a host autoupdates) |
| `cloudflare-tunnel-new.yml` | creates a Cloudflare tunnel and writes credentials at 0600 |
| `cloudflare-tunnel-cutover.yml` | **cycles a connector and repoints DNS** — there is a deliberate outage in it |
| `cloudflare-tunnel-retire.yml` | **deletes a tunnel. Irreversible** |
| `cloudflare-dev-tunnel.yml` | creates edge objects and prints a secret that cannot be re-fetched |
| the `*-client.yml` plays | write ssh config and a 0600 token on the client, not on a host |
| `authorize-dev-client.yml` | writes `authorized_keys` on `zero` and refreshes it inside containers |

Most take `--check`, and running that first is the habit: it is what caught the `docs`
metapackage before it landed on a 1 GB Pi. **The tunnel plays are the exception** —
`cloudflare-tunnel-new.yml` cannot be rehearsed that way at all, because the API create is
skipped in check mode and everything after it dies on undefined.

## The playbooks

| | |
|---|---|
| `audit.yml` | read-only; what runs where → `docs/fleet-inventory.md` |
| `packages.yml` | the declared package set on all three hosts |
| `dev-container.yml` | the **host** side of `infra-dev` on zero — secrets dir, deploy key, authorized_keys, `dev/.env` |
| `cloudflare-dev-tunnel.yml` | the **edge** side — tunnel, DNS, Access application and policy |
| `dev-client.yml` | the **client** side — one dev container's service token and `~/.ssh/config` block, **and the Windows half of the same laptop when run from WSL** |
| `ssh-client.yml` | the fleet's aliases in this client's `~/.ssh/config`, Windows included |
| **`this-client.yml`** | **the one you actually run** — the two above, composed: every ssh block this repo owns, and the dev-container registry |
| `authorize-dev-client.yml` | adds one client's **public** key to the dev containers' `authorized_keys` on `zero` — the host half of letting a new laptop or phone in |
| `_inventory-guard.yml` | not run directly — imported by the client plays so a run with no inventory fails instead of exiting 0 |

**`dev-container.yml`, `cloudflare-dev-tunnel.yml` and `dev-client.yml` are one job split
three ways, and the split is not arbitrary.** They
hold state in three different places, need three different credentials — sudo on zero, a
Cloudflare API token, an Access service token — and change at three different rates. A
single play would demand all three credentials to do any of it, and re-running it to add
a second client would put an API token back on the command line for no reason.

### One command, for whichever client you are on

**The reasoning behind every alias it writes is [`../docs/ssh-clients.md`](../docs/ssh-clients.md)**,
not this file and not the generated blocks. Those blocks keep only what you need with a
wedged connection in front of you; the background is in the doc. This section is how to
run it.

```sh
cd ~/infra/ansible
ansible-playbook playbooks/this-client.yml --check --diff   # see it first
ansible-playbook playbooks/this-client.yml
```

That is the fleet block, plus a block for every dev container, plus — from WSL — the
Windows side of the same laptop. It prompts once per container that has no service token
on this client, and not at all when they all do.

**`this-client.yml` is also the registry.** Its header table is where the dev containers'
ports and tunnel hostnames are recorded, because it is the file that consumes them: every
`<alias>-lan` written onto every client is built from that table, so a wrong number is
found by somebody using a rescue path rather than by somebody re-reading a comment. It
used to be a comment in or3's compose file — `../docs/management-plane.md` opens its drift
table with that as the worked example.

**When a container's tunnel does not exist yet:**

```sh
ansible-playbook playbooks/this-client.yml -e prompt_for_token=false
```

Writes every container that already has a token and skips the rest, naming each one. The
default is to prompt, which is right for a client being set up against a fully provisioned
fleet and wrong when half the tunnels are still Phase 5 — there, one unanswerable prompt
would stop the containers that *are* ready from being written.

### A new client needs two halves, and only one of them is `this-client.yml`

The ssh block and the service token are things a client *holds*. The key that admits it
is a fact about the **container**, and lives on `zero`:

```sh
ansible-playbook playbooks/authorize-dev-client.yml \
  -e client_pubkey_file=~/laptop.pub
```

A relative path is anchored to the directory you run from, not to `playbooks/` — which
is what a bare `lookup('file', …)` would have done, and would have looked for a key in
`ansible/playbooks/` that was sitting in `ansible/`. The file is read on the **control
node**, never on `zero`.

`Permission denied (publickey)` with a key visible in `ssh -v` means the client half is
right and this half has not been run. It appends — the phone's key is untouched — and it
refuses a secrets directory that is not there rather than creating one nothing mounts.

**Do not pass the key as `-e client_pubkey=ssh-ed25519 AAAA... you@host`.** Ansible's
`k=v` extra-var form splits on whitespace, so that arrives as the single word
`ssh-ed25519` — a truncation that still looks like a key. Use the file form above, or
JSON: `-e '{"client_pubkey": "ssh-ed25519 AAAA... you@host"}'`.

`dev-client.yml` still runs on its own for one container, which is the rotation path:

```sh
ansible-playbook playbooks/dev-client.yml -e alias=or3-dev -e hostname=or3-dev.gsrpi.uk \
  -e lan_port=2224 -e replace_token=true
```

### The laptop is two clients, and one run in WSL configures both

`dev-client.yml` and `ssh-client.yml` both write `~/.ssh/config` on the machine they run
on. On the laptop that is not one machine: Windows' `ssh.exe` and WSL's `ssh` read two
different configs, from two different homes, and neither can use the other's.

Windows cannot be an Ansible target without sshd on it. It does not need to be — from WSL,
`C:\Users\gavin` is a directory at `/mnt/c/Users/gavin`, so **one run in WSL provisions
both sides**:

```sh
# in WSL, in this directory
ansible-playbook playbooks/this-client.yml      # everything, both sides
```

| | WSL writes, for itself | WSL writes, for Windows |
|---|---|---|
| `ssh-client.yml` | `~/.ssh/config` | `C:\Users\gavin\.ssh\config` |
| `dev-client.yml` | `~/.ssh/config`, `~/.config/<alias>/token` (0600) | `…\.ssh\config`, `…\.config\<alias>\token`, `…\.ssh\cf-access-<alias>.cmd` |

Three things that are not obvious and have each cost a run:

- **WSL needs its own Linux `cloudflared`.** The laptop's is `cloudflared.exe`, which
  `command -v cloudflared` will not find and which the POSIX `ProxyCommand` — running
  under WSL's `/bin/sh` — could not exec anyway. The Windows half uses the Windows binary
  and is checked separately.
- **Windows has no `sh`**, so its `ProxyCommand` is `cf-access-<alias>.cmd`, generated
  from `templates/cf-access.cmd.j2`. It does what the `sh -c` does — load the token from a
  file, exec cloudflared — without the secret ever reaching a command line.
- **Ansible cannot set a mode on `/mnt/c`.** The Windows token is protected by the NTFS
  ACL `C:\Users\gavin` hands down; the play prints that ACL when it writes the file and
  deliberately does not assert on it. See `../docs/decisions.md`.

From Termux `/mnt/c` does not exist, the Windows half is skipped, and the block and the
wrapper are rendered to `~/ssh-dev-block-windows-<alias>.txt` to paste. **The token is
never rendered to that file** — a secret in something you open and copy out of is a secret
in scrollback.

### Run them from this directory, or they do nothing at all

`ansible.cfg` is read from the **cwd** and is the only thing pointing at `./inventory`.
Run a play from anywhere else and `hosts: control` matches nothing, so Ansible prints
`skipping: no hosts matched`, an empty recap, and **exits 0** — which on a phone screen
with `display_ok_hosts = False` looks a great deal like a clean run with nothing to do.

No task inside the play can catch that, because the play is skipped whole. So the client
plays import `playbooks/_inventory-guard.yml` above their own play; it matches
`localhost` (which Ansible provides even with no inventory) and fails, loudly, naming the
working directory as the usual cause.

**None of them starts anything, and there is no flag that makes them.** `dev/Makefile` is
the container's lifecycle interface and stays the only one — this repo's own split from
`../CLAUDE.md`: *check-system-drift reports and never writes; install-system-file writes
and never restarts.*

The principle is not the whole reason. `community.docker.docker_compose_v2` is installed
and an `up` task here would work, but **the Makefile does not merely run `docker compose
up`**: it passes `HOST_UID`/`HOST_GID` as build args read from the *owner of the checkout*
with `stat -c %u`, not from `id -u`, because under sudo `id -u` is 0 and a dev user built
at uid 0 writes root-owned files into the bind-mounted repo. It refuses to build at 0 at
all. A second copy of that guard is a guard that can be subtly wrong, and the way it would
be wrong is by corrupting ownership in a working tree.

So there is one interface, and the control node reaches it in one line instead of being
told to go somewhere else:

```sh
ssh -t zero 'cd ~/infra/dev && make up'      # or dev, restart, status, verify, logs
```

`-t` because `make` sudos and sudo wants a tty. `dev-container.yml` prints exactly this
line, filled in, when it finishes.

**`dev-container.yml` replaced `dev/seed-secrets.sh`, which is deleted.** Three of that
script's five steps were fleet access, which went with the control-node question being
deferred; what was left did not justify a bespoke script. That is the third time this
repo has traded hand-rolled shell for stock tooling — after `bin/compose` and after a
`cf-provision.sh` that lasted twenty minutes.

## Layout

| | |
|---|---|
| `ansible.cfg` | read from the **cwd**, so run from this directory |
| `inventory` | deliberately thin — `~/.ssh/config` owns the transport |
| `group_vars/all.yml` | where the report goes; applies to `localhost` too |
| `group_vars/fleet.yml` | the container CLI |
| `host_vars/` | four files: the three hosts' container runtimes, plus `localhost.yml`'s Termux fixes — see below |
| `playbooks/` | the ones above; `_inventory-guard.yml` is imported, never run |
| `playbooks/this-client.yml` | the dev-container registry lives in its header |
| `templates/` | the report, the two ssh blocks, and the Windows ProxyCommand wrapper |

## `-K`, and why it is not a wart

`gavin` is not in the `docker` group ([`../docs/decisions.md`](../docs/decisions.md): it
is root-equivalent) and NOPASSWD sudo is in
[`../docs/roadmap.md`](../docs/roadmap.md)'s *Not doing*. So reading the Docker socket
costs one sudo password per run. That is the right price for a human-run audit.

**It is also the reason Phase 7 cannot just schedule this playbook.** A scheduled
read-only audit from `two` would need passwordless sudo on `zero` and `one`, which this
repo refuses. The likely answer is the shape `bin/hw-inventory` already uses — each host
writes its own report locally, and Ansible fetches it unprivileged — but that is not
built, and pretending otherwise now would only find it later.

## ansible-core, plus three named collections

This fleet installs **`ansible-core`**, not the `ansible` metapackage — the metapackage
bundles about a hundred collections for AWS, Azure and VMware in order to talk to three
Raspberry Pis. The collections it actually needs are named in
[`requirements.yml`](requirements.yml) and installed deliberately:

```sh
ansible-galaxy collection install -r requirements.yml
```

**Check `ansible.builtin` first, then add a collection on purpose.** Two runs were lost to
reaching for things that were not there:

- `stdout_callback = yaml` lives in `community.general`, and core's `result_format = yaml`
  does the same job — so that one was a core setting all along.
- `ansible.builtin.apk` **does not exist and never did**; apk has always been
  `community.general.apk`. `playbooks/packages.yml` failed at its first task.

**The cost argument that shaped this was wrong, and correcting it changed a decision.**
The apk task was first rewritten by hand rather than adding a collection, on the belief
that collections were expensive over the phone's metered radio. Measured from Galaxy's API
on 2026-08-21: `ansible.posix` 0.16 MiB, `community.general` 2.70 MiB, `community.docker`
0.57 MiB. The ~50 MiB figure was the metapackage, not any one collection. The hand-rolled
version was then also inconsistent with dropping `bin/compose` for being repo-specific
knowledge, so it went.

`containers.podman` is 7.93 MiB and is **deferred** until Phase 7 needs it — see
`requirements.yml`. Adding a collection is still a decision with a number attached, and
the number belongs in `docs/data-ledger.md` in the or3 repo; it is just a smaller number
than this file used to claim.

## Where "prefer the standard tool" loses — the audit's `docker inspect`

`playbooks/audit.yml` reads containers with a hand-rolled `docker inspect --format`, not
`community.docker.docker_container_info`, and that is deliberate rather than left over.
It is the first case where the rule recorded in `docs/management-plane.md` does not win,
so the reason is here rather than assumed.

**Checked 2026-08-21, after two wrong guesses.** `docker_container_info` talks to the
Docker API through the Python Docker SDK on the *target*. The SDK is absent on `zero` and
`one`; Alpine does package it, as **`py3-docker-py`** (an earlier probe of mine looked for
`py3-docker`, found nothing, and nearly concluded it was unavailable). So adopting it is
possible — it costs `py3-docker-py` plus `py3-requests`, `py3-urllib3`,
`py3-websocket-client` and `py3-packaging` on two hosts.

Two things make the hand-roll the better answer here anyway:

- **The narrow format string is a safety property, not a style.** `docs/fleet-inventory.md`
  is committed to git. The format string extracts eight named fields, so `Config.Env` — which
  holds a live Discord token and a MySQL root password on the bot containers — is never in
  the data at all. `docker_container_info` returns the entire inspect dict, Env included,
  and one careless `to_nice_json` in the template would put those in git history. The
  module makes a leak possible that the current shape makes impossible.
  **Naming a seventh field is not the same act as widening**, and the one that was added —
  `.HostConfig.NetworkMode` — is what stopped the report being wrong: without it a
  host-networked or namespace-sharing container has no port mappings, so both Syncthings
  and `torrent` rendered a bare `—` under Published, which reads as "publishes nothing"
  and is false for all three. The bar is that a field is named, chosen, and known not to
  carry a secret; it is not that the list never grows. The eighth, `.Id`, is gathered and
  never rendered — it exists only so the template can turn NetworkMode's `container:<hex>`
  back into a name, because an id changes on every recreate and this file is committed.
- **The cost lands on the critical box.** Five Python packages on `zero` to replace four
  lines of shell that work is not what "more to type" meant.

`community.docker` still earns its place: **`docker_compose_v2` needs no SDK** — it invokes
the Compose CLI plugin directly, requiring only Docker CLI with compose ≥ 2.18.0 — which is
what makes retiring `bin/compose` at Phase 3 cheap. Worth knowing that it parses CLI output
rather than using an API, and upstream says a new Compose plugin release can break it; that
is a reason to keep `recovery.md`'s bring-back commands as plain `docker compose`, which
this repo was going to do anyway.

## The two things in here that are easy to break

**The `{% raw %}` guard in `audit.yml`.** Docker's `--format` is Go template syntax and
uses the same `{{ }}` delimiters as Jinja. Without the guard, Ansible tries to resolve
`.Name` as an Ansible variable and the task dies before Docker ever sees the string.

**`UNREADABLE` is not `None`.** A failed read and an empty result look identical, and
collapsing them is the wrong-reason pass this repo keeps designing against. The template
distinguishes them deliberately; every task carries `failed_when: false` so one
unreachable host does not abort the run, which means the *report* is the only thing that
can tell you a read failed. Do not simplify those branches away.

`check_mode: false` on the command tasks is the same idea from the other side: under
`--check`, `command` and `shell` are skipped by default, so a `--check` run would gather
nothing and print a clean report. A read is safe in check mode by definition.

## What is in `host_vars/`, and what is deliberately not

~~It is empty on purpose.~~ It holds four files: `zero.yml`, `one.yml` and `two.yml`, each
naming that host's container runtime and nothing else, and `localhost.yml`, which carries
the two Ansible defaults that are wrong on Termux (`~` is not `$HOME` there, and there is
no `/usr/bin/python3`).

**The reason it was described as empty is still true and is the useful part:** per-host
values are for when one stack needs different ones on different hosts, and **no stack in
this repo runs on two hosts.** Syncthing looks like it does and does not: `zero`'s syncs
the general share, `one`'s distributes completed torrents from inside the torrents stack.
Two jobs, two definitions.

`two.yml` is the one to read before adding anything here — it explains why that host must
never get docker back, and `group_vars/fleet.yml` explains why almost everything else
belongs there instead. Unexplained divergence between the hosts is the bug.

## Not audited

`two` is in `[fleet]` but not `[containerized]`: its one stack is leaving, its podman is
rootless under a different account, and reaching that account is work that buys nothing
for a box that is about to run no containers. It still reports OS facts.
