# SSH from a client

How a laptop or a phone reaches this fleet and the dev containers on it, and why each
part is shaped the way it is. **The generated blocks in `~/.ssh/config` point here.** They
used to carry this reasoning inline, which meant the dev-container explanation was
written into every client config once per container — 484 lines to say 130 lines of
configuration.

The configs themselves keep only what you need with a wedged connection in front of you.
Everything that is background rather than emergency is here.

## One command writes all of it

```sh
cd ~/infra/ansible
ansible-playbook playbooks/this-client.yml
```

Run it **wherever the client is** — the phone, or WSL on the laptop, where the same run
also writes the Windows side. It reaches no host in the fleet; it writes files on the
machine executing it. `ansible/README.md` is how to run it, including the flag for a
container whose tunnel does not exist yet.

Two blocks land in `~/.ssh/config`, each edited in place on re-runs:

| Marker | Written by | Holds |
|---|---|---|
| `# BEGIN infra-fleet` | `ssh-client.yml` → `templates/ssh-fleet-block.j2` | the three Pis, three ways each |
| `# BEGIN <container>` | `dev-client.yml` → `templates/ssh-dev-block.j2` | one dev container, three ways |

Do not hand-edit between the markers. Change the template and re-run — a hand edit
survives until the next run and then vanishes, which is the worst of both.

## Ordering: first value wins

`ssh` takes the **first** value it obtains for each keyword, so specific blocks go above
wildcards and `Host *` stays last. This is the opposite of `sshd_config`, where `Match`
blocks go last, and the two are easy to conflate.

Both playbooks therefore insert **before `Host *`** rather than appending. They used to
insert at the top of the file, which is a stronger claim than the requirement and had a
cost: the header a human wrote got pushed below the generated blocks, one block deeper
per dev container provisioned. If `Host *` is absent the block appends, which is right for
a file with no defaults section to lose to.

A note that must stay next to `Host *` belongs **inside** that block, indented, not above
it — anything above it is separated from it by the next block a playbook inserts.

## Three routes to a dev container

Each container gets three aliases. They are not redundancy for its own sake; each fails
for different reasons.

| Alias | Route | Fails when |
|---|---|---|
| `<c>` | its own tunnel → Access → the container's sshd | its tunnel, its Access app, its token, or Cloudflare |
| `<c>-sh` | the same, without `RemoteCommand` | the same |
| `<c>-lan` | `ssh zero nc 127.0.0.1 <port>` | zero's sshd, or Cloudflare |

**`ssh <c>` IS the claude session.** `RemoteCommand in-workspace abduco -A claude claude`
reattaches if one is already running, so the habit is one word rather than a remembered
incantation. Two concerns are deliberately split: `in-workspace` is a program in the
**image** and holds the one thing the container owns — where its work is, so no client
names that path. `abduco` is a property of **this link**: an ssh session from a phone dies
at the lock screen, so the session has to outlive it. A laptop on ethernet running
`ssh … 'git log'`, or a one-shot `claude -p`, wants the workspace and no abduco at all —
which a wrapper owning both would have made impossible.

**The caveat that comes with `RemoteCommand`:** `ssh <c> <command>` is then an error
(*cannot execute command-line and remote command*), and `scp`/`sftp` to that alias will
not work. `<c>-sh` exists for both. It is worth its own alias rather than
`ssh -o RemoteCommand=none <c>`, which nobody remembers under pressure.

### `-lan` is not a no-Cloudflare path

It is independent of the thing that usually breaks — **this container's** tunnel, its
Access application and its service token. A bad or expired token does not touch it, and a
wedged container sshd does not touch the other two.

But `Host zero` is `ssh-zero.gsrpi.uk` behind `cloudflared access ssh` — zero's **own**
tunnel — so a Cloudflare-wide outage takes `-lan` with it. The paths that survive that are
the LAN ones. From the LAN, `-lan` is one override away:

```sh
ssh -o ProxyCommand='ssh zero-local nc %h %p' infra-dev-lan
```

An earlier version of this text claimed `-lan` touched no Cloudflare at all. A comment
that names the wrong failure is read at the moment there is no time to check it.

### `nc`, not `ProxyJump`, for the containers

`-lan` targets `127.0.0.1:<port>` on zero, which zero's `PermitOpen` deliberately does not
include — so `ProxyJump` there is refused. A session channel running `nc` is not governed
by `AllowTcpForwarding` at all, so it reaches the container without relaxing sshd on the
internet-facing box. `nc` is busybox's on Alpine; `nc host port` is the one form busybox
and openbsd-nc agree on.

