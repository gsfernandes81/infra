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
ansible-playbook playbooks/client-home-ssh-config.yml
```

Run it **wherever the client is** — the phone, or WSL on the laptop, where the same run
also writes the Windows side. It reaches no host in the fleet; it writes files on the
machine executing it. `ansible/README.md` is how to run it, including the flag for a
container whose tunnel does not exist yet.

Two blocks land in `~/.ssh/config`, each edited in place on re-runs:

| Marker | Written by | Holds |
|---|---|---|
| `# BEGIN infra-fleet` | `client-home-ssh-config.yml` (its fleet half) → `templates/ssh-fleet-block.j2` | the three Pis, three ways each |
| `# BEGIN <container>` | `client-home-ssh-config.yml` (its dev half, once per container) → `templates/ssh-dev-block.j2` | one dev container, two ways |

Do not hand-edit between the markers. Change the template and re-run — a hand edit
survives until the next run and then vanishes, which is the worst of both.

**The marker names the playbook, so renaming a playbook orphans its blocks.** The run
after the 2026-08-29 rename found no block under the new marker and inserted a second
one *below* the old, which ssh then never read past: on the phone, `ssh infra-dev` kept
attaching `abduco` after the template had moved to the door, and that was only the change
visible enough to notice — any edit since the rename to a keyword the old block also set
reached the file and lost to the block above it. Each play now removes its block under
the pre-rename marker (`ssh-client.yml`, `dev-client.yml`) before writing its own, and on
the laptop's Windows side also the bare `# BEGIN infra-fleet` the Termux paste file used to
carry. The paste file now uses the real marker, so a pasted block is adopted by the next
run from WSL rather than shadowing it.

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

Each container gets **one route and one alias**; `<c>-sh` is a second name for it.

| Alias | Route | Fails when |
|---|---|---|
| `<c>` (and `<c>-sh`) | its own tunnel → Access → the container's sshd | its tunnel, its Access app, its token, or Cloudflare |

