# Ansible

## RUN THESE FROM THE CONTROL NODE, WHICH IS THE PHONE

**There is no `ansible` on `zero`, `one` or `two`, and there should not be** — they are
the boxes being managed. Every command in this file is typed in Termux. `fish: Unknown
command: ansible-playbook` on a Pi means you are on the wrong machine, not that something
is missing from it.

**The `client-` play is the exception, and only because it targets the client.**
`client-home-ssh-config.yml` writes `~/.ssh/config` on whatever machine runs it and reaches
no host at all, so it is run wherever that client is — the phone, or WSL on the laptop,
where one run also configures Windows. See *The laptop is two clients* below. That is not
a second control plane: it cannot touch a Pi.

The design and the reasoning are in
[`../docs/management-plane.md`](../docs/management-plane.md); this file is how to run it.

```sh
# in Termux
cd ~/infra/ansible
# transport works
ansible fleet -m ping
# what runs where -> docs/fleet-inventory.md
ansible-playbook playbooks/server-generate-fleet-inventory.yml -K
```

## The playbooks, by what you want to do

Two prefixes. **`client-`** runs on the machine you type on and changes only it.
**`server-`** changes a Pi, or the Cloudflare edge in front of one, and runs from the
phone. A leading **`_`** is a half that one of these imports — not a thing you run.

