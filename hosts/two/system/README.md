# hosts/two/system

**Raspberry Pi Model B Plus Rev 1.2, `armv6l`, 512 MB** (confirmed Aug 2026) —
single-core ARM1176 at 700 MHz, 100 Mbit ethernet sharing a USB 2.0 bus, no crypto
acceleration. `MemTotal` is 486 272 kB, so **~475 MB usable**, not the ~490 MB an
earlier note here and in `docs/host-setup.md` claimed. Alpine **3.24.1** (not 3.23 —
package names moved between the two; see `hosts/two/setup/root-setup.sh` §3).

`two` does **not** join the MicroOS fleet — its armv6 was the only thing that would
have forced the whole fleet onto Debian, and armv6 also rules out Claude Code (arm64
and x86-64 only). It is kept, powered on, for a different job.

## What changed, Aug 2026

`two` now also runs the **destiny-director test bot** — see
[`deployments/destiny-director/`](../../../deployments/destiny-director/), reachable
here as [`hosts/two/destiny-director`](../destiny-director). That is a real change to
this box's brief, and the tension with the lifeboat role is recorded in
[`docs/decisions.md`](../../../docs/decisions.md).

With it come three host changes:

- **Docker and containerd are removed**, and **rootless podman + podman-compose**
  replace them. `gavin` is not in any new group and no new user is created; rootless
  podman's isolation comes from the user namespace, not from which uid owns it.
- **`python3` is now installed** as a dependency of `podman-compose` 1.6.0. That
  removes the stated objection to tracking `/etc` files here (see below): the
  interpreter `bin/check-system-drift` needs is no longer a cost this box would pay
  only for the checker's sake.
- **`/usr/local/bin/dd-ctl`** — a restricted SSH forced command, root-owned, the only
  thing the deploy key can run. Its canonical copy is
  [`deployments/destiny-director/dd-ctl`](../../../deployments/destiny-director/dd-ctl).

The privileged half is [`../setup/root-setup.sh`](../setup/root-setup.sh) — one
reviewable script, `sh`-invoked, mode 0644 so it is never on a PATH.

> **Status: not applied as of 2026-08-06.** The script has been reviewed and syntax
> checked, and nothing in it has been run on the box. Docker removal is opt-in behind
> `DD_REMOVE_DOCKER=1` and is a separate second run. Treat the three bullets above as
> the intended end state, and confirm on the box before writing them down as fact.

## Its job: the lifeboat

Five jobs, all tiny, all suited to hardware that cannot do anything demanding:

1. **Serial console** to `zero` and `one` — a login prompt when a box has dropped to
   emergency mode with no network.
2. **Power-cycle authority** via a smart plug.
3. **Dead-man's switch** — reports the other hosts' health outward, because a watchdog
   running on the box being watched is not a watchdog.
4. **Boot-integrity monitoring** — boot time, `/boot` hash, block-device inventory.
   This is what makes remote unlocking of `zero`'s encrypted volume defensible: it
   turns "I have no idea whether anyone touched it" into a decision you can actually
   make.
5. **Independent access path** — Tailscale or WireGuard, separate from cloudflared.

