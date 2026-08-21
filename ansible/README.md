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

## ansible-core only — no collections

This fleet installs **`ansible-core`**, not the `ansible` metapackage. The control node is
a phone on a metered radio, and the metapackage is roughly 50 MB of collections for AWS,
Azure and VMware in order to talk to three Raspberry Pis.

**So only `ansible.builtin.*` may be used here.** That is a real constraint, not a
preference, and it has already cost two runs:

- `stdout_callback = yaml` lives in `community.general`. Every playbook run failed on the
  callback until it was replaced with core's `result_format = yaml`, which does the same
  job and ships in core.
- `ansible.builtin.apk` **does not exist** — apk has always been `community.general.apk`.
  `playbooks/packages.yml` failed at its first task until it was rewritten with
  `ansible.builtin.shell` and `ansible.builtin.command`.

Before using a module or plugin here, check it is in `ansible.builtin`. If something
genuinely needs a collection, that is a decision with a data cost attached, and it belongs
in `docs/data-ledger.md` in the or3 repo alongside every other metered purchase — not in a
quiet `ansible-galaxy collection install`.

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