`ssh zero nc …` is the same line on every client, Windows included: Win32-OpenSSH provides
`ssh.exe`. **The fleet block is a prerequisite** — without it there is no `Host zero` to
reach, and the failure names something else.

## The fleet: three named paths to each Pi

```
<host>                    via that box's own cloudflared tunnel
<host>-local              direct on the LAN
<host>-zero|-one|-two     through another box, over the LAN
```

**Why the mesh exists.** On 2026-08-23 `two`'s tunnel was stopped while it was the only
configured route to it. There was no `two-zero` to fall back to and no key on zero or one
that reaches it, so the box was unreachable until a ProxyCommand was assembled by hand
under pressure. Every box is now reachable through both of the others.

`HostName` on the `-zero|-one|-two` aliases is resolved **on the jump host**, so those are
LAN addresses as it sees them.

### The jump rules, and what they depend on

`ProxyJump` since 2026-08-23: all three hosts set `AllowTcpForwarding yes` with
`PermitOpen` scoped to exactly the three LAN addresses on port 22
(`hosts/*/system/sshd-infra.conf`). Verified live in both directions on all three, and
with a negative test that a destination outside the list is refused.

**If that drop-in is ever removed**, `ProxyJump` fails with *administratively prohibited*
and these revert to `ProxyCommand ssh <host> nc %h %p`, which uses a session channel the
setting does not govern. That is what they were until that date, and it works with no
server-side change at all. Worth knowing during a rescue.

`*-zero` matches an alias **ending** in `-zero`, which is why no dev-container alias is
caught by it and nothing has to exclude them.

### `two` gets ChaCha20 first

`two` is an ARM1176 with no AES acceleration, where software AES is both slower and
exposed to cache-timing side channels. Ordered, not pinned — AES-GCM stays available, so
this rescue path cannot fail closed.

## One host key per box, and per container — not per path

Without a shared `HostKeyAlias`, each route keeps its own `known_hosts` entry. A
rarely-used path then has no stored key and simply prompts you to accept whatever it is
handed — during a rescue, which is exactly when you are least likely to check.

A container's key lives in a docker volume and survives rebuilds, so all three of its
routes meet the same key. To clear one later: `ssh-keygen -R <alias>`.

## Compression, and which end turns it on

Metering, not comfort. The client is the end of the session that holds claude's plaintext
output, which is text and compresses hard, and it is compressed before it is encrypted —
so what crosses the phone's radio is the smaller thing.

**The client is the half that turns it on.** sshd already permits it by default and
`dev/sshd_config` says so out loud, but ssh's own default is `no` and nothing is
negotiated unless both ends offer it. On `-lan` it costs a little CPU on a Pi for no
metered link, which is not worth a second `Host` block to avoid; a rescue session is not
where you tune throughput.

## Multiplexing

The first connection stays open and later ones reuse it, so a run of commands pays TCP and
auth setup once.

**Keyed by alias (`%n`), not by host.** `%C` and the usual `%r@%h:%p` both hash the
*resolved* address, so `zero-one` and `zero-local` would share one socket — and a rescue
path that silently reuses a working direct connection is not a test of anything.

**Omitted on Windows.** Win32-OpenSSH has never implemented multiplexing; setting it there
fails with `getsockname failed: Not a socket`, which reads like a network fault and is not
one. The playbook renders the Windows copy without it.

`~/.ssh/cm/` must exist or every multiplexed connection fails with an opaque
`unix_listener: cannot bind`. The play creates it.

## The phone as a jump host — Windows only

The `-s24` aliases have the laptop reach the fleet **through the phone**, over a USB
cable. This exists for the ship: the laptop has no internet, the phone does.

- `adb forward` runs as a **side effect** of `Match host s24 exec "adb forward …"`. ssh
  evaluates a `Match exec` while parsing, including when resolving a jump host, so the
  forward exists before s24 is dialled and `ssh zero-s24` is one command rather than two.
  If the phone is not attached, adb exits non-zero, the block does not apply, and you get
  a plain connection refused on `127.0.0.1:8022` — the right error, naming what is missing.
- **The targets are tunnel hostnames, not LAN addresses**, and that is the point: every
  byte of egress happens on the phone, which is the only one with a network. So the phone
  runs `cloudflared`, exactly as the mesh aliases have their jump host run `nc`. Not
  `ProxyJump`, which would open a raw TCP connection to `ssh-zero.gsrpi.uk:22` where
  nothing is listening — an `ssh://` ingress is not raw TCP at the edge.
- `127.0.0.1`, **not** `localhost`. ssh resolves `localhost` to `::1` first and
  `adb forward` binds IPv4 only, so the name gives
  `kex_exchange_identification: Connection refused` while `adb forward --list` shows the
  forward plainly up.
