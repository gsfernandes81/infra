# Ansible

The management plane, Phase 1. **Read-only — nothing here writes to a host.** The design
and the reasoning are in [`../docs/management-plane.md`](../docs/management-plane.md);
this file is how to run it.

```sh
cd ansible
ansible fleet -m ping                       # transport works
ansible-playbook playbooks/audit.yml -K     # what runs where -> docs/fleet-inventory.md
```

## Layout

| | |
|---|---|
| `ansible.cfg` | read from the **cwd**, so run from this directory |
| `inventory` | deliberately thin — `~/.ssh/config` owns the transport |
| `group_vars/all.yml` | where the report goes; applies to `localhost` too |
| `group_vars/fleet.yml` | the container CLI |
| `host_vars/` | empty, on purpose — see below |
| `playbooks/audit.yml` | the audit |
| `templates/` | the report |

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
  is committed to git. The format string extracts six named fields, so `Config.Env` — which
  holds a live Discord token and a MySQL root password on the bot containers — is never in
  the data at all. `docker_container_info` returns the entire inspect dict, Env included,
  and one careless `to_nice_json` in the template would put those in git history. The
  module makes a leak possible that the current shape makes impossible.
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

## `host_vars/` is empty on purpose

It is where per-host values go when one stack needs different ones on different hosts.
Nothing needs that yet — **no stack in this repo runs on two hosts.** Syncthing looks like
it does and does not: `zero`'s syncs the general share, `one`'s distributes completed
torrents from inside the torrents stack. Two jobs, two definitions. The directory exists
now so that adding the first real case is an addition rather than a restructure.

## Not audited

`two` is in `[fleet]` but not `[containerized]`: its one stack is leaving, its podman is
rootless under a different account, and reaching that account is work that buys nothing
for a box that is about to run no containers. It still reports OS facts.