The full case, and the trust logic behind job 4, is in
[`docs/roadmap.md`](../../../docs/roadmap.md#5-two--keep-it-as-the-lifeboat).

**Stays on Alpine. It is a `sys` install today, not diskless** — root on
`/dev/mmcblk0p2`, 29 G with 27 G free (verified over SSH, Aug 2026). This section
previously read as though diskless were already done; it is not, and
[`docs/host-setup.md`](../../../docs/host-setup.md) had it right all along.

Diskless — running from RAM with the SD card read-only, committed via `lbu commit` —
remains the argument for the lifeboat: the box whose purpose is surviving other boxes'
failures should be the one least able to die of SD-card corruption. But it is now in
tension with what else is on here. A 512 MB board cannot hold its OS image in RAM
*and* Postgres's buffers, and an unsynced diskless system loses Postgres's data
directory on power loss. Whichever way that is settled, settle it in
[`docs/decisions.md`](../../../docs/decisions.md) rather than by drifting.

**Swap: there is none.** Verified Aug 2026 — no zram, no swap file, no swap partition.
`docs/host-setup.md` said `two` runs zram; it does not, and Alpine's `zram-init`
package cannot be enabled either of the two ways that doc described. There is no OpenRC
service and no `/etc/conf.d/zram-init` — both are Gentoo's packaging — **and the
invocation it gave would not have run either**: it passed `-s 1`, which is not in that
script's `getopts`. The real `armhf` binary answers `Illegal option -s` and exits, so
the documented command failed while both files went on describing `two` as running zram.
The verified line is `zram-init -d 0 -p 100 256`. `root-setup.sh` §9 runs that, **live**,
and it does not survive a reboot, because persisting it means boot-path code on the
lifeboat box.

Nothing household-critical goes here: no DNS, no backups, no log sink. A test bot is
not household-critical either — but it does put a continuous Postgres write load on a
decade-old SD card, which is the cost worth watching.

## Tang is not currently possible here

Alpine packages **neither `tang` nor `clevis`** — checked Aug 2026 across `main`,
`community` and `edge`, on `armhf`, `armv7` and `aarch64`. Only `jose`, their
dependency, is present. So tang cannot be `apk add`-ed on this box, and it would mean
either building from source on a 700 MHz CPU or switching to Raspberry Pi OS, which
does package both for armhf.

That decision is on hold anyway, and for a better reason: a tang server sitting beside
`zero` doesn't protect against theft, it just means the thief takes two boxes instead
of one. See the roadmap before doing anything here.

## Tracked `/etc` copies

**Still none.** This is a reference directory, and `bin/check-system-drift two` only
reports differences. Nothing here is applied to the host.

`/usr/local/bin/dd-ctl` is the obvious candidate and is deliberately **not** one. Its
single canonical copy lives beside the stack it drives, at
[`deployments/destiny-director/dd-ctl`](../../../deployments/destiny-director/dd-ctl),
with no second path to it anywhere — a script reachable two ways is a script whose
behaviour can depend on which way you came. It therefore carries no `infra-` header,
because `bin/_infra.py` is the single parser for those and it only ever looks in
`hosts/<host>/system/`; a header no parser reads would be decoration dressed as a
checked invariant. The live copy is installed by `root-setup.sh` §4 and compared by
hand:

```sh
md5sum /usr/local/bin/dd-ctl ~/infra/deployments/destiny-director/dd-ctl
ls -ln  /etc/fish/config.fish ~/.profile ~/.config/fish/config.fish
ls -lnd ~ ~/.config ~/.config/fish ~/.config/fish/conf.d
ls -ln  ~/.config/fish/conf.d/          # expect podman.fish, and nothing else
```

**The `md5sum` alone is not the drift check**, and the four lines under it are not
padding — see "the login shell is in the TCB" below. A matching hash while
`~/.config/fish/conf.d/` has gained a second file is a green light for a dispatcher that
no longer decides anything.

**The installed copy must be a real file owned by root, mode 0755, in a directory only
root can write** — never a symlink into the checkout, and never the checkout's copy run
in place. `gavin` owns `~/infra`, so a forced command resolving through anything gavin
can rewrite is not a restriction at all: replace the target, get a shell. `root-setup.sh`
§4 verifies all three properties after installing rather than trusting `install` to
have produced them.

## The login shell is in the deploy key's TCB

**sshd does not exec a forced command. It runs `$SHELL -c "<command>"`** — and `gavin`'s
login shell is fish, which reads `/etc/fish/config.fish`,
`~/.config/fish/conf.d/*.fish` and `~/.config/fish/config.fish` on *every* startup,
including a non-interactive `-c`. Only `fish -N` skips them. So four files run, as
`gavin`, before `/usr/local/bin/dd-ctl` is reached, and any one of them can replace the
dispatch entirely.

That defeats the section above one level up. `/usr/local/bin/dd-ctl` being root-owned
and unwritable is still true and still worth having; it is just not sufficient, because
the thing that *decides whether dd-ctl runs at all* is a file `gavin` owns by
construction — and `root-setup.sh` §8 writes one of them itself. `restrict` does not
help: it implies `no-user-rc`, which governs `~/.ssh/rc`, an unrelated file.

What is actually done about it:

- `root-setup.sh` §4 checks all four files' ownership and modes, **and the directories
  holding them** (`~`, `~/.config`, `~/.config/fish`, `~/.config/fish/conf.d`,
  `/etc/fish`) — because a writable directory lets a file be replaced by unlink-and-
  create, which no check on the file itself can see. It warns on anything in `conf.d/`
  that it did not write.
- `dd-ctl` re-execs itself under `env -i`, keeping four names, so nothing fish exported
  reaches podman.
- The drift check above lists those paths, so a hash comparison cannot pass while the
  shell that runs first has changed.

**None of that removes the residual, and it is not claimed to.** `gavin` can always
write `gavin`'s dotfiles. The only arrangement that takes the ambient shell out of this
key's trusted computing base is a **dedicated deploy account with `/bin/sh` and an empty
home** — which [`docs/decisions.md`](../../../docs/decisions.md) rejected, on reasoning
that did not have this fact in it. That entry now states the trade with the fact
included. The decision has not been reversed here; it has been re-stated honestly, which
is the difference between a settled decision and one resting on a false premise.

## `dd-ctl` is not signed off

**`gavin` is in `wheel` and `sudo` is installed.** So anything that escapes the
`dd-ctl` forced command lands on an account that can become root. The dispatcher is the
entire boundary and there is nothing behind it. Nothing in this repo describes it as
contained or unprivileged, and nothing should.

Its design answer is to give hostile input almost nothing to act on: six verbs
(`deploy-beacon`, `deploy-anchor`, `down`, `status`, `logs`, `logs-postgres`), **none of
which takes an argument**, matched against exact literals and then discarded. But `sh
-n` is a syntax check, not a review, and that is all this repo has run against it. A
dedicated adversarial read is outstanding. What it still owes:

| Question | Why it is the question |
|---|---|
| How is `SSH_ORIGINAL_COMMAND` handled end to end? | It is one string compared against literals and dropped — but that is a claim about the code, verified by reading it, not by anything automated. |
| What does each fixed command line actually *do*? | The verbs are fixed, so the remaining risk is in what they invoke. A `git pull`-shaped verb would hand control of the deployed `compose.yaml` to whoever controls the git remote; there is none today, and there must not be one. |
| Can the deployed stack gain a writable mount under `$HOME`? | A bind mount over `~/.ssh` would let the keyholder strip `restrict` from their own `authorized_keys` line and walk out of the forced command entirely. |

On that last one: **`compose.yaml` uses only named volumes** (`pgdata`, `sshhostkeys`),
and as of 2026-08-06 that is **enforced, not merely observed**. `dd-ctl` refuses to
deploy if `compose.yaml` declares a volume whose source is not a bare name, and refuses
again after `up` — stopping and removing the container — if `podman inspect` reports a
mount of type `bind`. Two layers because they fail differently: the first is a text scan
that cannot destroy anything, the second asks podman and catches what the scan does not
model.

> The second layer is **uncalibrated**. It rests on podman's `.Mounts` listing only
> user-requested mounts, which has not been checked against this box. Per this repo's
> own rule, calibrate before trusting the verdict: run
> `podman inspect --format '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' dd-bot`
> and expect exactly one `volume|…|/home/dd/.ssh-host` line. Watch the first deploy
> after this change; if it refuses, suspect the check before the box.

**The trust boundary that is not about `dd-ctl` at all:** `compose.yaml` names a moving
branch tag, so anyone with push access to that branch decides what runs as `gavin` on
the next deploy. See [`docs/decisions.md`](../../../docs/decisions.md).

**Known gap, for when a tracked executable does land here:**
`bin/install-system-file`'s `validators_for()` keys on `live.parent == /etc/init.d` and
on the filename `fstab`, so an executable installing anywhere else would get **no**
post-install check — not even `sh -n`. Widening it is the right fix, but this repo's
own rule is to calibrate a new validator against known-good state first, and there is
currently no tracked file of that shape to calibrate against. Add the file and the
validator together.