- **From WSL it cannot work**, and that is not an oversight to fix later: WSL2 has its own
  network namespace, so the forward Windows creates binds a loopback WSL cannot see — and
  `adb` is a Windows binary regardless. Rendering these aliases there would give WSL four
  addresses that resolve and never connect. From the phone it is pointless: `s24` would be
  its own sshd over loopback.
- `s24_user` is Android's uid for the Termux app and **changes if the app is
  reinstalled**. If `ssh s24` starts refusing, check that first.

## The service token, and where it is allowed to live

Each dev container sits behind a Cloudflare Access application admitting one service
token. The client holds it at `~/.config/<alias>/token`, mode 600, and the
`ProxyCommand` sources it:

```
ProxyCommand sh -c '. ~/.config/<alias>/token; exec cloudflared access ssh --hostname %h'
```

So the secret is in the environment of exactly one short-lived `cloudflared` and nothing
else. Three places it deliberately does **not** go:

- **not `set -gx` in fish's `conf.d`** — that puts a live credential in the environment of
  every process the account starts, for one command that runs when you ssh.
- **not in the `ProxyCommand`** — a secret on a command line is a secret in `ps` output
  and in shell history.
- **not in `~/.ssh/config`** — that file is routinely pasted, diffed and shared when
  something is wrong with it.

The file is POSIX `sh`, because `ProxyCommand` runs under `/bin/sh` whatever your login
shell is. fish syntax there fails with a message about `set` that names neither the file
nor ssh.

**The playbook will not accept the secret on the command line** — not "should not", it
refuses. `-e st_client_secret=…` silently *replaces* a `vars_prompt` rather than colliding
with it, so the play reads it with `ansible.builtin.pause`, which is a task and has no
variable name for `-e` to pre-empt. The Client ID is treated differently on purpose: it is
the username half, is not secret, and `-e st_client_id=…` is accepted.

Re-running does not ask again. `-e replace_token=true` is the rotation path; delete and
recreate is refused by Cloudflare while a policy references the token.

## Windows has no `sh`

Every POSIX client loads the token in one `ssh_config` line. Win32-OpenSSH cannot, and the
two shortcuts that close the gap are both refused — a `--service-token-secret` flag puts a
live credential in the process list, and `setx` puts it in the environment of every
process the account starts.

So the load-then-exec becomes `%USERPROFILE%\.ssh\cf-access-<alias>.cmd`, generated from
`ansible/templates/cf-access.cmd.j2`. It `setlocal`s, reads the two values off `findstr`'s
**stdout** (not its argv, which is the half a process list shows), and runs the Windows
`cloudflared`. Same guarantee, spelled for the shell that is actually there. Batch has no
`exec`, so cloudflared is a child of the wrapper rather than a replacement for it — two
processes per session, which is the cost.

**The Windows token's permissions are printed, not asserted.** `/mnt/c` is drvfs and
carries no Unix mode, so `mode: "0600"` there either fails or silently does nothing, and a
task that pretends to have set a mode is worse than one that does not try. What protects
that file is the NTFS ACL `C:\Users\gavin` hands down. The play runs `icacls` through WSL
interop and shows you the result; it does not judge it, because nothing in the control
plane can see that laptop to calibrate the check against.

**WSL needs its own Linux `cloudflared`.** `command -v cloudflared` will not find
`cloudflared.exe`, and the POSIX `ProxyCommand` runs under WSL's `/bin/sh`, not under
Windows.

## The dev containers' second door

`ssh-zero-dev-dd.gsrpi.uk` and `ssh-zero-dev-ds.gsrpi.uk` are rules on **zero's** host
tunnel pointing at those containers' loopback ports. Now that every container runs its own
connector behind its own hostname and token, they are a second door to each — a different
door with a different trust story.

No client alias points at them. `dd-dev` and `ds-dev` are not running until they are
deployed with a connector of their own, at which point `dev-client.yml` gives them the
same three aliases every other container has — so an alias for the old door would name a
hostname with nothing behind it, which fails exactly like a container being down.

Dropping the alias does not close the door, and nothing about this pretends it does. The
rules are still on zero. Closing them edits
`hosts/zero/system/cloudflared-config.yml` and cycles zero's connector, which is
[`management-plane.md`](management-plane.md)'s phase 2i and the owner's to run — from a
mesh route, since `ssh-zero.gsrpi.uk` **is** the tunnel being cycled.

`ssh-zero-dev-or3` was already dead when its alias went: the ingress rule came off in
`7bb2075`, so the alias named a hostname with no route behind it — which fails exactly
like the container being down.