**The container decides what a login runs, not the client** (2026-10-04, infra#7). Its sshd
forces every session through `claude-sessions-door` (`dev/sshd_config`, `ForceCommand`),
and the client block is transport only — `HostName`, `User`, `ProxyCommand`, the host key
and the identity. So:

| You run | You get |
|---|---|
| `ssh <c>` | **the session menu** — every session in the container, `Enter` to attach or resume, `n` for a new one, `q` to leave |
| `ssh <c> 'git log'` | the command, in `~`, exactly as any ssh runs it — `ssh <c> in-workspace git log` for the repo |
| `scp`, `sftp`, Zed, ansible | work, as against any sshd; `scp file <c>:` lands in `~` |
| `ssh -t <c> in-workspace` | a login shell in `/workspace` |
| `ssh -T <c>` | a login shell with no terminal |
| `ssh -N -L/-R …` | the forward, untouched — `-N` opens no session, so the door never runs |

Each session the menu opens is an abduco session, so it outlives the link: an ssh session
from a phone dies at the lock screen, and the work must not. The door never locks you out:
a menu that cannot run (too narrow a terminal, a missing binary) says why and drops to a
login shell.

**A container whose base predates 2026-10-04 answers `ssh <c>` with its plain login shell**
— the old `-sh` behaviour, not an error — until its repo bumps `BASE_TAG`; the menu is then
`claude-sessions-door` by hand. The client cannot name a program the image lacks any more,
which is what used to make a not-yet-bumped child answer `exec: claude-sessions-door: not
found`.

**Before 2026-10-04** the main alias carried `RequestTTY yes` and `RemoteCommand in-workspace
claude-sessions-door`, which made `ssh <c> <cmd>` a client-side error (*cannot execute
command-line and remote command*) and scp/sftp to it unreliable; `<c>-sh` existed for both.
A client not yet re-run still has that block and keeps working: its `RemoteCommand` arrives
at the forced door as a command, and the door runs it — `in-workspace` then starts the door
again, which this time sees a login. `<c>-sh` is kept as a name so tools that use it
(`server-add-authorised-keys.yml`, or3's phone tunnel) need no change, and goes once nothing does.

### Break glass by hand — there is no third alias

**Dropped 2026-08-31.** Every container used to get a `<c>-lan` that reached its sshd on
`127.0.0.1:<port>` through the host's own sshd, independent of that container's tunnel,
Access application and token — the set of things that actually breaks. The path is still
there. Only the alias went:

```sh
ssh <host>                              # zero today; the container's host, whichever it is
ssh -p <port> dev@127.0.0.1             # from that shell. Ports: ansible/playbooks/client-home-ssh-config.yml
```

**Why an alias was the wrong shape for it.** The generated block had `ProxyCommand ssh
zero nc %h %p` with `zero` written in, because a client-side alias must name the host the
container sits on — and that is the one fact a movable container does not have. A dev
container is designed to move (`management-plane.md` § *Placement*), and the day one did,
the rescue alias would have pointed at the wrong box: a break-glass path that fails only
when you need it is worse than none, because you spend the outage trusting it.

**It was never a no-Cloudflare path anyway.** `Host <host>` is that box's own tunnel
behind `cloudflared access ssh`, so a Cloudflare-wide outage takes the first hop with it.
The paths that survive that are the LAN ones — `<host>-local`, below. An earlier version
of this text claimed otherwise, and a comment that names the wrong failure is read at the
moment there is no time to check it.

**If you want it in one line from a client**, `ProxyJump` will not do it: the target is
`127.0.0.1:<port>` on the host, which `PermitOpen` deliberately does not include, so the
jump is refused. A session channel running `nc` is not governed by `AllowTcpForwarding` at
all, which is what the old alias exploited:

```sh
ssh -o ProxyCommand='ssh zero nc %h %p' -p 2225 dev@127.0.0.1
```

`nc` is busybox's on Alpine; `nc host port` is the one form busybox and openbsd-nc agree
on, and `ssh <host> nc …` is the same line on every client, Windows included.

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
negotiated unless both ends offer it. On a break-glass session from the LAN it costs a
little CPU on a Pi for no metered link, which is not worth a second `Host` block to
avoid; a rescue session is not where you tune throughput.

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
ProxyCommand sh -c 'if [ -r ~/.config/<alias>/token ]; then . ~/.config/<alias>/token; exec cloudflared access ssh --hostname %h; fi; echo "<alias>: no Access token at … - run …" >&2; exit 1'
```

(abbreviated; the real line names absolute paths and the exact run). **The ssh block and
the token are separate, and the block does not need the token to be written.** A client
gets a block for every container in the registry, up or not; one without a token says so
on `ssh <c>` and stops **before `cloudflared` starts** — never falling through to Access's
browser login, which these apps do not admit (service tokens only) and which is no use
from Termux anyway. The split is in the playbook too, as tags:

```sh
ansible-playbook playbooks/client-home-ssh-config.yml --tags ssh      # every block, no prompts
ansible-playbook playbooks/client-home-ssh-config.yml --tags access   # tokens only
```

At the prompt, **leave both the Client ID and the Client Secret blank to skip that
container's token** — the run carries on to the next one. One blank and one not is
refused as a slip. Until 2026-10-02 a blank stopped the whole composed run, and a
container without a token got no block at all.

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

**The wrapper is CRLF and ASCII-only, and both are load-bearing.** cmd.exe seeks by byte
offset between commands in a batch file and miscounts on an LF-only one, resuming mid-line
and running fragments of the comments as commands; and it reads the file in the console
codepage, so an em dash arrives as several bytes of something else. `_client-dev-ssh.yml` writes
it with `newline_sequence: "\r\n"`.

**The laptop's `ssh_config` is the opposite on endings — LF — and ASCII like the
wrapper.** Both plays convert it to LF before any `blockinfile` touches it — and the
client's own `~/.ssh/config` too, on every client, the phone included; on the laptop's WSL
side it turned out to be CRLF as well. It matters because `blockinfile` finds its block by
comparing each line to the marker plus `os.linesep`, `"\n"` under WSL. Once anything has
saved the file as CRLF, no marker matches: the next run writes a second block *under* the
first, the pre-rename removals find nothing, and ssh reads the stale copy — first value
wins. LF is the only ending `blockinfile` can write from WSL, and Win32-OpenSSH reads it
fine, so the whole file goes to LF rather than round-tripping. The conversion is `grep`
then `sed`, not `replace`, which opens files with universal newlines and never sees a
`\r`. `--check` cannot convert, so on a CRLF file its diff shows a second block that the
real run will not write, and the run says so. The generated blocks are ASCII because that
file is opened and edited under a Windows codepage, where `—` and `─` arrived as several
characters of something else; each play refuses a template with anything outside printable
ASCII. **Your own lines are yours:** the plays convert their endings but never rewrite
their text, so a hand-kept header drawn with box characters stays that way until you
redraw it.

**`IdentityFile` and `IdentitiesOnly` appear only if that client has the key.** With
`IdentitiesOnly yes`, ssh offers an agent key only when its public half matches a named
file — so on a client whose key lives in an agent and never on disk, naming a missing file
leaves ssh nothing to offer and you get `Permission denied (publickey)`. The two sides of
the laptop are checked separately, because `~` in WSL is not `C:\Users\gavin`.

**The Windows token's permissions are printed, not asserted.** `/mnt/c` is drvfs and
carries no Unix mode, so `mode: "0600"` there either fails or silently does nothing, and a
task that pretends to have set a mode is worse than one that does not try. What protects
that file is the NTFS ACL `C:\Users\gavin` hands down. The play runs `icacls` through WSL
interop and shows you the result; it does not judge it, because nothing in the control
plane can see that laptop to calibrate the check against.

**WSL needs its own Linux `cloudflared`.** `command -v cloudflared` will not find
`cloudflared.exe`, and the POSIX `ProxyCommand` runs under WSL's `/bin/sh`, not under
Windows.

## Letting a new client in

Two halves. The ssh block and the service token are things a client *holds*;
`client-home-ssh-config.yml` writes those. The key that admits it is a fact about the **container**:

```sh
ansible-playbook playbooks/server-add-authorised-keys.yml -e client_pubkey_file=~/laptop.pub
```

`Permission denied (publickey)` with a key visible in `ssh -v` means the client half is
right and this one has not been run.

**It does not restart anything, and must not.** `dev/entrypoint.sh` copies the
`authorized_keys` out of the read-only secrets mount at start-up, and `sshd_config` names
that copy — so the play refreshes the copy inside each container over its `-sh` alias.
Restarting sshd would be the wrong tool: sshd is **exec'd as PID 1**, so restarting it
restarts the container and every detached abduco session goes with it. It is also
unnecessary — sshd reads `AuthorizedKeysFile` on each authentication attempt, not at
start-up.

`dd-dev` and `ds-dev` are excluded: their drop-in names its own `AuthorizedKeysFile` and
serves the host account's keys, so add the key to `gavin`'s `~/.ssh/authorized_keys` on
zero for those.

## The dev containers' second door

`ssh-zero-dev-dd.gsrpi.uk` and `ssh-zero-dev-ds.gsrpi.uk` are rules on **zero's** host
tunnel pointing at those containers' loopback ports. Now that every container runs its own
connector behind its own hostname and token, they are a second door to each — a different
door with a different trust story.

No client alias points at them. `dd-dev` and `ds-dev` are not running until they are
deployed with a connector of their own, at which point `client-home-ssh-config.yml` gives them the
same block every other container has, one route under two names — so an alias for the old door would name a
hostname with nothing behind it, which fails exactly like a container being down.

Dropping the alias does not close the door, and nothing about this pretends it does. The
rules are still on zero. Closing them edits
`hosts/zero/system/cloudflared-config.yml` and cycles zero's connector, which is
[`management-plane.md`](management-plane.md)'s phase 2i and the owner's to run — from a
mesh route, since `ssh-zero.gsrpi.uk` **is** the tunnel being cycled.

`ssh-zero-dev-or3` was already dead when its alias went: the ingress rule came off in
`7bb2075`, so the alias named a hostname with no route behind it — which fails exactly
like the container being down.