| I want to… | Run | Needs |
|---|---|---|
| set up this phone or laptop: every ssh alias, every dev-container token, Windows too from WSL | `client-home-ssh-config.yml` | the [API token](#the-cloudflare-api-token) on this machine; it mints the Access tokens itself |
| rotate one dev container's token on this client, or add it once its tunnel exists | `client-home-ssh-config.yml -e only=or3-dev -e replace_token=true` | the same |
| let a new phone or laptop into the dev containers | `server-add-authorised-keys.yml -e client_pubkey_file=~/laptop.pub` | a route to `zero` |
| create a dev container: its tunnel, DNS, Access, and (for `infra-dev`) its host side | `server-create-dev-container.yml` · `-e name=or3-dev` for another | the [API token](#the-cloudflare-api-token) |
| see what runs where, read-only, into `docs/fleet-inventory.md` | `server-generate-fleet-inventory.yml -K` | sudo |
| install the packages each Pi should have | `server-install-packages.yml -K` · `--limit <host>` | sudo |
| install the tracked `/etc` files, without restarting anything | `server-install-system-files.yml -K` · `-l <host>` · `-e only=<file>` | sudo |
| create a tunnel for a Pi (nothing serves through it yet) | `server-create-tunnel.yml -e target=<host> -K` | sudo, the API token |
| move a Pi onto a new tunnel — **a deliberate outage** | `server-cutover-tunnel.yml -e target=<host> -K` | sudo, the API token |
| delete a Pi's tunnel — **irreversible** | `server-delete-tunnel.yml -e target=<host> -K` | sudo, the API token |
| update cloudflared on a Pi, deliberately | `server-update-cloudflared.yml -e target=<host> -e version=… -e sha256=… -K` | sudo; refuses while that host autoupdates, which today is all of them |

`--check --diff` first is the habit; it is what caught the `docs` metapackage before it
landed on a 1 GB Pi. **The tunnel plays are the exception** — `server-create-tunnel.yml`
cannot be rehearsed that way at all, because the API create is skipped in check mode and
everything after it dies on undefined; `server-create-dev-container.yml --check` does
every read for real and skips every write, which proves the token and shows what exists.

**Only `server-generate-fleet-inventory.yml` is read-only.** Every other `server-` play
changes something: packages, **boot-path `/etc` files**, the cloudflared binary, tunnels
and DNS, `authorized_keys` on `zero`. `server-create-dev-container.yml` prints a secret
that cannot be fetched again. `client-home-ssh-config.yml` writes ssh config and a 0600
token on the client.

The halves, for reading rather than running:

| | |
|---|---|
| `_client-fleet-ssh.yml` | the fleet's aliases in this client's `~/.ssh/config`, Windows included |
| `_client-dev-ssh.yml` | one dev container's service token and `~/.ssh/config` block, imported once per container |
| `_dev-container-tunnel.yml` | the **edge** side — tunnel, DNS, Access application and policy |
| `_dev-container-host.yml` | the **host** side of `infra-dev` on zero — secrets dir, deploy key, authorized_keys, `dev/.env` |
| `_assert-inventory.yml` | imported above every play that targets `control` or `fleet`, so a run with no inventory fails instead of exiting 0 |

**`server-create-dev-container.yml` runs the edge half, then the host half, in one go.**
Until 2026-10-04 they were three separately-run plays (the client half is still separate,
because it runs on each client), defended on the grounds that each needed a different
credential. Neither server half needs sudo, so the only credential the combined play asks
for is the API token — from a file now, see below — and the owner wanted one command. The
host half runs for `infra-dev` only, because it writes `dev/.env` in this checkout; the
other containers' host side lives in their own repos, and the play says so.

**`client-home-ssh-config.yml` is also the registry** of which dev containers exist and
which repo each lives in. No ports: since 2026-10-04 nothing is published on the host, and
break-glass is `ssh -t zero 'cd ~/infra/dev && make shell'`.

### One command, for whichever client you are on

**The reasoning behind every alias it writes is [`../docs/ssh-clients.md`](../docs/ssh-clients.md)**,
not this file and not the generated blocks. Those blocks keep only what you need with a
wedged connection in front of you; the background is in the doc. This section is how to
run it.

```sh
cd ~/infra/ansible
ansible-playbook playbooks/client-home-ssh-config.yml --check --diff   # see it first
ansible-playbook playbooks/client-home-ssh-config.yml
```

That is the fleet block, plus a block for every dev container, plus — from WSL — the
Windows side of the same laptop. **Nothing is typed.** For every container whose token this
client does not hold, the play mints one — this client's own, named `<container>-<client>`
— over the Cloudflare API, adds it to the container's Access policy and writes it to
`~/.config/<container>/token`. The only thing it needs for that is the
[API token](#the-cloudflare-api-token) at `~/.config/cloudflare/api-token` on this
machine; if that is missing it prints how to mint one and stops.

**When a container's tunnel does not exist yet** it has no Access application, so its
token is skipped with a message and the run carries on; its ssh block is written anyway,
and `ssh <c>` says the token is missing rather than failing obscurely. The ssh blocks and
the tokens are separate halves, tagged `ssh` and `access`:

```sh
ansible-playbook playbooks/client-home-ssh-config.yml --tags ssh      # every block; needs no API token
ansible-playbook playbooks/client-home-ssh-config.yml --tags access   # tokens only
```

`-e client=<name>` sets the name this machine's tokens carry; the default is `phone` on
Termux and `uname -n` elsewhere. It matters only at minting.

### A new client needs two halves, and only one of them is `client-home-ssh-config.yml`

The ssh block and the service token are things a client *holds*. The key that admits it
is a fact about the **container**, and lives on `zero`:

```sh
ansible-playbook playbooks/server-add-authorised-keys.yml \
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

One container at a time is `-e only=`, which is the rotation path:

```sh
ansible-playbook playbooks/client-home-ssh-config.yml -e only=or3-dev -e replace_token=true
```

`only`, not `alias`: each import inside the play pins its own `alias`, and an `-e alias=`
would outrank all four and configure one container four times. The hostname is not
passed. A dev container's is `<alias>.<dns_zone>`, and `dns_zone` is in
`group_vars/all.yml` so that this play and `server-create-dev-container.yml` cannot
disagree about it. Pass `-e hostname=` only for a container that does not follow the standard.

### The laptop is two clients, and one run in WSL configures both

Both halves of `client-home-ssh-config.yml` write `~/.ssh/config` on the machine they run
on. On the laptop that is not one machine: Windows' `ssh.exe` and WSL's `ssh` read two
different configs, from two different homes, and neither can use the other's.

Windows cannot be an Ansible target without sshd on it. It does not need to be — from WSL,
`C:\Users\gavin` is a directory at `/mnt/c/Users/gavin`, so **one run in WSL provisions
both sides**:

```sh
# in WSL, in this directory
ansible-playbook playbooks/client-home-ssh-config.yml      # everything, both sides
```

| | WSL writes, for itself | WSL writes, for Windows |
|---|---|---|
| the fleet half | `~/.ssh/config` | `C:\Users\gavin\.ssh\config` |
| the dev half, per container | `~/.ssh/config`, `~/.config/<alias>/token` (0600) | `…\.ssh\config`, `…\.config\<alias>\token`, `…\.ssh\cf-access-<alias>.cmd` |

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
wrapper are rendered to `~/ssh-dev-block-windows-<alias>.txt` for reference. **The laptop's
token cannot be made from there**: it is minted per client, so run the play in WSL, which
writes both of the laptop's sides.

### Run them from this directory, or they do nothing at all

`ansible.cfg` is read from the **cwd** and is the only thing pointing at `./inventory`.
Run a play from anywhere else and `hosts: control` matches nothing, so Ansible prints
`skipping: no hosts matched`, an empty recap, and **exits 0** — which on a phone screen
with `display_ok_hosts = False` looks a great deal like a clean run with nothing to do.

No task inside the play can catch that, because the play is skipped whole. So the client
plays import `playbooks/_assert-inventory.yml` above their own play; it matches
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

`-t` because `make` sudos and sudo wants a tty. `server-create-dev-container.yml` prints exactly this
line, filled in, when it finishes.

**The host half of `server-create-dev-container.yml` replaced `dev/seed-secrets.sh`, which is deleted.** Three of that
script's five steps were fleet access, which went with the control-node question being
deferred; what was left did not justify a bespoke script. That is the third time this
repo has traded hand-rolled shell for stock tooling — after `bin/compose` and after a
`cf-provision.sh` that lasted twenty minutes.

## The Cloudflare API token

One token per machine that runs playbooks — the phone, WSL, any client — at
`~/.config/cloudflare/api-token`, mode 600. Every play that talks to Cloudflare reads it
from there: the four `server-` tunnel plays, and `client-home-ssh-config.yml`, which uses
it to mint this client's Access service tokens. If the file is missing the play prints the
steps below (they live once, in `group_vars/all.yml`) and stops; nothing is ever prompted
for, because a prompt is a paste. It is never accepted on the command line
(`-e cf_api_token=` is refused), never in this repo gitignored or not (the checkout is
bind-mounted into `infra-dev`, whose point is having no route out), and never in
`$INFRA_SECRETS` (mounted into the container).

**One per machine, not one copied around.** Any token with the five permissions below
works, so mint a separate one on each machine, named for it: a lost laptop is then one API
token and one set of service tokens to delete, and the phone notices nothing.

**It must be a USER token, from My Profile — not an "Account API Token" from Manage
Account.** Every tunnel play proves the token first with `GET /user/tokens/verify`, and
an account-owned token fails that call outright even when its permissions are right.

### Minting it

In the Cloudflare dashboard, logged in as the account's owner:

1. Click the **profile icon** (top right) → **My Profile** → **API Tokens** in the left
   menu → **Create Token**.
2. Scroll past the templates to **Custom token** → **Get started**.
3. **Token name**: `infra-ansible-<machine>` (anything; this is how you recognise it later).
4. **Permissions** — one row each, using **Add more** for the extra rows. Each row is
   three dropdowns, left to right:

   | Scope | Permission group | Level |
   |---|---|---|
   | Account | Cloudflare Tunnel | Edit |
   | Account | Access: Apps and Policies | Edit |
   | Account | Access: Service Tokens | Edit |
   | Zone | Zone | Read |
   | Zone | DNS | Edit |

5. **Account Resources**: Include → **Specific account** → your account.
6. **Zone Resources**: Include → **Specific zone** → `gsrpi.uk`.
7. Leave **Client IP Address Filtering** empty — the phone's address changes. Leave
   **TTL** unset, or set a long one and expect to re-mint when it lapses.
8. **Continue to summary**, check the five rows read back as above, **Create Token**.
9. **Copy the token now.** Cloudflare shows it once; after this page it cannot be
   fetched again, only rolled.

Then on the phone, in fish, without the token touching history or a process list:

```fish
mkdir -p ~/.config/cloudflare; chmod 700 ~/.config/cloudflare
umask 077; read -s -P 'Paste the token, then Enter: ' tok; printf '%s\n' $tok > ~/.config/cloudflare/api-token; set -e tok
chmod 600 ~/.config/cloudflare/api-token
```

`read -s` reads without echo and without writing history; `printf` is a fish builtin, so
the value never appears in a process list. Then prove it, with a run that only reads:

```sh
cd ~/infra/ansible
ansible-playbook playbooks/server-create-dev-container.yml --check
```

It verifies the token first and names the cause if it fails: *not accepted at all* means
the paste is truncated, the token is expired or not yet active, or it is an account token
rather than a user one; *cannot read zone gsrpi.uk* means a permission row is missing.

### What the names mean, and why the dashboard and the API disagree

The dashboard's third dropdown says **Edit**; the API, and the per-endpoint "accepted
permissions" in Cloudflare's API reference, call the same permission **Write** (`Cloudflare
Tunnel Write`, `DNS Write`, `Access: Service Tokens Write`). They are one thing. Checked
2026-10-04 against three sources: the *Create API token* guide (the dashboard path and the
three dropdowns), the *API token permissions* reference (the group names, with their
Account/Zone scope), and the API reference pages for every endpoint the plays call
(`cfd_tunnel`, `teamnet/routes`, `access/service_tokens`, `access/apps` and their
`policies`, `zones`, `dns_records`). The union of what those pages list is the five rows
above, and nothing else: the plays never list accounts (the id comes from the zone, or
from a credentials file already on the box), and `/user/tokens/verify` needs no permission.

Which play uses which, so a 403 can be read: `client-home-ssh-config.yml` needs Zone Read
and both Access rows (it mints service tokens and edits policies); `server-create-dev-container.yml`
needs Cloudflare Tunnel, Zone Read, DNS and Access: Apps and Policies; `server-create-tunnel.yml`
needs Cloudflare Tunnel alone; `server-cutover-tunnel.yml` and `server-delete-tunnel.yml`
need Cloudflare Tunnel, Zone Read and DNS. One token carrying all five is the point.

### The Access service tokens are minted, not pasted

Each client mints its own, per container, named `<container>-<client>`, when
`client-home-ssh-config.yml` runs there, and adds it to the container's `non_identity`
policy without disturbing the tokens already in it. Nothing is shown. To revoke one client:
Zero Trust → Access → Service credentials → Service Tokens → delete `<container>-<client>`
(remove it from the application's policy first if Cloudflare refuses). The shared
`<container>` tokens of the old design stay valid until removed the same way; do that once
every client has re-run the play.

### Rotating or revoking it

**My Profile → API Tokens → the token's `⋯` menu → Roll** gives a new secret under the same
permissions; **Delete** kills it. Either way nothing already built stops working — tunnels,
DNS records, Access applications and service tokens do not authenticate with this token —
so the only follow-up is overwriting the file with the new value, by the same three lines
as above. A token that was ever on screen in a shared place is one to roll, not to keep.

## Layout

| | |
|---|---|
| `ansible.cfg` | read from the **cwd**, so run from this directory |
| `inventory` | deliberately thin — `~/.ssh/config` owns the transport |
| `group_vars/all.yml` | the fleet inventory's path and `dns_zone`; applies to `localhost` too |
| `group_vars/fleet.yml` | the container CLI |
| `host_vars/` | four files: the three hosts' container runtimes, plus `localhost.yml`'s Termux fixes — see below |
| `playbooks/` | the ones above; `_assert-inventory.yml` is imported, never run |
| `playbooks/client-home-ssh-config.yml` | the dev-container registry lives in its header |
| `templates/` | the report, the two ssh blocks, and the Windows ProxyCommand wrapper |

## `-K`, and why it is not a wart

`gavin` is not in the `docker` group ([`../docs/decisions.md`](../docs/decisions.md): it
is root-equivalent) and NOPASSWD sudo is in
[`../docs/roadmap.md`](../docs/roadmap.md)'s *Not doing*. So reading the Docker socket
costs one sudo password per run. That is the right price for a human-run inventory.

**It is also the reason Phase 7 cannot just schedule this playbook.** A scheduled
read-only run from `two` would need passwordless sudo on `zero` and `one`, which this
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
  `community.general.apk`. `playbooks/server-install-packages.yml` failed at its first task.

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

## Where "prefer the standard tool" loses — the inventory's `docker inspect`

`playbooks/server-generate-fleet-inventory.yml` reads containers with a hand-rolled
`docker inspect --format`, not `community.docker.docker_container_info`, and that is
deliberate rather than left over. It is the first case where the rule recorded in
`docs/management-plane.md` does not win, so the reason is here rather than assumed.

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

**The `{% raw %}` guard in `server-generate-fleet-inventory.yml`.** Docker's `--format` is Go
template syntax and uses the same `{{ }}` delimiters as Jinja. Without the guard, Ansible
tries to resolve `.Name` as an Ansible variable and the task dies before Docker ever sees
the string.

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
