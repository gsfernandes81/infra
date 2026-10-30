# Decisions

Settled. The reasoning is here so it doesn't get re-derived — argue with the reason,
not from scratch.

Rows marked ⚠︎SUPERSEDED describe the `dd-ctl` / `root-setup.sh` era on `two`. See the
boxed note in "`two` also runs a test bot" below for what replaced them and why.

Until 2026-10-24 this repo called a deployment — a Compose project under
`deployments/<name>/` — a "stack" (`-e stack=`, `server-create-stack-tunnel.yml`). Older
entries keep the old word.

| Decision | Because |
|---|---|
| Named `infra`, not `containers` | It holds host system config too. |
| `deployments/` canonical, `hosts/` symlinks in | Lets each host move to a different distro without touching stack definitions. |
| Deploy stubs + `SOURCE`, not submodules | Same benefit, none of the detached-HEAD trap. |
| `SOURCE` records a sha, never pulls | Otherwise a restart at 03:00 silently deploys whatever upstream HEAD is, and you find out from mid-ocean. |
| `${SRC_ROOT:?...}` with `:?`, not `:-` | Unset stops Compose with your error message instead of building from a wrong path. |
| `/etc/fstab` tracked read-only, never generated | Generated files on the boot path are the one red line. |
| esmira, immich-ml dropped | Dead for months; esmira's data dirs were empty. |
| Staying on OpenVPN | Works and is proven. The WireGuard key is unused but still live, so still gitignored. |
| `gavin` not in `docker` group | Root-equivalent. Rootless Podman removes the need. |
| Target OS is **openSUSE MicroOS** — decided, gated on being ashore, explicitly reversible | Immutable root with btrfs snapshots and auto-rollback on a failed boot — the right shape for a box you can't reach for months. Official Pi 5 support. **Confirmed by the owner 2026-08-29:** it is decided and waiting on physical presence, not deferred — and it is not set in stone; it can be overturned. Recorded because a sweep flagged that three documents said Decided while nothing here recorded a deferral. There is no deferral to record: a decision waiting on a date is not a decision that lapsed, and the reversibility is the part that was nowhere. |
| `two` leaves the fleet, but is **kept as the lifeboat** | Its armv6 was the *only* thing forcing a Debian fleet, so it doesn't migrate. It stays powered on for serial console, power-cycling, and watchdog duty — the things that help when a critical box won't boot. Stays on Alpine. *Diskless was written here as settled and is not:* `two` is a `sys` install today, and now has a Postgres data directory arguing against the switch — see "`two` also runs a test bot" below. |
| `chattr +i` on bare mountpoints, not a guard service | Makes the bad write **impossible** rather than detected, with no boot-path code. The guard service that was drafted instead added a new way for the box to come up with no containers, and had a false-failure mode: renaming a Syncthing share would have silently stopped Docker on the next reboot. |
| Claude dev containers stay in their own app repos | They are developer tooling, not host services. Pulling them into `deployments/` would break `make dev` from a fresh app clone, invert the dependency, and — decisively — still leave both `Dockerfile.dev` files duplicated. It relocates the duplication instead of removing it. ⚠︎**To be SUPERSEDED** — decided 2026-10-25, not yet built: every dev container moves into one compose file in `infra` (*Dev containers: one compose file in `infra`, one memory pool, `claude-sessions` only in a hub* below). |
| `containerd` service removed, package kept | `dockerd` spawns its own containerd; every moby shim uses `/var/run/docker/containerd/containerd.sock`, so the standalone service owned zero shims. But `docker-engine` **hard-depends on the package** — `apk del containerd` would kill every container at the next start. Service-level removal only. **On `one` and `zero`.** ⚠︎ **Not done on `one`**, found 2026-10-25: `containerd` was still in its default runlevel, started at boot 62 days earlier — about 15 MB, and owning none of the shims, every one of which is on dockerd's own socket. The removal was handed over that day; until the owner confirms it, `one` still runs it. On `two` the package goes too, in one transaction with every dependent — see below; the rule was always "never *alone*", not "never". |
| OpenCloud and k3s deleted, not migrated | Both confirmed unused. k3s was still *running* a live cluster (traefik, coredns, metrics-server) and holding ~880 MB of swap; removing it plus the dead `nextcloud` subvolume returned ~344 GiB to the array. |
| **Docker and containerd removed from `two`; rootless podman instead** | Two daemons and their shims cost roughly 34 MB RSS on a board with ~475 MB total, and `two` ran no docker containers worth the price. Rootless podman is daemonless — nothing is resident when nothing is running — and it needs no `docker` group, which this repo already refuses to grant. It is also where `one` and `zero` are headed under MicroOS, so `two` is the cheap place to learn it. |
| **No new user, no boot autostart on `two`** ⚠︎SUPERSEDED | Rootless podman's isolation comes from the user namespace, not from which unprivileged uid owns it, so a second service account buys nothing over `gavin`. **That reasoning was incomplete and the entry is re-stated below** — a dedicated account also buys a `/bin/sh` login shell and an empty home, which is the only thing that takes the ambient login shell out of the deploy key's TCB. Still not done; see "The forced command runs inside `gavin`'s login shell". And a test bot that resurrects itself at 03:00 and takes 200 MB of a 475 MB lifeboat is the wrong default: `restart: always` covers a crashed container, and a reboot deliberately leaves the box running nothing until someone deploys. |
| **`bin/compose` stays docker-only and refuses `destiny-director` by name** ⚠︎SUPERSEDED by management-plane.md § *`bin/compose` goes, at Phase 3*; deleted 2026-10-25 | Making it runtime-aware would not have helped: that stack cannot be driven from `bin/compose` on *any* host, because its compose file interpolates two variables only `dd-ctl` supplies. And `docker compose` and `podman-compose` are not interchangeable — different project-directory semantics that agree here by coincidence. A wrapper hiding that will eventually hide a difference that matters. The conversion belongs to the MicroOS move, where there are stacks to test it against. |
| **`dd-ctl` has exactly one copy, and it is not in `bin/`** ⚠︎SUPERSEDED | It drives one stack, so it lives beside that stack; `bin/` is for fleet-wide tools, and the README points at it from there. No symlink to it anywhere: a script reachable two ways is a script whose behaviour can depend on which way you came. It carries no `infra-` header either, because `_infra.py` only reads those under `hosts/<host>/system/` — a header no parser reads is decoration dressed as a checked invariant. |
| **`dd-ctl`'s verbs take no arguments** ⚠︎SUPERSEDED | Deleting the arguments deletes every line of validation that existed to make them safe, and the bugs that could hide in it. It also means the keyholder cannot name the image. It does **not** mean the image is safe from everyone — see below. |
| **The deployed image is a literal in `compose.yaml`, not a variable** | It is the one knob, and it is tracked. `SOURCE` already withholds the commit deliberately; putting the *branch* in a gitignored `.env` too would leave this repo unable to say anything at all about what `two` runs. It also removes a `${…:?}` failure path and any chance of `.env` and `compose.yaml` disagreeing. Editing it to test a branch shows up as local drift, which is the desired signal. |
| **`root-setup.sh` generates the dispatch key itself; the private half goes in the Claude Code environment block** ⚠︎SUPERSEDED | The operator had to arrive with a keypair and paste its public half in. Now the box makes one, installs the public half, and prints the private half once as base64 for `DD_CTL_KEY_B64`; a `SessionStart` hook in the app repo materialises it per session, so ephemeral containers keep working with nothing to re-authorise. The private half never touches the SD card — generated on tmpfs, shredded on exit. **That environment block is not masked**, and that is the constraint the whole arrangement is built around: only a key whose entire reach is dd-ctl's six argument-less verbs may go in it. Never a key that gets a shell. The one exposure is the print itself, in terminal scrollback; the script says so rather than letting it pass. |
| **Exactly one dispatch line, and rotation is opt-in** ⚠︎SUPERSEDED | A second `command=…,restrict` line is not an error anyone can see: both keys authenticate, sshd reports nothing, and neither the box nor the operator can say which one the environment block holds — so revoking the wrong one reads as a broken deploy. A plain re-run therefore reports the installed key's fingerprint and generates nothing, and `DD_CTL_ROTATE=1` **replaces**. That is the single deliberate exception to append-never-rewrite for `authorized_keys` (which is right, because a botched rewrite on a tunnel-only box is unrecoverable): backup first, build beside and rename atomically, and require every non-dispatch line to come back byte-for-byte — so a rotation cannot cost `gavin` his own key. |
| **The live `dd-ctl` is root-owned, and that is the whole mechanism** ⚠︎SUPERSEDED | `/usr/local/bin/dd-ctl`, a real file, 0755, in a root-only-writable directory — never a symlink into `~gavin/infra` and never the checkout's copy run in place. `gavin` owns the checkout, so a forced command resolving through anything `gavin` can rewrite is not a restriction: replace the target, get an unrestricted shell. It was never a boundary *against* `gavin`, who has sudo; it stops the holder of the **restricted key** rewriting the thing that restricts them. **It is not sufficient on its own** — the login shell runs first; see below. |
| ✔ DONE 2026-08-29 — **On `two`, 2g, 2e and the Cloudflare dashboard sweep are one job** | They close each other, so tracking them apart invites a half-done state. A tunnel created with `config_src: local` arrives with credentials in a 0600 file, so 2e is satisfied by *construction*; deleting the old tunnel then **voids** the credential that was inline in `two`'s 755 init script until 2026-08-23 — which beats rotating it. ⚠︎ Moving it into `/etc/cloudflared/two.json` stopped the *exposure*, not the *disclosure*: the tunnel secret is unchanged, so anyone who read that world-readable file still holds a working credential for tunnel `bdb4a988`. Only the delete voids it, which is why this is still 2e's last host. The orphaned Access tokens and applications from the failed runs of 2026-08-22 are objects on the same tunnel and the same dashboard visit. The sweep half stays a human step: it needs judgement about which token the phone holds. |
| **Every informational `debug` in a playbook carries `changed_when: true`** | `display_ok_hosts = False` in `ansible.cfg` buys a quiet run on a phone screen, and a `debug` task reports **ok** — so the setting silences every message the playbooks exist to print. It cost the one that matters most: `create-dev-tunnel.yml` mints an Access service token, whose secret Cloudflare returns at creation and never again, and printed it into a suppressed `ok`. Marking those tasks changed is a display decision, not a claim about state. The price is that `changed` in the recap stops meaning "the fleet moved"; the alternative — turning the setting back off — costs the quiet run everywhere to fix output in one place. |
| **A lost service-token secret is recovered by rotation, never by delete-and-recreate** | Cloudflare will not delete a service token an Access policy references (`400` / `12139` `service_token_in_use`), and every token here is named by the policy that admits it — so the delete-and-recreate path `create-dev-tunnel.yml` shipped with could only ever have worked on a half-provisioned container. Rotation is also simply better: one call instead of three, the token id and the policy untouched, no window in which the application has nothing to admit, and the old pair dead the instant the new one is printed. The flag is `-e rotate_service_token=true`; the old `replace_service_token` is refused by name rather than redefined, because it described an operation that does not exist. |
| The base image is parameterised by **environment and baked files**, not by forks | A child that needs different behaviour sets `DEV_*` in its compose, or bakes `ssh_config` / `known_hosts.extra` / a `sshd_config.d/*.conf` (⚠︎SUPERSEDED 2026-10-27: that seam is gone, every container's sshd is the base's one file) / a `child-init.sh` (an `rc-supervisor.sh` was one of these until 2026-08-25, when remote control left the fleet — see the superseded rows below). or3-dev was the test: it needed a different secrets directory, different key names, an extra pinned host key, TCP forwarding on, and a remote-control daemon — and every one fits a seam. Had any needed a second `entrypoint.sh`, the base would have bought nothing, because the entrypoint is most of the ~700 shared lines. |
| **The base image builds on a push to `main`, and an unbumped `BASE_TAG` fails the run** | Dispatching `dev-base.yml` by hand was one more thing to remember on a change that already has several, and an image nobody built is a `BASE_TAG` in the Makefile that names nothing — `make up` then fails on the pull, days later, for a reason that reads like a registry problem. So a push to `main` touching `dev/` runs it. **What it enforces is the tag, not the build**: a tag that is new gets built and pushed, a push that changed no file the image is built from does nothing and says so, and a push that changed one *without* bumping `BASE_TAG` fails — because dd-dev, ds-dev and or3-dev pin that tag, a pinned tag is a contract that the same tag is the same bytes, and `main` would otherwise describe an image that does not exist. The thing a person forgets is not the dispatch, it is the bump, and this is the only place that can catch it. **Which files count is derived from the `COPY` lines in `Dockerfile.base`**, not listed in the workflow: a second list is a list that drifts, and adding a `COPY` to the base needs no edit in CI. The trigger is deliberately wider than the derived list — any push touching `dev/` — so the narrow question is answered in one place; a run that concludes there is nothing to publish costs a checkout and two API calls. **It compares what a rebuild would see, not file names**, and that took one push to learn: the first version failed on a commit whose only change to `Dockerfile.base` was a paragraph of prose, twenty minutes after it went in. A Dockerfile comment cannot reach the built image — the parser drops it, `\` continuations included — so comments are stripped before comparing, keeping parser directives (`# syntax=`) and refusing to strip at all if the file ever grows a heredoc. Every other input is a shell script, where `#` cannot be told from content without parsing the shell (`entrypoint.sh` has two heredocs), so those compare byte for byte and a comment edit in one does ask for a bump. The asymmetry is the point: strip where it is provable, refuse where it would be a guess. Overwriting a published tag still takes `-f force=true`. |
| **The base image is built with a registry layer cache, zstd layers and a digest-pinned `FROM`. The child still builds on the Pi** | Without a cache, every CI run gave every layer a new digest. So a bump that changed one `ARG` (claude-sessions, ~4 MiB; ~15 such bumps in the first week of October) made zero download 264 of the image's 306 MiB and decompress it beside Immich. That was the `make up` that took minutes and dropped the session. With `cache-from`/`cache-to` (`type=registry`, `mode=max`, the `buildcache` tag), an unchanged step keeps its digest and a Pi pulls only what moved. This was proven locally, for both platforms, with a fresh builder per build. **zstd** decompresses faster on ARM. The cache is zstd too, so cached blobs are reused rather than re-compressed into fresh digests. **The pinned digest is what keeps the cache valid**, because a floating `python:3.13-slim-trixie` moves every few weeks and would invalidate it. Moving that digest is now the one deliberate refresh of Debian packages and the baked Claude Code. (⚠︎ Amended 2026-10-11: still true of Debian and Claude Code, but no longer the only layer that re-runs — the Crush layer re-runs, ~25 MB, whenever Charm has released since the last tag. See the Crush row. Crush left the base in 2026.10.30, so the digest is again the only refresh.) **Not chosen: publishing the infra-dev child from CI too.** The owner wants GitHub to build the base and nothing else, with the remaining steps small enough to run on the Pis. **Not chosen: Nix.** It would give the same per-change layers, but its read-only store fights Claude Code's self-update into its own prefix, nixpkgs lags Claude Code releases, and it adds a second build language for one property the cache already provides. |
| The base copies **every `id_*`** out of the secrets mount, not a list of names | The names are the one thing that differs per container. A list in the base is a list the base has to know about its children, which is the dependency the registry was built to remove. Which keys a container *should* hold is stated in its own `ssh_config`, where an absent `IdentityFile` fails naming itself. The test is the file's first line, not its name, so a stale `.bak` is not copied. |
| ⚠︎SUPERSEDED 2026-08-25 — The base carries the remote-control **hook**, never the daemon | Only an RC-enabled child uses it, dd-dev's is a different design, and `--permission-mode auto` is a decision about the container that makes it. In the base that default is one environment variable away in every child. **Replaced by: no remote control on this fleet at all.** Every dev container is reached by ssh with the work in an abduco session; dd-dev, ds-dev and or3-dev deleted their supervisors, `DEV_REMOTE_CONTROL` is gone from the base, and the hook went with the daemons it started. |
| ⚠︎SUPERSEDED 2026-08-25 — `remoteDialogSeen` is seeded **only** under `DEV_REMOTE_CONTROL=1` | It suppresses the one-time Remote Control consent prompt, which a headless container cannot answer. Seeding it where nothing ever starts remote-control is pre-consenting to a thing that container deliberately does not do. **Replaced by: it is not seeded at all**, since no container starts remote-control — the reasoning survives its subject. |
| A drop-in cannot brick a dev container: `sshd -t` runs before the `exec` | The `sshd_config.d` seam lets a child inject text into the config that decides whether sshd — which is PID 1 — starts at all, on containers that are `restart: no`. The preflight starts without the drop-ins and says so, rather than not starting. Falling back is safe by structure, not by care: the `Include` is first and sshd is first-match-wins, so a drop-in can only override, and the base it falls back to is key-only with no forwarding and no passwords. **The `Match`-leaks-into-the-main-file hazard this seam was documented with turned out to be false** — measured on OpenSSH 9.2, a drop-in's `Match` is confined to that file. Three readings repeated it because each was checking whether the rule was followed, not whether it was true. |
| The base runs a child's **`child-init.sh`** at start — the fifth seam | The other four seams place a *file*; dd-dev and ds-dev needed something *done*: `uv sync --frozen` against the lockfile in the bind mount, which cannot happen at build time because `/workspace` is not mounted then. Two of the four children need it, which is this base's own test for what belongs in it. Placed after the pull, so a lockfile that just moved is what gets installed, and before sshd, so no session arrives to a half-installed venv — a child wrapping the `CMD` instead would get neither. Non-fatal, like the pull: the door is the one thing that must come up, and a container you can ssh in and fix beats one that refused to start over its own dependencies — **and time-bounded for that same reason**, because non-fatal only covers the half of it that exits, and a hook that hangs ahead of sshd costs the door exactly as a crash would. |
| A start-up warning that names the wrong thing is worse than no warning | Two in the base were infra-dev's own written as if they were everyone's. *zero, one and two are unreachable* means nothing in or3-dev, dd-dev or ds-dev, so it now prints only for a container that did not name its own `DEV_SECRETS_DIR` — which is infra-dev, by definition. *NOTHING can ssh in* is false when a drop-in names its own `AuthorizedKeysFile`, which is exactly dd-dev and ds-dev serving the host account's keys; the base tests the drop-in's own text rather than a flag — and only `*.conf`, which is what the `Include` globs, so a `.bak` beside a drop-in cannot silence the warning that the door is shut. Both would otherwise have been inherited by two more containers on the day they converted. The same first-match-wins cuts the other way: a secrets `authorized_keys` copied out *while* a drop-in overrides the path is a copy nothing reads, so that case says so too. |
| **One way into every dev container: ssh, and abduco holding the work** | ⚠︎SUPERSEDED IN PART 2026-10-06 by the zmx row below — the way in is unchanged, but a slot is held by zmx, not abduco. Four containers had three arrangements — infra-dev refusing remote control by design, or3-dev shipping a daemon it defaulted to off, dd-dev and ds-dev running one as PID 1's payload. Three arrangements means three things to remember at 2am and three failure modes to tell apart, for a capability that duplicates the door: `ssh -t <name> abduco -A claude claude` already survives the dropped link, and it does not put a permission classifier in charge of a container holding deploy keys. The supervisors are deleted rather than defaulted off, because a daemon that ships disabled is one env var from running and nobody reviews an env var. **Still the rule since 2026-10-02, with the command in front changed:** `ssh <name>` lands on the `claude-sessions` menu through `claude-sessions-door`, and every session that opens is still an abduco session (row below). |
| **An idle claude is offloaded after 90 minutes, and the conversation is not** | ⚠︎SUPERSEDED 2026-10-06 by Stage B of the two-stage row below: `claude-sessions offload` replaced the script, with 10 minutes at the prompt and no floor, because a pending timer was then seen (⚠︎ and that in turn superseded 2026-10-08: since v0.4.7 no timer is read, and a quiet wait is held by `claude-sessions keepalive` — the measured-offloader row). The 90-minute reasoning stands as the history of why there was a floor. Measured on infra-dev: one detached session's process tree held 1,146 MB RSS, on a 4 GB Pi that runs four of them plus Immich. The conversation is already on disk — `claude --resume` — so memory is the only thing an idle process holds that anyone wants back. 90 minutes because a claude can schedule its own wake-up and the runtime clamps that to an hour: past that, nothing inside the process is coming back for it. The script refuses a limit under 3600s rather than clamping one, and refuses to touch an attached session, a session with any non-claude process running under it, or one with no transcript to time. |
| **Claude Code is not pinned in the dev base, and updates itself in place** | It ships several releases a week, so a pin costs a base rebuild, a `BASE_TAG` bump and four repos moved *per release* — which nobody was ever going to do, so what the pin bought in practice was containers months behind with no signal saying so. It was never much of a pin either: `npm install -g` takes whatever the registry serves on build day. **The auto-updater was in the image all along and could not run** — `npm install -g` as root writes a root-owned `/usr/lib/node_modules` and every session runs as `dev`, and Claude Code reports that exactly once, at start-up, inside a TUI, in a container people leave running for weeks. The fix is one property and no machinery of ours: the npm prefix is `/opt/npm-global`, owned by `dev`. **`/opt` and not `~/.npm-global`**, because a named volume only inherits the image's content while it is EMPTY and four of them mount over `/home/dev` here — a binary baked under a mountpoint is visible on the container that created the volume and hidden from every one after it, which is a broken `claude` on a rebuild months later for a reason nobody would connect back. The costs are accepted and stated rather than discovered: the tag no longer pins the one thing in the image that can move under a running container (`Dockerfile.base`'s header says so where the contract is stated), and four containers fetch each release separately over zero's own home line, which is free. `make verify`'s `autoupdate:` line is the check, and it deliberately does not read `claude doctor`'s `Auto-updates:` field: measured both ways round on 2.1.278, that field prints `enabled` on an install that demonstrably cannot update itself, because it reports the `DISABLE_AUTOUPDATER` setting and nothing else. The discriminator is the warning `Can't auto-update: npm global folder isn't writable`, with `Last update attempt: success` as corroboration — one more instance of *a check that can pass for the wrong reason*, caught this time by running the negative control before trusting the verdict. |
| **The dev base runs Debian trixie, for a glibc floor of 2.39** | Asked for on 2026-09-21. Bookworm carried glibc 2.36 and trixie carries 2.41, so the bump is two `FROM` lines — and the reason it is recorded here rather than just made is that **a distro bump is never only the package you wanted**. It also moved OpenSSH 9.2 to 10.x, which matters because `sshd_config` carries two claims this repo *measured* on 9.2 — that a drop-in's `Match` is confined to that file, and that `sshd -T` already reports `compression yes` — and a measurement against a version the image no longer ships is an inference wearing a measurement's clothes. Both are annotated in place with the two-minute command to re-run them, rather than deleted or quietly trusted. fish went 3.6 → 4.x; Python and Node did not move. **The hosts have no glibc to bump** — zero, one and two are Alpine, musl — so this is a statement about one image, and a container's libc is its own business: glibc 2.41's kernel floor is far below Alpine's 6.x, and the syscalls a newer glibc reaches for were already being made by 2.36 on those same boxes under that same docker. The abduco build-from-source stage was kept in the bump commit — one change at a time, and what `apt` would install on trixie was the one thing that could not be checked from an agent session — **and the follow-up that tried to drop it failed, which is the useful part**: `apt-get install abduco` does not work on trixie (`E: Unable to locate package abduco`, both architectures, main + updates + security, 2026-09-21). This repo's Dockerfile had asserted for a month that Debian shipped it "in trixie and sid only"; the first time anything executed that claim, it was refuted. The stage is therefore not a workaround for an old base — it is how the image gets abduco at all — and the comment says so where it sits. ⚠︎SUPERSEDED IN PART 2026-10-06: abduco and its stage left the image (the zmx row below). A fact nobody has run is not a measurement, however long it has sat in a comment; the five-minute automatic build is what turned this one over. |
| **The laptop is two ssh clients, and Ansible runs on one of them to configure both** | Windows cannot be an Ansible target without sshd on it, which is a lot of machinery for three files. Under WSL it does not have to be: `C:\Users\gavin` is mounted at `/mnt/c/Users/gavin`, so one run of `configure-client-dev.yml` *in WSL* writes the Linux config and token **and** the Windows config, token and wrapper. `configure-client-fleet.yml` already did this for the fleet block; the dev-container blocks were simply never given the same half, which is why a WSL run appeared to do nothing on either side of the laptop. Run from Termux, `/mnt/c` is absent, the Windows half is skipped, and the block and wrapper are rendered to a paste file — **but never the token**, because a secret in a file the owner opens and copies out of is a secret in scrollback. |
| **Windows gets a `.cmd` ProxyCommand wrapper, not a longer ProxyCommand** | Every POSIX client loads the service token in one line — `ProxyCommand sh -c '. token; exec cloudflared …'`. Win32-OpenSSH has no `sh`, and the two shortcuts that close the gap are both refused: `--service-token-secret` on the command line puts a live credential in the process list, and a `setx` puts it in the environment of every process the account starts. So the load-then-exec becomes `cf-access-<alias>.cmd`, which `setlocal`s, reads the two values off `findstr`'s **stdout** (not its argv), and runs cloudflared as its final command — the same guarantee the `sh -c` gives, spelled for the shell that is actually there. Not the same *shape*: batch has no `exec`, so cloudflared is a child of the wrapper rather than a replacement for it, and the wrapper's closing comment says what that costs. It runs the *Windows* cloudflared, consistent with the fleet block's existing choice; the WSL half needs its own Linux binary, and `command -v cloudflared` will not find `cloudflared.exe` for it. |
| **The Windows token's permissions are printed, not asserted** | `/mnt/c` is drvfs and carries no Unix mode, so `mode: "0600"` there either fails or silently does nothing — and a task that pretends to have set a mode is worse than one that does not try. What protects that file is the NTFS ACL `C:\Users\gavin` hands down. The play runs `icacls.exe` through WSL interop and prints the result with `changed_when: true`; it does **not** assert on it, because this repo's own rule is that a check is calibrated against known-good state before its verdict is trusted, and nothing in the control plane can see that laptop to calibrate against. Localised account names would have made a name-matching assertion wrong on a machine nobody here can test. |
| **A playbook run with no inventory fails instead of exiting 0** | `ansible.cfg` is read from the cwd and is the only thing pointing at `./inventory`, so running a play from anywhere else makes `hosts: control` match nothing: Ansible prints `skipping: no hosts matched`, an empty recap, and **exits 0**. With `display_ok_hosts = False` a real run also collapses to banners, so the two read alike on a phone and the conclusion drawn is "it ran, nothing to do". No task inside the play can catch it — the play is skipped whole — so the guard is its own play in `playbooks/_assert-inventory.yml`, imported above the real one and matching `localhost`, which Ansible provides even with no inventory at all. That is exactly the case being caught. |
| **One command writes every ssh block, and the composition is four static imports rather than a loop** | `configure-client.yml` imports `configure-client-fleet.yml` once and `configure-client-dev.yml` once per dev container, with the alias and port as import vars — the hostname is derived, see *A dev container's tunnel hostname is DERIVED from its alias* below. A loop over a list is the obvious spelling and is wrong here: `configure-client-dev.yml` prompts for a credential and writes it at 0600, and a loop puts those prompts and writes inside `loop:` results, where `no_log` hides which iteration is which — so a mistake becomes a mistake about a secret you cannot see. Static imports keep the reviewed single-alias play byte-for-byte as it was, each stanza reads as the fact it asserts, and `-e alias=…` still works for a single container, which is the rotation path. Verified: import vars reach the imported play, do not leak between imports, and `meta: end_play` inside one import does not stop the next. |
| **The dev-container port registry moves into the playbook that consumes it** | It was a comment in or3's `dev/compose.yaml` — the worked example that opens `management-plane.md`'s drift table, a fact about `zero` recorded in the newest claimant's app repo where nothing in this repo could contradict it. It is now the header table of `configure-client.yml`, and every `<alias>-lan` block on every client was built from those numbers. That was the difference that mattered: a wrong number was found by somebody using a rescue path, not by somebody re-reading a comment. ⚠︎ **That consumer went with the `-lan` aliases on 2026-08-31** — see the row on dropping them. The table stays where it is, because it is still the file you open to add a container, but it is documentation again and nothing generated will catch a stale number. The evidence it was needed is in the same commit — `management-plane.md`'s own port paragraph had been missing `2225 infra-dev` since the day `infra-dev` was built. |
| ⚠︎SUPERSEDED 2026-10-02 by *A client's ssh blocks never depend on its Access tokens* (below): the skip now drops the TOKEN, not the container — the block is written and its ProxyCommand names the missing token, `meta: end_play` is gone, and a blank ID+secret at the prompt skips too. **A missing service token skips its container by name; it does not stop the run** | `-e prompt_for_token=false` makes `configure-client-dev.yml` print what it is skipping and `meta: end_play` out of that import. Without it, one command against a fleet where half the tunnels are still Phase 5 stops on a prompt for a credential nobody can produce, and the containers that *are* provisioned never get written. Default is still to prompt, because that is right for a client being set up against a fully provisioned fleet, and because a flag that quietly tolerates a missing credential is one that hides a real failure. The skip writes **nothing** for that container rather than a partial block: a `ProxyCommand` sourcing a token file that is not there fails as `Connection closed`, which reads like the container being down. |
| **The `ssh-zero-dev-*` aliases leave the fleet block, and that is only the client half** | Every dev container now runs its own connector behind its own hostname and Access token, so the rules on **zero's** host tunnel are a second door to each — the argument 2i was filed on. `zero-dev-or3` was already dead when it went: its ingress came off in `7bb2075` and the alias named a hostname with no route, which fails exactly like the container being down. Dropping the other two stops this fleet *using* that door; it does not close it. Closing it edits `hosts/zero/system/cloudflared-config.yml` and cycles zero's connector, which is a box change the owner drives from a mesh route — filed, not done. |
| **The generated ssh blocks keep rescue notes; the reasoning moves to a doc** | A client's `~/.ssh/config` was 484 lines to express 130 lines of configuration, because the dev-container explanation was inline in the template and therefore written once **per container** — four identical copies of the same seventy lines, in a file that is read on a phone. [`ssh-clients.md`](ssh-clients.md) now holds the why; each block keeps only what is useful with a wedged connection in front of you: which alias does what, the `RemoteCommand` gotcha, what `-lan` is and is not independent of, and the `nc`-not-`ProxyJump` reason. 275 lines, and the same 130 directives — proved by rendering both template versions across every permutation and diffing the non-comment lines, then by `ssh -G` over 25 aliases before and after. This does not soften the repo's comment habit: a comment that says *why* still belongs next to the thing, and the test applied was whether you would need it during an outage, not whether it was interesting. |
| **No dev container gets an alias for zero's host tunnel** | The `ssh-zero-dev-*` rules are a door **zero** opens on a container's behalf; every dev container now comes up with its own connector, hostname and Access token, and `configure-client-dev.yml` writes two aliases for each. `dd-dev` and `ds-dev` are not running until they are deployed that way, so an alias for the old door would name a hostname with nothing behind it — the failure that reads as the container being down. This was briefly reversed on 2026-08-28 out of a worry about removing a working fallback; the fallback was not working, and the owner knew the fleet's state where the repo did not. **Dropping an alias closes nothing** either way: the rules live in `hosts/zero/system/cloudflared-config.yml`, and removing them is a boot-path edit plus a connector cycle — phase 2i, and the owner's to run. |
| **Whitespace and line-ending tests go in awk, not in grep or `case`** | `bin/one-shot-ssh-defaults-note` refused a config whose last stanza demonstrably *was* `Host *`, and printed `Host *` as the thing that was not `Host *`. Three inputs produce that and all three are invisible in a terminal: CRLF endings (`Host *<CR>`), a trailing tab, and two spaces between the keyword and the `*`. The check was `case` against `grep -n '^[Hh]ost[ \t]'`, and `[ \t]` inside a grep BRE is not a tab — it is a bracket expression matching a space, a **backslash**, or the letter `t`, so `Host<TAB>*` was never even found. awk's regex engine understands `\t`, and one `sub(/\r$/, "")` on read removes the whole class. The file's own line-ending convention is then preserved on write rather than normalised, because changing every line of a config to fix a comment is not what the script was asked to do. This is the same failure the repo already records twice — a check that can pass, or fail, for the wrong reason, and a pattern counting characters across multi-byte or invisible input. |
| **A prompt for a credential names the credential** | `configure-client.yml` imports `configure-client-dev.yml` once per dev container, so the run showed four identical play banners and four identical `Client Secret (not echoed)` cursors with nothing distinguishing them — reported from the laptop, and the honest answer to "which one is it asking for?" was that you could not tell. The play name, both prompt task names, and the prompt strings themselves now carry `{{ dev_alias }}`, and the announcement above them names the container, its hostname and where to read the token off a client that already has it. Play names and task names template against the play's own `vars:`, which was worth verifying rather than assuming. The general form: composing a play by importing it N times makes every message in it ambiguous by default, and the ones that ask for something are where that costs. |
| **The Windows ProxyCommand wrapper is written with `newline_sequence: "\r\n"`** | cmd.exe seeks by byte offset between commands in a batch file and miscounts on an LF-only one, resuming mid-line and executing fragments of the file's own comments — `'ible' is not recognized as an internal or external command`, from the middle of the word "ansible". The wrapper's header had asserted the opposite ("LF line endings are fine here"), which was never checkable from a control plane that cannot run cmd.exe and should not have been written as fact. Two other spellings were tried and are recorded in the task so nobody repeats them: a `replace('\n', '\r\n')` filter on a `lookup('template')` silently does nothing, and CRLF in the template file survives only while that file has no Jinja in it — the lexer normalises newlines once it does. The wrapper is also ASCII-only now, for the same class of reason: it runs under the console codepage, not UTF-8. |
| **`IdentityFile`/`IdentitiesOnly` are written only when the client has that key** | `IdentitiesOnly yes` is worth having — it stops ssh walking every key an agent holds and hitting `MaxAuthTries` before it reaches the right one. But it also means an **agent** key is offered only when its public half matches a named `IdentityFile`, so on a client whose private key lives in an agent and never on disk — Windows' OpenSSH agent reached from WSL is the case that found it — the pair we wrote left ssh nothing to offer and the container answered `Permission denied (publickey)`. The play now stats the key and its `.pub` on each side (they are different files: `~` in WSL is not `C:\Users\gavin`) and omits both lines where neither exists, saying so. An `-e identity=…` that does not resolve is still a hard failure, because that is a typo rather than an agent. |
| **A task var must not share a name with a `set_fact`** | Ansible's precedence puts `set_fact` at 19 and task `vars:` at 15, so a task var named after an existing fact is silently ignored — no warning, no error. Passing per-render values into `ssh-dev-block.j2` as `identity_usable` therefore rendered **both** the POSIX and the Windows block with the POSIX client's answer, on a laptop where the two sides genuinely differ. Renamed to a name the play never sets as a fact. The general rule: a variable that exists to be overridden per task must never also be a fact, and `| bool` belongs on it, because `set_fact` coerces `"True"`/`"False"` to real booleans while a task var stays a string and any non-empty string is truthy. |
| **A public key is passed as JSON or a file path, never as `-e k=v`** | Ansible's `k=v` extra-var form splits on **whitespace** into several pairs, so `-e client_pubkey='ssh-ed25519 AAAA... you@host'` arrives as the single word `ssh-ed25519` — the rest is silently discarded. It is a truncation that still passes a prefix check, and `ansible.posix.authorized_key` then fails with `list index out of range`, which names nothing. `authorize-configure-client-dev.yml` counts the whitespace-separated fields rather than trusting the prefix, and its failure message says which of the two working forms to use. Same class as the `-e st_client_secret` hole in `configure-client-dev.yml`: an extra-var that looks like it worked is worse than one that errors. |
| **A lookup inside a `fail_msg` cannot report its own failure** | `authorize-configure-client-dev.yml` read the key file with `lookup('file', …)` in a play var that its assert's `fail_msg` interpolated. A missing file therefore blew up while Ansible was *rendering the error message*, producing forty lines ending in `Finalization of task args for 'ansible.builtin.assert' failed` — for a wrong relative path, which the message was written to explain. The existence check is now its own task, before anything reads the file, and it is `delegate_to: localhost` because the play targets `zero` while every lookup runs on the control node: an undelegated `stat` would look for the key on the wrong machine. The general form: anything a failure message needs must be known to be safe *before* the failure can occur. |
| **`~/.ssh/cp` and `~/.ssh/cm` are two directories, and both are the client play's job** | `ansible.cfg` multiplexes through `~/.ssh/cp/%C`; the infra-fleet block multiplexes through `~/.ssh/cm/%n-%r`. `configure-client-fleet.yml` created only the second, so a fully configured control node still died the first time it ran a play against a fleet **host**: `unix_listener: cannot bind to path …: No such file or directory`, reported as **UNREACHABLE** — which reads like the box being down and is a missing `mkdir`. It hid for months because every play run from the laptop until then was `hosts: control`, which connects locally and never multiplexes; the phone had the directory because `ansible.cfg` says to make it by hand and someone once did. A prerequisite that only one node happens to satisfy is not a prerequisite, it is an accident. |
| **A rollback restores every file it replaced, and then proves the service came back** | The cutover's rescue restored `<host>.json` and cycled — but `install-system-file` had already replaced `/etc/cloudflared/config.yml` with one naming the **new** tunnel, so a rolled-back host was left with the old credentials and a config pointing somewhere else. cloudflared will not start on that pair. The play then reported *"every hostname still points where it did"*, which was true about DNS and silent about the connector, and the rescue never asked `/ready` — so a failed cycle-back read exactly like a successful one. Found on `two`, 2026-08-28, on the box whose tunnel is its only door and which logs nowhere until 2f reaches it. Both halves are now backed up as `.pre-2g` and both are restored; the rescue then polls `/ready` and says out loud when the answer is zero. |
| **A guard that reads `lookup('file', …)` has checked the control node, not the host** | The cutover asserted that the new credentials and "the reviewed config" named the same tunnel — but `lookup` always runs on the control node, so it compared phase 1's output against the machine that produced it and proved nothing about the box. On `two`, 2026-08-28, the host's clone (`~gavin/infra` — **not** the `/srv/infra` three docs claimed, which does not exist there) did not carry the reviewed config: `install-system-file` installed the OLD config as a no-op, the credentials were then swapped to the NEW tunnel, and cloudflared could not authenticate a tunnel its config did not name. It surfaced as `/ready` returning 503 with zero connections — which reads like a slow box or a network fault, and sent the first diagnosis after a timing hypothesis that was wrong. Two guards now: the host's own clone is slurped and compared before anything is written, and the **installed** `/etc/cloudflared/config.yml` is re-read after the install and before the credential swap, so a mismatch aborts with the host still on its old tunnel instead of after an outage. |
| **`no_log` on a READ hides the refusal too, not just the secret** | `CLAUDE.md` already records this for a `no_log` *write* that can be refused — carry `failed_when: false`, print the body's error list, then assert. The cutover's DNS lookups were bare `no_log` reads, so a 403 arrived as `Status code was 403 and not [200]` with the response censored, and the response body is the only place Cloudflare names the missing permission. Cost a run on `two`, 2026-08-28. The rule is about direction of travel, not about writes: any call whose *failure* carries information needs its body printed, and the thing that must never be printed is the invocation, where the Authorization header is. |
| **A command in a message is a handover block, and handover blocks are fish** | `CLAUDE.md` § *Privileged commands* says to write them for fish and a TTY, and the very fail message added to teach a better diagnosis told the reader to run `read -rs TOKEN` — bash, which fish rejects. The rule is not about `sudo` blocks specifically: every shell fragment this repo emits is going to be pasted into Termux fish, WSL fish, or fish on a Pi. Where a form genuinely differs, give the fish one first and name the bash equivalent, rather than assuming the reader translates. |
| **2g is finished, and the scaffolding written for it is deleted** | `ansible/2g` shortened three long `ansible-playbook` lines to under forty characters, because ninety-three is how a paste breaks in half on a phone. Its own header said to delete it once 2g was done on all three, and it is — `one` and `zero` on 2026-08-23, `two` on 2026-08-29. The plays it wrapped stay; they are the interface now, and the last run was driven from a laptop where the length never mattered. The wrapper's one piece of embedded knowledge is worth keeping in prose: **the cutover must not arrive through the tunnel it cycles**, so reach the target over a mesh alias — `two` cannot jump through itself, and `-e ansible_host=<host>-one` or `-zero` is how you say so. |
| **Playbooks are named verb-first, like `bin/`** | `audit.yml`, `packages.yml`, `ssh-client.yml`, `this-client.yml` — nouns that say what a play is about and not what it does to you, and three client plays whose names gave no hint that one composes the other two. `bin/` had already settled this: `check-sources`, `install-system-file`, `check-mount-guards`. The playbooks now match — `audit-fleet` (⚠︎SUPERSEDED: now `generate-fleet-inventory`, see the row after next), `install-packages`, `create-host-tunnel`, `cutover-host-tunnel`, `retire-host-tunnel`, `configure-client` with `-fleet` and `-dev` beneath it. Renamed with `git mv` so history follows, and every reference updated in the same commit. **Two files were deliberately left holding the old names**: `docs/fleet-inventory.md`, which is generated and regenerates correctly from its template, and the six tracked `/etc` copies, where changing a comment would put three boot-path files into drift against their installed versions for a rename. ⚠︎ **A third thing kept an old name, and it was not deliberate: the blockinfile markers on every client**, which name the playbook — see the next row. |
| **A renamed play removes its blocks under the old marker** | `configure-client-fleet.yml` and `configure-client-dev.yml` find their `~/.ssh/config` blocks by a marker that names the playbook, so the rename above left every existing client with a block the plays no longer recognised, and the next run inserted a second one beneath it. ssh reads the first value it obtains, so the stale block won: on 2026-10-03 `ssh infra-dev` still attached `abduco` after the template had moved to the claude-sessions door. Each play now carries a `state: absent` for its pre-rename marker (and, on the Windows side, the bare `infra-fleet` the Termux paste file used) before it writes. Removing it by hand on each client was the alternative, and is how this would recur: the phone, WSL and Windows are three files, and a fix applied to whichever one was noticed leaves the others. Changing the marker format to drop the playbook name would have orphaned every block a second time. |
| **The read-only play is `generate-fleet-inventory`, not `audit-fleet`** | *Audit* means checking for issues, and this play checks nothing: it reads what runs where and writes `docs/fleet-inventory.md`. The old name also hid the link between the play and the file it produces, so "which playbook makes the inventory?" had no obvious answer. `inventory-fleet` was considered and rejected, because in Ansible *inventory* already names the host list (`ansible/inventory`), and that name reads as if it builds or edits the list. Still verb-first, like the row above. `audit_report` became `fleet_inventory_report` with it. Two things were left alone deliberately. `docs/fleet-inventory.md` is generated, so its header (still naming `audit.yml`) is fixed by the next run from the template. Historical prose ("Phase 1's audit found…") describes an event, not the file. No `state: absent` was needed: the play writes only to the control node and leaves no `blockinfile` marker on any host. |
| **`failed_when: false` on a task with `until` makes it incapable of failing** | Exhausting the retries does **not** fail a task whose `failed_when` is false — it reports ok and the play continues. Verified on ansible-core 2.21. The cutover's final end-to-end check used exactly that shape, so a hostname that never came back after DNS moved would have produced ten retry lines and then *"every hostname answers as it did before the cutover"* — a false statement, from the highest-stakes play in the repo, after the step you cannot quietly undo. `failed_when` **compares**; the fix is to compare against the baseline rather than suppress, which also handles the legitimate 302/502 baselines the suppression was there for. The rescue's `/ready` wait is the same shape and wants the opposite semantics: two tasks that look identical and are not. |
| **A command sent over ssh is parsed by the target's LOGIN shell** | `authorize-configure-client-dev.yml`'s in-container refresh sent a POSIX one-liner to `dev@<container>`, whose shell is **fish** — so it was rejected on its first token, on every container, on every run, and `failed_when: false` reported it as *"COULD NOT refresh — it will pick the key up at its next start"*, which reads as the container being unreachable rather than as a command that cannot run. Shipped broken and caught in review. Anything sent over ssh to this fleet is wrapped in `sh -c` so fish has only one simple command to parse. This is the same rule CLAUDE.md already records for handover blocks, applied to a machine-generated command instead of a human-pasted one. |
| **The read that proves a token can look is not the write that proves it can change** | The cutover's DNS PATCH was the only Cloudflare call still carrying a bare `no_log` with no error-body printing, and the preflights above it do not cover it: listing `dns_records` succeeds with Zone → DNS → **Read**, so a read-only token passes every check, the host is swapped, the outage starts, and only then does the PATCH fail as a censored 403. The loop also continues past a failure, so DNS can end **partially** moved — which is why the assert now names which records moved and points at the "Print each record's current target, to write down" output as the map back. |
| **`<host>.json.pre-2g` sits beside the file it backs up, and that is a deliberate exception** | `CLAUDE.md` § *Backups of secret-bearing files* says back up **outside** the directory at 0600, never `foo.bak` beside `foo`, and never in `/etc/init.d`. This one breaks the letter of the first clause. It is allowed because both harms that rule exists for are absent: it is not in `/etc/init.d`, so OpenRC cannot pick it up as a phantom service; and it is created `cp -a` from a 0600 root file with the mode re-asserted, so it cannot be the world-readable copy that made the rule. What it buys is that `retire.yml` can find it by a fixed path to identify which tunnel to delete — a backup somewhere else would need its own registry, on the one operation in this repo that is irreversible. It is deleted by the cleanup the cutover prints. Recorded here because an unexplained deviation from a rule this repo enforces elsewhere reads as an oversight. |
| **When two parts of one document disagree, the artefact settles it — not the more detailed prose** | `management-plane.md`'s phase table said 2f was done on all three hosts; its prose section for 2f said `two` still needed it. The prose was longer, more specific and more recently edited, which is exactly why it was believed — and it was the stale one. `hosts/two/system/cloudflared` declares `output_log`/`error_log`, so the table was right. This is the same rule the repo already applies to docs versus boxes (`fleet-inventory.md` over the README's port table), and it applies inside a single file too. It was not free: the stale paragraph was quoted twice during `two`'s cutover to say the lifeboat logs nowhere, when it had been logging since 2026-08-23. |
| **Every play that holds a Cloudflare token verifies it before using it** | Cloudflare answers a token it will not accept with `9109 Invalid access token` on whichever endpoint you happened to hit — so the failure lands wherever the play got to and reads like that endpoint's problem. It sent one diagnosis to a missing-permission conclusion that the body did not support. `GET /user/tokens/verify` asks the question directly and separates the two causes that are otherwise indistinguishable: a token string that is wrong, truncated by an echo-off paste, expired, not yet started or the wrong kind of credential, versus a valid token missing a scope. It runs first in all three tunnel plays, prints the body on failure, and the downstream 403 assert can now say *"the token verified, so this is a permission"* and mean it. |
| **The cutover needs three Cloudflare permissions, not two** | Every prompt and the *Safe to delete* list said `Tunnel:Edit` and `Zone:DNS:Edit`. The cutover opens with `GET /zones?name=gsrpi.uk` to find the zone id, which needs **`Zone -> Zone -> Read`** — a token minted for phase 1 (tunnel-only, which is genuinely all phase 1 needs) gets 403 there. Fixed in the prompts of both plays that touch DNS and in `cloudflare.md`, and the assert now says which of the three is likely missing rather than leaving a bare status code. |
| **A relative `-e …_file=` is anchored to `$PWD`, not to the playbook** | `lookup('file', 'x.pub')` resolves against the **playbook's** directory, so a key sitting in `ansible/` is searched for in `ansible/playbooks/` and reported missing while `ls` in the same shell plainly shows it. That is a correct reading of Ansible's rules and a wrong reading of what the person typing it meant. The play expands `~` and anchors anything else to `$PWD`, so the argument means what it looks like it means, and the failure message says which directory it resolved to. |
| **Authorising a key refreshes the container's copy; it does not restart anything** | `dev/entrypoint.sh` copies `$DEV_SECRETS_DIR/authorized_keys` to `~/.ssh/authorized_keys` at start-up and `sshd_config` names the copy, so a key added on the host reaches a running container only when that copy is refreshed. The obvious move — restart sshd — is the wrong one twice over: **sshd is exec'd as PID 1**, so restarting it restarts the container and takes every detached abduco session with it; and it is unnecessary, because sshd reads `AuthorizedKeysFile` on each authentication attempt rather than at start-up. `authorize-configure-client-dev.yml` therefore copies the file inside each container over that container's own `-sh` alias — the same command a person would type, so a failure is fixed by the command that failed — and treats it as best-effort: the host-side write is the durable half, so a container that is down is reported, not fatal. |
| **`command:` needs `expand_argument_vars: false` when the argument is for another machine** | The refresh task passes a small shell script to `ssh`, and `command` expands environment variables in its arguments **by default** — so `$HOME` was resolved against the CONTROL NODE before ssh was invoked, and the copy was aimed at a path that exists on the phone and not in the container. Caught by logging the argv the task actually built rather than reading the task; `$c` and `$d` survived only because they happen not to exist in the controller's environment. Anything destined for a remote shell must be marked as not ours to expand. |
| **A dev container gets no `<alias>-lan` rescue alias** | The block used to carry a third `Host` reaching the container's sshd on `127.0.0.1:<port>` through its host's own sshd — independent of that container's tunnel, Access application and token, which is the set of things that actually breaks. It went because a client-side alias has to name the host the container sits on, and it did: `ProxyCommand ssh zero nc %h %p`, with `zero` written in. A dev container is designed to be movable (`management-plane.md` § *Placement* marks all four **yes**), so the first one to move would have left every client holding a rescue alias pointing at the wrong box — a break-glass path that fails only when it is needed, which is worse than none, because the outage is spent trusting it. **Nothing was closed.** The hop is still there and is now typed: `ssh <host>`, then `ssh -p <port> dev@127.0.0.1`, with the ports in `configure-client.yml`'s table and the one-line client form in [`ssh-clients.md`](ssh-clients.md). It was never a no-Cloudflare path either — the first hop is that host's own tunnel — so what it actually protected against was a bad token, and that is a case where you have a shell on the host anyway. The cost, recorded rather than hidden: the port registry loses its only generated consumer and becomes documentation again. |
| **A dev container's tunnel hostname is DERIVED from its alias, never passed beside it** | Every caller spelled both: `alias: ds-dev` next to `hostname: ds-dev.gsrpi.uk`, four times in `configure-client.yml`'s imports and four more in its registry table — for a value `create-dev-tunnel.yml` already built as `<name>.<zone>` when it created the CNAME. Two spellings of one fact is a pair that can drift, and this drift is silent in the worst direction: the client block names a hostname the edge was never asked to create, which fails exactly like the container being down. So `dns_zone` moved to `group_vars/all.yml` — `all.yml` and not `fleet.yml`, because the client play targets `control`, which is localhost — and both ends derive `<alias>.<dns_zone>` from it. **No `\| default('gsrpi.uk')` beside any use**: a play that cannot see the variable should die on it, loudly, rather than quietly using a fallback that is not the fleet's value; the same call as `${VAR:?message}` over `:-`. `-e hostname=` still wins for a container off the pattern. Proven by rendering `ssh-dev-block.j2` for all four containers both ways and requiring byte-identical output, with a negative control to show the comparison can fail. **Deliberately NOT extended to `prepare-dev-host.yml`'s `tunnel_hostname`**, where absence is itself a setting — absent preserves what `dev/.env` holds, empty turns the tunnel off — so a derived default would make "no `-e`" mean "turn the tunnel on" for a container deliberately reached on its loopback port. Derive where the value is a NAME; do not derive where absence carries meaning. |
| **Claude Code's agent view is off in every dev container, by baked managed settings** | One **←** at an empty prompt — the footer advertises it — takes an idle session from ~250 MB RSS to ~1,260 MB (`claude daemon`, a warm `bg-spare`, its `bg-pty-host`, further full sessions), releases none of it when you return to the prompt, and leaves ~690 MB running after that session exits. Measured 2026-10-01 against 2.1.286. `zero` has 4 GB and carries four of these containers, and the leftovers were **invisible to `offload-idle-claude.sh`** (deleted 2026-10-06), which walked down from abduco and found nothing above them — or3-dev was holding ~700 MB of them that day. It is `/etc/claude-code/managed-settings.json` and not a user or project settings file because this is policy about zero's RAM, not a repo's preference: neither a checkout's `.claude/settings.json` nor the `~/.claude/settings.json` on the `infra-claude` volume can turn it back on. **The image also sets `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`**, because the binary checks the variable FIRST, before any settings file is loaded — so it is the switch that survives the states the file does not: a malformed file is ignored whole, and a settings path a later version moves takes the file with it. The path itself is checked, not assumed: grepping 2.1.286 in `infra-dev` on 2026-10-01 gives `default:return"/etc/claude-code"` off macOS and Windows, a `managed-settings.d` drop-in beside it, and a gate that tests the file with a strict `=== true` — so the JSON boolean is load-bearing and the variable is truthiness-tested, meaning `=0` disables the view too. `make verify` prints both switches, never a single PASS, and **parses** the file rather than grepping it: the first version matched a substring and read "off" for a file truncated after the word `true`, which is the silent-ON case the readout exists to catch. The price, intended: `claude --bg` and `claude agents` are unavailable in these containers. Phase 1 of [`../plans/claude-sessions.md`](../plans/claude-sessions.md). |
| **Claude Code follows the stable update channel, set in the base's managed settings** | Asked for by the owner, 2026-10-07. Claude Code updates itself in these containers (the row on not pinning it), so the auto-update channel decides which versions a container moves to; `stable` is "typically one week behind latest, skips releases with major regressions" (code.claude.com/docs/en/setup). It is `"autoUpdatesChannel": "stable"` in `dev/claude-managed-settings.json` — one line in a file the base already bakes for the agent view — and not a default merged into `~/.claude/settings.json` by the entrypoint, on the owner's rule of managed settings whenever that saves code: the user file is on the `infra-claude` volume, so a baked copy would be hidden after the first container, and the alternative was entrypoint code to merge a key into it. Managed settings outrank every other scope, so the cost is that a container cannot be put back on `latest` from inside it; that is an edit to the file and a `BASE_TAG` bump. The docs confirm the key is honoured in managed settings and applies to an npm global install, which is what this image has. `make verify`'s `autoupdate` line now names the channel, calibrated on the container before the change, where it read `latest`. **Forward only, accepted (owner, 2026-10-07):** the image carries whatever `latest` was when its cached npm layer last ran (corrected 2026-10-08: not build day — `2026.10.07.1` carries 2.1.291), and the updater never steps down — checked in 2.1.292, the background updater and `claude update` both skip a channel version at or below the running one — so a new container stays on that version until stable passes it. Installing `@stable` at build was the alternative and was not needed; today's stable (2.1.285) was checked to carry everything this image relies on (the three scroll switches, `background_tasks`, `SubagentStart`, `autoUpdatesChannel`, `disableAgentView`). The build now parses the managed-settings file, since a malformed one is ignored whole. Landed at `2026.10.07`. **Measured 2026-10-08 (claude-sessions#14):** a claude left running across an update reinstalls every 30 minutes, because the updater compares the version the *process* runs with the channel's, not the file on disk — infra-dev's, started on 2.1.292, rewrote 2.1.293 half-hourly, 13 GB a day of `write_bytes`. Stable makes the trigger weekly rather than near-daily and does not remove it; restarting that claude ends it, and `DISABLE_AUTOUPDATER` in a child's compose stops it outright. or3-dev, on stable and ahead of it, had nothing to install and did not loop. **Auto-update stays on (owner, 2026-10-08: "don't disable auto update completely")** — the loop is handled by restarting a claude that has outlived an update, not by `DISABLE_AUTOUPDATER`. |
| **Every dev container's sessions start in Claude Code's auto mode, set in the base's managed settings** | Asked for by the owner, 2026-10-29: *"default to claude's auto mode across all containers"*. It is `"permissions": {"defaultMode": "auto"}` in `dev/claude-managed-settings.json`, on the same rule as the stable channel above: managed settings whenever that saves code, because `~/.claude` is a volume and a default written into it would need entrypoint code to merge. Checked on 2.1.311 before the change: settings files are read user, project, local, flag, managed, and the last that sets `defaultMode` wins, so this beats every repo's `.claude/settings.json`, and no repo's `.claude/` can set a different default (a repo could never grant `auto`: the binary takes it only from managed, user and flag settings). It is a default, not a lock: a headless `claude` given the key through `--settings` started in `auto`, and with `--permission-mode default` added started in `default`, and Shift+Tab still changes mode inside a session. That proof used the `--settings` flag, which the binary trusts like managed settings; **the baked file itself is not yet proven on a box** — the first rebuilt container's `make verify` `permmode` line and a `claude -p` init event reading `auto` are the check, beside the hooks row's first-`claude` check. A first auto session appends a one-time notice to its transcript, not a dialog, so it cannot hold an unattended slot. claude-sessions passes no mode of its own to a slot's claude, so the default reaches every slot. `disableAutoMode` is not set anywhere, and the model each container runs must support auto mode or Claude Code says so and stays in `default`. **This reverses a reason given in the ssh-and-abduco row above**, that the way in "does not put a permission classifier in charge of a container holding deploy keys". That row was about remote control, and the owner has now chosen the classifier for every session; infra's own `autoMode` rules in its `~/.claude/settings.json` (soft-deny for fleet compose runs and for content changes to `hosts/*/system/`) still apply on top. `make verify`'s `permmode` line reads the key, calibrated on infra before the change, where it read `NOT SET`. Landed at `2026.10.29.1`, superseding `2026.10.29` before it was rolled out. |
| **`claude-sessions` lives in its own public repo under AGPL-3.0, and reaches a box as a pinned, checksummed release** | Created 2026-10-01 at [gsfernandes81/claude-sessions](https://github.com/gsfernandes81/claude-sessions). **Public is not a preference, it is a requirement:** `Dockerfile.base` is built on a public GitHub runner with no token, so a private release asset could only be fetched by putting a credential into that build. The release is a **static musl binary, cross-compiled**, downloaded by a pinned tag and checked against a per-architecture SHA-256 — the shape `CLOUDFLARED_SHA256_*` already uses in that file, so there is a working precedent beside it — and `claude-sessions --version` runs as a **fatal** build check, because a static binary has no excuse not to run. Never compiled in the image: that build's arm64 leg runs under QEMU and a Rust compile there is unusable. **A published tag is never re-cut**, which is the whole point of pinning a hash. The crate has **no dependencies at all**, which began as a constraint and is worth keeping: the dev container has no C linker and no way to get one, so a crate with a build script or a proc macro could not be compiled or tested there — and the tests are the product. Phase 3 of [`../plans/claude-sessions.md`](../plans/claude-sessions.md). |
| **`claude-sessions`' hooks are a managed-settings drop-in the binary generates at image build, never a tracked file** | `claude-sessions hooks-config /usr/local/bin/claude-sessions > /etc/claude-code/managed-settings.d/claude-sessions.json`, 0644, in `Dockerfile.base`. **Generated, because the binary prints exactly the events its own code handles** — a copy in this repo would be a second source of the same fact, and the one that drifts when the pin moves. **Managed settings**, because a user's `disableAllHooks` cannot turn them off and no repo's `.claude/` has to know they exist. **A drop-in** (`.d/`, read after `managed-settings.json` in name order), so this tool owns a file and the agent-view policy stays its own one-line file. **File-based, and never also from the claude.ai admin console**: server-managed settings put any hook behind an approval dialog, and replace the file outright. **0644 is load-bearing** — sessions run as `dev`, and a file it cannot read means no hooks with nothing on screen to say so; the build parses the file and `make verify` re-parses it as `dev`. That a root-written file raises no approval dialog rests on the vendor's docs (claude-sessions' `docs/design.md` § *Where the hooks live*), **not yet on a box** — the first `claude` in a rebuilt container is the check, listed as a bring-up step in the plan. Pinned at v0.1.0, 2026-10-02; at v0.2.0 the same day (`2026.10.02.1`), regenerated from that binary rather than carried over, and byte-identical; at v0.3.1 on 2026-10-03 (`2026.10.03`), the same, checked with `cmp` against the drop-in a v0.2.0 container was running; at v0.3.2 the same day (`2026.10.03.1`, superseding `2026.10.03` before it was rolled out), the same again; at v0.3.3 (`2026.10.03.2`, infra#3), and at v0.3.4 (`2026.10.03.3`, infra#4, superseding `2026.10.03.2` before it was rolled out), both byte-identical again; at v0.3.6 (`2026.10.04`, infra#5, v0.3.5 never pinned), at v0.3.7 (`2026.10.04.1`, infra#6, superseding `2026.10.04` before it was rolled out), and at v0.3.8 (`2026.10.04.3`, infra#8, on top of the forced door at `2026.10.04.2`), byte-identical each time. **v0.3.8's scrollback names are checked here, not in claude-sessions' release** (infra's call, infra#8): the three `CLAUDE_CODE_DISABLE_*` names a slot's claude is started with come from inside Claude Code, which updates itself in a running container without a base bump, so only a check against the live container can see a rename — `make verify`'s `scrollvars` line, word-bounded because the binary also holds `…_MOUSE_CLICKS`, which an unanchored match would count as `…_MOUSE`. And at v0.4.0 and v0.4.1 (`2026.10.06`, infra#9), byte-identical again — v0.4.1's fix for #9 needed no new hook. And at v0.4.3 (`2026.10.06.1`, 2026-10-06, no handoff issue; v0.4.2 was skipped on the owner's word), byte-identical again: the two changes since v0.4.1 — v0.4.2's Esc-ended turn reading idle from the transcript's trailing interrupt marker, and v0.4.3's working-set memory (claude-sessions#7) — need no hook. Checked here before pinning: the memory line matched `max − current + inactive_file` to the megabyte, and the Esc rule against a real zmx session and a stand-in claude — a trailing marker 11 min old offloadable, one followed by a prompt or a reply kept, a fresh one restarting the ten minutes, and the calibration (mid-turn, no marker) kept. **Not byte-identical at v0.4.4** (`2026.10.06.2`): the drop-in gains `SubagentStart` and `SubagentStop`, both calling `claude-sessions hook` with a 5 s timeout, the other six unchanged — still generated from the pinned binary, never tracked. `SubagentStop` is a blocking hook, so the hook's always-exit-0 rule now also stops a hook bug keeping a subagent running (⚠︎ no longer from v0.4.6, which runs it async). Checked here before pinning, through the real hook binary into a scratch registry and a dry run against a real zmx session: an Esc 11 min old with nothing started `would offload`; after a `SubagentStart` the slot listed `subagent: general-purpose` and read `kept — background work running`; after a `SubagentStop` listing nothing (as for a foreground or finished agent — a background agent's own `SubagentStop` still lists it, and the `Stop` of the turn its end wakes releases it) the list emptied and it `would offload` again; a typed prompt beginning with the marker phrase was kept. **v0.4.6 (2026-10-07, `2026.10.07.1`): the same file carries the binary's status line, and six of the eight hooks run async.** The status line (`claude-sessions statusline`, RAM and load, refreshed each minute) was the owner's ask upstream and arrives in the drop-in, so it outranks any user `statusLine`; none is set in the repo or on the volume, and it is taken as the image's, not a user's, setting — checked on infra-dev's volume; the other children's are a step in the plan's bring-up, before each bumps. Every event but `SessionStart` (now 30 s) and `SessionEnd` runs async because a millisecond hook stalled past its 5 s timeout on a loaded box (or3's), holding the prompt and then losing the event; upstream orders late-landing events by the hook's fork time. Checked before pinning: the installed Claude Code (2.1.292) carries `async`, `statusLine` and `refreshInterval`; the status line answered in ~100 ms with its stdin held open; a dry-run pass on a copy of the registry read TCP through socket diagnostics without privilege here. `make verify`'s `hooks` line now names the status line. The pass log's cap went from 4 MB (trimmed to 2) to 16 MB (trimmed to 8), because each pass now adds a measured line per slot and those lines are the whole record upstream reads before the owner decides on the activity rule. **v0.4.7 (2026-10-08, `2026.10.08`): five events, feeding the menu only.** `PostToolUse`, `SubagentStart` and `SubagentStop` left the drop-in because no offload rule reads hooks any more (the measured-offloader row) — ⚠︎ so the v0.4.4 reasoning above for adding `SubagentStart`/`SubagentStop`, and the timer hold `PostToolUse` fed, are superseded. Still generated from the pinned binary, still a drop-in, still parsed at build; the status line stays in it. ⚠︎**To be SUPERSEDED** — decided 2026-10-25, not yet built: `claude-sessions` leaves the dev containers for a hub, and what a dev container keeps for it to read is the hub mode's design (*Dev containers: one compose file in `infra`, one memory pool, `claude-sessions` only in a hub* below). |
| **The offloader is replaced in two stages: `claude-sessions offload --dry-run` beside the old script first, then the swap** | ⚠︎SUPERSEDED IN PART 2026-10-08 by the measured-offloader row below — the two stages stand as how it went live; the rules they read (10 minutes after `Stop`, a pending timer never stopped) are gone. The new rules are not the old ones, and the difference cuts the other way from caution: **10 minutes after a `Stop`, with no one-hour floor**, against 90 minutes of transcript silence. The floor existed because a session could be waiting on a wake-up nothing outside it could see; the hooks now record a pending `ScheduleWakeup`/`CronCreate`, and a slot with one is never stopped, so the floor's reason is gone (owner, 2026-10-01). It also reaches further — today's ssh sessions feed the registry and are judged by the same rules (until v0.4.0; since then only a zmx-held claude is registered — dev/README.md § claude-sessions). A rule that much more aggressive is read before it acts: **Stage A** (until 2026-10-06) runs the dry run every 3 minutes from the entrypoint, logging to `~/.local/share/claude-sessions-dry-run.log` because its verdicts go only to stdout, while `offload-idle-claude.sh` keeps stopping; **Stage B** switches to the live command and deletes the script in the same commit, at which point the 90-minute row above becomes ⚠︎SUPERSEDED. Same `DEV_IDLE_OFFLOAD` switch for both, since in Stage B it becomes the new one's. **No memory gate** (owner's decision). ⚠︎SUPERSEDED IN PART: the orphan sweep shipped log-only and was to be armed after a week of its log had been read — it was armed in v0.3.0 on 2026-10-03 instead; see the sweep row below. Phase 5 of [`../plans/claude-sessions.md`](../plans/claude-sessions.md). **Stage B is in base `2026.10.06`, the same base as zmx** (infra#9, owner's word, 2026-10-06), live on each container from its recreate onto it — armed on **claude-sessions v0.4.1**, after a council review found and reproduced claude-sessions#9 against v0.4.0: a slot running background subagents, forks, Workflow or Monitor fires no hook while they work, so ten minutes after its parent's `Stop` it read idle, and a live pass would have stopped it and everything in it (this session's own detached slot, with four council agents working, dry-ran to `would offload, idle 13m`). v0.4.1 keeps a slot whose `Stop` listed background work and counts idleness from the newest transcript or subagent-transcript write; reproduced on infra-dev with a real zmx session and a stand-in claude — a calibration with neither signal `would offload, idle 11m`, background listed `kept — background work running: …`, a fresh subagent write `kept — idle, offloadable in 600s`. Between v0.4.0 and v0.4.1 the arming was held; the hold never shipped. The gate was read on **or3-dev**, which had the slot use infra-dev's 19-hour window lacked: 2026-10-03 14:19 → 2026-10-06 08:18, 1,320 passes, none more than 4 minutes apart, five slots, up to three live — every `would offload` checked against its transcript with no overlap, holds one pass each, the four `would close` lines an unprompted session with no transcript, no sweep line, agent view off, hooks firing, and the one dropped `SessionEnd (other)` (06:17 on 2026-10-06) a menu close, confirmed by the owner in session with infra's agent on 2026-10-06 (not on infra#9). It also showed the old script **stopped nothing in the whole window**: its newest-transcript clock let one active slot keep every other alive, so swapping cost nothing it was doing. **The one thing that evidence could not cover** — v0.4.0 reads "attached" from zmx's `clients=`, not abduco's socket bit — was accepted on confidence, not proof: upstream's `tests/zmx_real.rs` drives the real zmx on a pty (`clients=1` attached, `clients=0` after Ctrl-\\), the same cycle was run on infra-dev with zmx 0.8.1, and a daemon that does not answer reads as unknown and **keeps** its slot (`attached_or_unknowable_attachment_keeps_it`). The swap deleted `offload-idle-claude.sh` and, with its last user gone, abduco and its build stage. The entrypoint loop now records failed passes — exit code, a 124 named as the timeout, stderr — because the Stage A loop's `| sed` hid every exit status — its `2>&1` kept the error text, not whether the pass failed — and it keeps each pass's verdicts too, in `~/.local/share/claude-sessions-passes.log`, so an offloader that keeps everything still leaves a trace. Stage A's dry-run log is left on the volume, not deleted at boot, because it is this row's evidence. **From `2026.10.06.1` (claude-sessions v0.4.3, taking v0.4.2) an Esc ends a turn**, and that cuts the aggressive way: an Esc fires no hook, so an interrupted slot used to read busy — or waiting on you — until its next turn, kept indefinitely; now it is offloadable ten minutes after the transcript's trailing interrupt marker, if that marker is newer than the hooks' last event and nothing follows it. Taken on a calibrated check against a real zmx session and a stand-in claude (the hooks row above), **with one known gap accepted and filed upstream as claude-sessions#10 — closed in v0.4.4 for agents (`2026.10.06.2`, the hooks row above); work with no agent behind it, a cloud session, is still held only by its writes, and v0.4.4 deliberately does not count Claude Code's housekeeping or its artifact watch as background work (claude-sessions#12 has the review's notes)**: background work started in the Esc'd turn is missing from the slot's background list (only `Stop` writes it, and an Esc fires none), so it holds the slot only through its own subagent-transcript writes, and would be stopped after ten quiet minutes detached — the one way this release can stop working agents, narrow enough to pin on the owner's fix-don't-block rule. |
| **The orphan sweep is armed in claude-sessions v0.3.0, five days before the week of log it was waiting on, and it rests on the agent view being off** | Armed on the owner's word on 2026-10-03, in claude-sessions (`2c34c9d`), not here: a live `claude-sessions offload` now kills a `daemon run --origin transient` tree whose parent is no longer a `claude` and which is at least ten minutes old, signalling each process by pid **and** start time. The week of log was there to find out whether a transient daemon detaches on purpose; what settled it instead is that the one thing which legitimately does — **agent view's supervisor, which outlives its session by design** — cannot start in these containers, because the managed settings and `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` both forbid it (the agent-view row above). **That makes the agent-view policy load-bearing twice over**: it was about zero's RAM, and it is now also what keeps the sweep from killing working supervisors. Turning the view on in any container means stopping its offloader first. **Nothing is killed here until Stage B**: infra still runs `offload --dry-run`, under which the sweep logs `sweep: WOULD KILL` and stops nothing — so Stage B now arms the offloader and the sweep in one step, and the `WOULD KILL` lines in `offload.log` meanwhile are the week of evidence the earlier plan wanted, read before that step rather than before the release. They were a SUPERSET of what the live sweep would kill, the dry-run branch skipping the ten-minute age check — ⚠︎SUPERSEDED by v0.3.4, whose dry run applies the check (`sweep: would keep, too young …`), so a `WOULD KILL` is now exactly what Stage B would kill. Pinned at `2026.10.03`, superseded by `2026.10.03.1` (v0.3.2) before it was rolled out. **Live from base `2026.10.06`** (Stage B), on each container from its recreate onto it. |
| **An ssh login lands on `claude-sessions-door`, a shell script in the image, and the menu failing can never lock the door** | The contract is claude-sessions' `docs/design.md` § *The door*; infra owns the script because infra owns the login. **Only an interactive login gets the menu**: a forwarded `SSH_ORIGINAL_COMMAND` runs as given and a login with no terminal on stdin or stdout gets `$SHELL -l`, because a full-screen program on the far end of rsync, scp or `ssh box cmd` corrupts the stream or waits for a key. **Exit 0 is the owner quitting and ends the login; anything else becomes `$SHELL -l`** after one line — claude-sessions has already said why — so a missing binary, a narrow phone or an unreadable registry costs a keypress, not a trip to `<alias>-sh`. **`$SHELL`, never a named shell**, because the base serves fish (infra-dev) and bash (dd, dossier). **A script, not a mode of the binary**, so the fallback does not depend on the thing it falls back from. (Since 2026-10-06 it also catches an abduco-era block's `abduco -A claude claude` — the menu at a terminal, exit 127 without one — because abduco left the image and that command would otherwise end the login.) ⚠︎SUPERSEDED IN PART 2026-10-04 by the forced-door row below — the client no longer names the door, so the mismatch this clause accepted cannot occur. **Switched for every alias at once, knowingly**: the client template serves every dev container and each pins its own `BASE_TAG`, so a client re-run before a child bumps gives that child's `ssh <c>` `exec: claude-sessions-door: not found` — offered a per-alias opt-in, a wait for all children, or a silent fallback to the old command, the owner took the switch now, with `<c>-sh` as the way in meanwhile. The silent fallback was the one to refuse on principle: a login that quietly becomes the old one is a guess. Landed 2026-10-02 at `2026.10.02.1`. **Exit 129 is not special-cased** (2026-10-04, against claude-sessions' offer in infra#6): from v0.3.7 it means the terminal went away and the menu wrote nothing, and the door's line and `$SHELL -l` then meet a hung-up terminal — `echo` gets EIO and is ignored, and the shell finds no tty, reads EOF and exits — while in practice the pty hangup has usually taken the door down already. A branch for a case that already ends quietly would be code with nothing to do. ⚠︎**To be SUPERSEDED for the dev containers** — decided 2026-10-25, not yet built: the menu moves to the hub (*Dev containers: one compose file in `infra`, one memory pool, `claude-sessions` only in a hub* below). |
| **The door is the container's sshd `ForceCommand`, not each client's `RemoteCommand`; forwarded commands stay in `~`** | Proposed by claude-sessions in infra#7 at the owner's request, taken 2026-10-04 on the owner's rule to fix a proposal's problems rather than treat them as blockers, and to prefer the simpler fix. `dev/sshd_config` gains `ForceCommand /usr/local/bin/claude-sessions-door` and `Subsystem sftp /usr/lib/openssh/sftp-server`; `ssh-dev-block.j2` loses `RequestTTY` and `RemoteCommand` and becomes one transport-only `Host <c> <c>-sh` block. **What it ends:** a client naming a program its container's image lacks (a not-yet-bumped child answered `exec: claude-sessions-door: not found`), two aliases per container, and `ssh <c> cmd` being a client-side error. **It reverses a written rejection** (`dev/in-workspace`'s header), and each reason is answered rather than waived: *$SSH_ORIGINAL_COMMAND* — the door already ran it, and now unsets it first so an old client's `RemoteCommand in-workspace claude-sessions-door` reaches the menu instead of looping; *sftp* — `internal-sftp` is a word no shell can run once a command is forced, so a real `sftp-server` binary, which the door runs like any command; *boot-path config on the only way in* — it is not the only way in (`docker exec`, the loopback port), the door falls back to a shell on any menu failure, and the image that names the door is the image that has it; *care with what you are connected through* — it governs the rollout, which is a base bump and the owner's recreate, never a live sshd restart. **Forwarded commands run in `~`, deliberately not `/workspace`** (the issue's alternative, chosen for simplicity): it is exactly where they ran under `<c>-sh`, so scp, sftp, Zed, ansible and `authorize-client-key.yml` see no change, no sftp-specific cwd rule is needed, and nothing can drop files into the repo by default; `ssh <c> in-workspace cmd` asks for the repo. **`<c>-sh` stays as a second name** on the same block, because or3's phone tunnel (`ssh -N -R` over `or3-dev-sh`) and `authorize-client-key.yml` use it, and `-N` never runs the door. **Verified before landing** on a throwaway unprivileged sshd in infra-dev (127.0.0.1:2299, the live sshd untouched), every probe first calibrated against today's config: menu and `q` with one alias; a forwarded command in `/home/dev`; `-T`; sftp, scp and `scp -O` round-tripping into `~`; `-N -L`; `ssh -t <c> in-workspace` in `/workspace`; an old client block still reaching the menu; and a missing menu binary falling back to a shell. Zed was not runnable there and is a bring-up check. A child that must not have the door sets `ForceCommand none` in its drop-in. ⚠︎**To be SUPERSEDED for the dev containers** — decided 2026-10-25, not yet built: the door moves to the hub (*Dev containers: one compose file in `infra`, one memory pool, `claude-sessions` only in a hub* below). |
| **A claude-sessions slot is a zmx session, not an abduco one; zmx is pinned by tarball hash and changes only with a base bump** | claude-sessions v0.4.0 (infra#9), on the owner's choice, 2026-10-06. **Why abduco went:** its client switches the terminal to the alternate screen on every attach (`\e[?1049h`), and there Windows Terminal and Termux turn a wheel or a swipe into Up/Down keys, which claude reads as prompt history — so v0.3.8's own-scrollback fix produced arrow keys, and the terminal's buffer was unreachable anyway. zmx sends no such switch. **The cost, measured upstream and accepted:** every attach replays the session's history (≈1.08× its bytes, capped near 10,000 lines, ≈120 KB compressed at 80 columns — one replay per lock-screen drop on the phone); a detach sends `ESC c`, which clears Termux's scrollback until the next attach; a narrower reattach rewraps history into the cap; and a daemon killed with `KILL` leaves its claude running. **Installed as `/usr/local/bin/zmx`, by name**, because a slot binds only when its claude's parent process is called `zmx`. **Pinned and hash-checked per architecture** (the tarballs, as claude-sessions' CI checks them), with `zmx version` a fatal build check run against a throwaway `ZMX_DIR` because it creates its socket directory to report it. **Never upgraded in place:** a zmx release that changes its protocol ends running sessions, so it moves only with a base bump, whose recreate ends them anyway. Sockets are `/tmp/zmx-<uid>` and logs `~/.local/state/zmx/logs`; neither needs a volume. **abduco left the image in the same base**, with Stage B: its last user was `offload-idle-claude.sh`, which listed abduco sessions and so could not see a single zmx slot. **Fetched from zmx's GitHub release since 2026-10-07, not zmx.sh:** zmx.sh answered 404 for the aarch64 tarball to GitHub's runners (two attempts of the `2026.10.07` build, the x86_64 one fetched fine in the same run) while still serving it to zero, and it sends `s-maxage=604800`, so a cached answer can stand for a week. The release assets' digests are the pinned hashes exactly, so the bytes are unchanged and only the copy they come from moved. |
| **The offloader acts on measured activity alone, and a quiet wait is held by `claude-sessions keepalive`** | The owner's decision, 2026-10-08, taken upstream in claude-sessions v0.4.7 and pinned at `2026.10.08`. Every rule that read Claude Code's hooks — the idle-since-`Stop` clock, timers, the background list, waiting-for-you, processes under claude, transcript writes — kept growing corners a self-update could move (claude-sessions #9, #10, #11, #12, #13 all came from them), while what a process does to the kernel means the same on every version. So a slot goes when it is detached, not under a keep-alive, and quiet for 10 minutes by its own bytes and CPU; **a slot waiting on the owner goes too**. What it cannot see — a quiet wait — claude asks for with `claude-sessions keepalive <duration>` (at most 12h), told when by a skill the binary ships and the entrypoint writes to the config volume at every start, through a temp file and a rename. Errs to keeping: a background poller or Claude Code's 30-minute reinstall reads as activity (claude-sessions#14, measured here). The 3-minute timer is now load-bearing — the CPU budget is per window, so a slower one reads an idle claude as busy — so the loop now sleeps to a fixed rate (180 s less the pass's own time) rather than a fixed 180 s after it. Infra's side changed with it: the hooks drop-in is five events feeding the menu only; `make verify`'s `bgtasks` binary check went, and the timer-tool check asked for in #13 was never added, and a `skill` line takes their place, comparing the installed skill with what the pinned binary prints — it is now the one thing a quiet wait depends on; the pass log stays at 16 MB because its measured lines are now the offloader's reasons. Checked before pinning, on a copy of the live registry against the real zmx and claude: a first reading reads `kept — not quiet long enough, offloadable in 600s`; `keepalive 5m` from inside the real slot found it by `ZMX_SESSION` and wrote only the copy; the next pass read `kept — kept alive for 2m more`, `keepalive 0` ended it, and a reading too soon after the last read `kept — not measured yet`, erring to keeping. ⚠︎**The rule stands; where it runs is to be SUPERSEDED** — decided 2026-10-25, not yet built: the offloader runs in the hub and measures each container over ssh (*Dev containers: one compose file in `infra`, one memory pool, `claude-sessions` only in a hub* below). |
| **A client's ssh blocks never depend on its Access tokens: every container gets a block, a missing token is named at connect time, and the two halves are separate tags** | A composed `configure-client.yml` run stopped dead at a blank prompt for a container that was not up, and before that a container without a token got no block at all — so the ssh config of every container hung on the Cloudflare state of each. The block only needed the token because its `ProxyCommand` sourced the file unconditionally and failed as *Connection closed*; it now tests for the file and, without it, prints which run fixes it and exits **before `cloudflared` starts**. That last part is deliberate: these Access apps admit service tokens only, and cloudflared's browser login is no use from Termux, so nothing may fall through to it. With the block safe on its own, a **blank Client ID and blank Client Secret skip that container's token** and the run continues (one blank alone is still refused as a slip), `meta: end_play` is gone, and the halves are tagged `ssh` and `access` — the fleet import and the inventory guard included, the guard as `always`, because a guard that `--tags` can skip reintroduces the silent empty run it exists to stop. Tags rather than a second playbook, because both halves need the same cloudflared and WSL preflight, and two copies of that is how they drift. 2026-10-02. |
| **The laptop's ssh config is LF throughout, and every template that reaches it is ASCII** | Running the client plays from WSL mangled the comments on the Windows side: the templates drew their rules and dashes with `─` and `—`, and that file is opened and edited under a Windows codepage, where each arrives as several characters of something else. The line endings were mixed for a worse reason than looks: `blockinfile` matches its markers as `marker + os.linesep` on a file read with newlines preserved, so once a Windows editor saves the file as CRLF its own markers stop matching — reproduced: the next run inserted a second block under the first, and ssh, taking the first value it obtains, reads the stale one. That is the same shadowing the 2026-08-29 rename caused, by a different road. LF and not CRLF because LF is the only ending `blockinfile` can write from WSL and Win32-OpenSSH reads it, so the plays convert the whole file before touching it rather than round-tripping it every run; the `.cmd` wrapper stays CRLF, for cmd.exe's reason (above). The conversion is `grep` then `sed`, because `replace` opens the file with universal newlines, never sees a `\r`, and reports ok. **Both files, not just the Windows one:** the first cut converted only the laptop's Windows config, on the theory that only Windows tools write CRLF, and the owner's first dry run disproved it the same day — WSL's own `~/.ssh/config` was CRLF too, visible as an `infra-dev` block about to be added under the `infra-dev` block already there. ASCII is enforced by an assert on the template *source*, not the rendered block, which would check only the branches one client's vars select; it runs before anything is written. Text a human wrote in that file is converted to LF but never rewritten, as with the `Host *` note: the play owns its blocks, not the owner's prose. |
| **Playbooks are named for the task, with `client-` and `server-` prefixes, and an imported half starts with `_`** | Decided with the owner 2026-10-04, from the question "what do I run to set up my ssh config" asked by someone who does not care how the plane is built. `configure-client.yml`, `prepare-dev-host.yml`, `create-dev-tunnel.yml` said which side of the system a play touched, not what it was for. The prefix answers the one question that matters before typing: does this change the machine I am on (`client-`), or a Pi and the edge in front of it (`server-`, from the control node). `_client-fleet-ssh.yml`, `_client-dev-ssh.yml`, `_dev-container-tunnel.yml` and `_dev-container-host.yml` are halves that `client-home-ssh-config.yml` and `server-create-dev-container.yml` import, on the convention `_assert-inventory.yml` set. The two client halves' `~/.ssh/config` markers now name the play you RE-RUN, and each carries a `state: absent` for its 2026-08-29 and 2026-10-04 predecessors, per the row above. The rows above that name the old files are history and stay as written. The `authorize-configure-client-dev.yml` the README and `docs/ssh-clients.md` told you to run had not existed since an earlier rename missed them: a rename sweeps every file that names a play, and the generated `docs/fleet-inventory.md` catches up on its next run rather than by hand. |
| **The Cloudflare API token is a user token, the union of what every play that talks to Cloudflare needs, kept at `~/.config/cloudflare/api-token` (0600) on each machine that runs plays — never prompted for; a missing file prints the minting steps and stops** | Until 2026-10-04 every tunnel play prompted for it on every run and the dev-tunnel header made a virtue of never storing it. The owner asked to stop retyping it, then for no prompts at all. The read, the mode check and the `/user/tokens/verify` preflight are one tasks file, `_cf-api-token.yml`, imported by all five plays, leaving a fact named `cf_token` rather than the guarded `cf_api_token` because a localhost fact survives into the next imported play. The trade: a token at rest on the control node, against four plays that each prompted for a different subset and three prompts that each described a different permission list — a list that had drifted (`Edit` in the dashboard, `Write` in the API) and was checked against nothing. It lives **outside the checkout** because the checkout is bind-mounted into `infra-dev`, which has no route to the fleet by decision and must not get one to the edge by accident; outside `$INFRA_SECRETS` because that is mounted into the container; and it is still refused on the command line (`-e cf_api_token=`), read by a task rather than `vars_prompt` so an extra var cannot silently pre-empt the file. A **user** token, not an account one, because the plays prove it with `/user/tokens/verify`. The five permissions, and the three sources they were checked against, are in `ansible/README.md` § *The Cloudflare API token*; Vault remains the Phase 4 answer when more secrets want the same home. |
| **A dev container's edge and host halves run as one play, `server-create-dev-container.yml`; the client half stays separate** | ⚠︎ This supersedes the README's defence of three separately-run plays ("three places, three credentials, three rates of change"). Neither server half needs sudo, so the only credential the combined play asks for is the API token, now a file; the Access service token belongs to each client and is still `client-home-ssh-config.yml`'s to collect. The order flips to edge first: the host half then writes the hostname into `dev/.env` in the same run, by a host fact (`dev_tunnel_hostname_from_edge`), and the first `make up` brings the container up with its tunnel instead of the old host → `make up` → edge → host-again sequence. The host half still keeps `tunnel_hostname` explicit on its own command line, because there absence means "preserve", so the row above about deriving names is not weakened. The host half is `infra-dev`-only, since it writes `dev/.env` in this checkout; for any other `-e container=` the play runs the edge half and prints why the rest is in that container's own repo. |
| **`infra-dev` publishes no port; break-glass is `docker exec` through the host's own ssh** | ⚠︎ Supersedes the "loopback publish stays" paragraphs in `dev/README.md` and `management-plane.md`, which argued that dropping `127.0.0.1:2225` would leave `docker exec` — needing sudo — as the only fallback to the tunnel. Decided with the owner 2026-10-04: both paths ran through zero's sshd anyway (`ssh zero` first, then either the port or `make shell`), so the port never bought an independent route, only a passwordless hop, and it cost a hand-kept registry of numbers that nothing consumed and only a person would notice drifting. The `ports:` block, `DEV_SSH_PORT` and `DEV_SSH_BIND` are gone from `dev/compose.yaml`, `dev/.env.example` and the host half of `server-create-dev-container.yml`; the registry in `client-home-ssh-config.yml` keeps containers and repos, no ports. Break glass is `ssh -t zero 'cd ~/infra/dev && make shell'`, which already existed. The other three containers' repos still publish `2222`–`2224`; dropping those is each repo's own change. The container's sshd still listens on 2222 inside, for the tunnel. |
| **Every client mints its own Access service token, named `<container>-<client>`; nothing is shown, prompted or pasted** | Until 2026-10-04 the edge play minted ONE token per container, printed its secret once, and the owner typed it into every client — the paste-free design of 2026-08 was really a paste-once-per-client design, and the owner asked for none. `client-home-ssh-config.yml` now holds the Cloudflare API token too (the same `~/.config/cloudflare/api-token` the server plays read; a separate API token per machine is fine, and preferred), creates or rotates a service token for THIS client over the API, adds it to the container's `non_identity` policy by read-modify-write, and writes the file. Per client, not shared, because a shared secret can only be fetched by rotation, and a rotation on one client cuts off every other: one token per client is the only shape in which "fetch" and "revoke one laptop" both work. The edge play creates the Access application with NO policy — an application with no policy admits nobody, which is the right state until a client has run. The policy update preserves every token already admitted, so the shared `<alias>` tokens of the old design keep working until removed by hand in Zero Trust. Removed with this: `vars_prompt` and `pause` prompts in every play, `prompt_for_token`, `st_client_id`, `rotate_service_token`, `service_token_name`, and the printed-secret banner. The row above about recovering a lost secret by rotation stands, and is now what `-e replace_token=true` does for one client. |
| ⚠︎SUPERSEDED 2026-10-30 — **Crush is in the base at the latest release, resolved per build and installed from Charm's signed apt repository** | The owner's call, 2026-10-11: a second agent harness to try, in every dev container, at the latest version and not pinned, reached as `ssh -t <c> in-workspace` then `crush`. No slot, no hooks and no environment variables; the provider key is typed at first start and kept on the `~/.local/share` volume every child already has. **Unpinned but verified.** apt checks the repository's signature, and the build keeps only the certificate whose fingerprint is pinned (it imports `gpg.key` into a scratch home and exports that one key). A review found that comparing the file's first fingerprint and keeping the whole file would also trust any key appended after it, and reproduced that. The alternatives were the npm package (`@charmland/crush`, a Node launcher whose postinstall fetches the binary unsigned) and a release tarball (a `checksums.txt` that vouches only for itself). **The version is resolved outside the build** by `dev/crush-latest` (GitHub's `/releases/latest` redirect), which CI and `make base` both run, and passed in as `CRUSH_VERSION`, because Crush has no updater and Docker caches an unpinned layer by its instruction, so the image would otherwise carry the first version it ever installed. Keying on the tag was the first design and was replaced before it shipped: it would have re-pulled ~25 MB of unchanged Crush on every bump, against the registry-cache row. Now the layer misses only on a Charm release, both architecture legs get the same version, and it sits above the dev user, claude-sessions and zmx so that their bumps never rebuild it. apt reads only `charm.list`, so a Debian or NodeSource failure cannot fail it, and the source and key are removed afterwards. **What it costs, accepted:** a tag carries the release current when it was built, so a forced rebuild or a local `make base` of the same tag later can carry a newer one; with GitHub or `repo.charm.sh` down, CI fails until a re-run and `make base CRUSH_VERSION=none` builds without it. `make verify`'s `crush` line is the lasting readout. **Left undecided: Crush's usage metrics, which are on by default.** Turning them off is a config key or `CRUSH_DISABLE_METRICS`, and is the owner's call. Built first at `2026.10.11`. Dropped by the owner on 2026-10-30 when pi was chosen (the pi row); the layer, its helper and its volume mount are gone from base 2026.10.30. |
| ⚠︎SUPERSEDED 2026-10-30 — **Jcode is in the base alongside Crush, hash-pinned to a version rather than resolved per build** | The owner's call, 2026-10-16: a third agent harness to try, in every dev container, reached the same plain way as Crush — `ssh -t <c> in-workspace`, then `jcode`. **Pinned because there is nothing to verify against:** jcode (`1jehuang/jcode`, MIT, Rust) ships only unsigned GitHub release tarballs with a self-vouching `SHA256SUMS`, no signed apt repository, so the trust anchor is a per-version SHA-256 in `Dockerfile.base` (the cloudflared model), not a signing key — and "latest" without a signature is a different binary on every rebuild, so it is a manual bump per release, not a `dev/jcode-latest`. **Installed the way jcode itself installs, so its updater works:** the real binary goes in `~/.jcode/builds/versions/` with a `stable` symlink and a launcher at `~/.local/bin/jcode` (first on PATH), all owned by `dev` — `jcode update` and `--auto-update` (on by default) repoint that `stable` symlink, which only works when the launcher and `~/.jcode` are writable by `dev`, not a root-owned `/usr/local/bin` copy. `~/.jcode` is its own `infra-jcode` volume, so an update and the provider login under `config/jcode` survive a recreate. **Not offloaded, deliberately:** jcode is light enough not to need the claude-sessions offloader, and its own 5-minute idle timeout reaps the background server it detaches. **Left undecided: jcode's usage metrics, on by default** (the installer's funnel telemetry to `telemetry.jcode.sh` is not taken — the tarball is fetched directly, no installer). Built first at `2026.10.16`. Dropped by the owner on 2026-10-30 when pi was chosen (the pi row); the layer, its helper and its volume mount are gone from base 2026.10.30. |
| **pi is in the base, pinned, with a package set that gates every tool call, and its state on the `~/.local/share` volume; claude-sessions 0.10.0 runs it as a slot** | The owner's call, 2026-10-30: one second harness beside Claude Code that costs less to run, talks to an open model and is managed by the hub as a Claude session is. Crush and Jcode were dropped the same day (their rows above). Pi is `earendil-works/pi` (MIT); its model is `qwen/qwen3.8-flash` over OpenRouter, a cheap stand-in for an open model run locally later. **Pinned, not self-updating:** `@earendil-works/pi-coding-agent@1.4.0` goes into `/opt/npm-global` with `--ignore-scripts` (the only install scripts in its tree are a version warning and a no-op), and `PI_SKIP_VERSION_CHECK=1` stops it asking for a newer one, so a bump is a rebuild, as for the language servers. Claude Code stays the one thing in the base that updates itself. **Packages in the image, state on the volume.** `PI_CODING_AGENT_DIR` is `~/.local/share/pi`, on the volume every child already has, so sessions survive a recreate. Packages on that volume would never take a bump, because a volume shows the image's content only while it is empty. `pi install` writes packages under its agent dir's `npm/` and nowhere else, so the build installs them with the agent dir pointed at `/opt/pi/seed`, and the entrypoint links `<agent dir>/npm` to `/opt/pi/seed/npm` at every start. `PI_PACKAGE_DIR` reads like the switch for this but moves pi's own install, so it is not used. **The seed is put back at every start:** the `packages` list in `settings.json` always, since pi reads it to know what is installed and the agent can edit it; the other keys, `models.json` and the two extension configs only where the volume has none, so the owner's theme and model stay. **`/opt/pi` is root-owned**, unlike the npm tree, because it holds the gate's code and the seed the gate's config is restored from, and an agent in the session must not be able to edit either. The cost: `pi install` fails at run time, and adding a package is a rebuild. **The packages, each pinned:** `pi-permission-classifier` and `@gotgenes/pi-permission-system`, the judge and the gate (reads allowed; writes and edits asked inside `/workspace` and denied outside it; any path outside `/workspace` denied; the shell and every other tool asked, except `claude-sessions mail` and `keepalive`, which the managed policy and the keepalive skill run every turn and a prompt on each would make unusable; the session's model judges, and a judge that fails never allows); `cc-safety-net`; `pi-subagents`; `pi-web-access`; `pi-lens`, whose ast-grep binary npm's integrity hash pins, and whose run-time downloads of linters and language servers are turned off by its own two variables, since they are neither pinned nor hashed; `@nredd/pi-dev-tools`; `pi-powerline-footer`, in plain characters for Termux's font; `pi-themes`. pi-auto-mode was considered and dropped for the gate and judge pair: it has one author, and it fails open. **The key is a file, `openrouter-key` in `HUB_SECRETS`.** The hub copies it beside each container's mail-token when it starts, and pi reads it with `!cat /run/github/openrouter-key` once per process. Not an environment variable: no secret reaches a container that way, and one would land in `~/.ssh/environment` and in `docker inspect`. The file is optional; without it pi reports the missing key at the first prompt. **Settings:** `tuiMode: regular`, because pi's fullscreen default takes the alternate screen and mouse tracking, the pair that broke scrolling from the phone for Claude Code; `defaultProjectTrust: never`, because a trusted `.pi/` in a repo could replace the gate and install unpinned packages; `enableInstallTelemetry: false`. `PI_OFFLINE` is set only for the build and the smoke test, not in the image, so a running pi may refresh pi.dev's model catalogue at start and will try to install a package missing from its list. No OpenRouter data-policy setting, by the owner's call. **The slot is claude-sessions' work:** 0.10.0 starts a pi slot with `p`, runs `pi --session-id <id> --tui-mode regular` under zmx, binds it by comm `pi` through an extension the entrypoint links from the hub's volume, resumes it by id and lists pi's sessions under Archived. Pi has no hook, so the managed policy has it read mail with `claude-sessions mail list`. `make verify`'s `pi`, `pi-ext` and `pi-tui` lines are the lasting readouts, and the smoke test checks the gate, `pi list` offline and the binding. Built first at `2026.10.30`, the menu from claude-sessions 0.10.0. |
| **Rootless podman on `one` waits for MicroOS** (management-plane Phase 7) | The owner's call, 2026-10-25, putting `one` where `zero` already was. On OpenRC, rootless podman cannot enforce memory limits (`management-plane.md`'s trade table), so converting now would trade a working limit for leaving the `docker` group and then be redone as Quadlet at the migration. On MicroOS it is one conversion with both. The cost is Phase 8: an unprivileged scheduled audit of `one` waits with it. |
| **`destiny-director` leaving `two` is not a management-plane phase** (was Phase 6) | The owner's call, 2026-10-25: whether and where the bot moves follows what Destiny Director needs, not this plan, so it is [gsfernandes81/infra#11](https://github.com/gsfernandes81/infra/issues/11) and may never become a PR. What it leaves open is Phase 8's precondition that `two` runs no containers, which is undecided and recorded on Phase 8's row rather than settled here. |
| **Phase 8 is not gated on Phase 7** | The owner's call, 2026-10-25. 7 was a gate only because a scheduled run cannot type a sudo password and reading containers needs root — but that is one part of an audit, and `zero` needs sudo until MicroOS whatever 7 does, so Phase 8 was always going to start partial. So it starts with the scheduled checks that need no root, container inventory stays an interactive `-K` run, and 7 (now waiting for MicroOS on `one`) later lifts that half for `one`. The other precondition, no containers on `two`, is met: the owner reported the same day that `destiny-director` no longer runs there. |
| **The fleet inventory lists btrfs subvolumes without mounting anything** | Asked for by the owner, 2026-10-24; on 2026-10-25 they asked that the array's top level be mounted on a throwaway directory rather than fstab's `/mnt`. No mount is needed: `btrfs subvolume list -a` lists every subvolume of the filesystem a path is on, so any mounted `/media/*` path answers it, and `server-generate-fleet-inventory.yml` keeps its promise of changing nothing on any host. One listing per filesystem, keyed by uuid; mounts are matched to subvolumes by uuid and `subvolid`, so two filesystems' subvolume 256 stay apart. `gen` is not rendered (it moves on every write, and the report is committed), and there are no sizes: without qgroups the only figure is `btrfs filesystem du`, a walk of every file, Immich's included. |
| **A moved dev container carries its history** (management-plane OPEN 1) | The owner's call, 2026-10-25. The credential volume is the login *and* the working history (22 MB of projects, sessions and uploads in August, growing), and the choice was a seamless move against keeping transcripts on one box. Seamless won. What comes with it: exactly one holder at a time, teardown before bring-up, because two holders of a rotating refresh token log one of them out; and the staging copy of the volume is a credential, so its permission step must fail the run, never warn. |
| **No control node inside the fleet** | The owner's call, 2026-10-25, closing management-plane § *A control node inside the fleet*. `infra-dev` keeps no route to `zero`, `one` or `two`: a control node in a container on a box it controls cannot fix the box it lives on, and a fleet key there makes compromising the container compromising the fleet. Whether this also retires Phase 8 (`two`, read-only and scheduled) was asked the same day and is recorded on that phase when answered. |
| **Phase 8 dropped: `two` is not a scheduled control node** | The owner's call, 2026-10-25, the same day as the row above, which it follows from: `two` is inside the fleet. It would also have reversed two rules — no Ansible on a Pi, and no box holding a key to another — been partial until MicroOS (containers need root to read), and spent writes on the fleet's oldest SD card. Its one unique benefit, a report with nobody at the phone, goes to the proposed Cloudflare Worker that watches the hosts from outside and mails on failure, which needs no key on the fleet. If scheduled drift reports are wanted later: each host writes its own, the phone collects them. |
| **Phase 4's Vault holds what a rebuild cannot recover without a person: `torrents`' VPN login, the hosts' tunnel credentials, the dev containers' secrets** | The owner's call, 2026-10-25, retargeting it from `send2ereader` and `ionic-traces`, which had nothing left to vault. Ansible Vault stays the mechanism. Out by design: the Cloudflare API token and Access service tokens, which are one per machine and one per client so each can be revoked alone; secrets that rotate as they are used (Garmin's session, Claude logins), where a stored copy goes stale or logs the holder out; and `immich`'s database password, which root on `zero` can reset. **Proton Pass was considered and set aside the same day**: its `pass-cli` could hold the vault password or the secrets themselves, and feed the Garmin re-login, but its Linux build needs glibc, which Termux lacks, and the owner judged the gain not worth that and a second dependency in the plays. |
| **`one`'s `/var/lib/docker` moves to the SSD now, on Docker, keeping its storage driver** | The owner's call, 2026-10-26. The SD card held every image, container layer, container log and named volume (`garmin-tokens`): the slow medium, and the one that wears. A subvolume `var-lib-docker` at the array's top level, mounted over `/var/lib/docker` by the tracked fstab, moves all of it with no Docker setting changed, so there is no `daemon.json` or `data-root` to track. **The overlay driver `one` already runs, not btrfs**, because the place was the point, not the driver: overlay on a btrfs disk is the default and best-tested path, while btrfs makes a subvolume of every layer and gives up the page cache overlay shares between containers, which a 1 GB box notices. **`one` turned out to be on the containerd image store**, not the classic `overlay2` this row first assumed: `docker info` reads `Storage Driver: overlayfs`, `driver-type: io.containerd.snapshotter.v1` (owner, 2026-10-26). Its images are containerd's, but the containerd is dockerd's own (`--config /var/run/docker/containerd/containerd.toml`, shims on `/var/run/docker/containerd/containerd.sock`), whose store is `/var/lib/docker/containerd`, so the one subvolume still holds everything, and the copy keeps the snapshotter's state as it is. **Not together with podman**, which still waits for MicroOS (the row above), and one change at a time keeps one suspect when something breaks. **Guarded like `/media`**, `nofail` and `chattr +i` on the bare directory, and `bin/check-mount-guards` finds it. A missing array then stops dockerd, so nothing runs on `one`, `send2ereader` and `garmin-mcp` included, which need no `/media` path; that is accepted over dockerd starting empty on the card, where the next deploy would pull everything back onto it. **A copy, not a re-pull**, so containers keep their ids and the locally built `garmin-mcp` image, its build cache and the Garmin login all come along; `server-stop-deployments.yml` was written for it, stops and starts with `compose stop`/`start`, and prints the ids on both sides. `zero` stays on its card until MicroOS: `one` is where the procedure is proven. **Run 2026-10-26 by the owner, and proven rather than reported:** 9.06 GB and 184,957 entries copied with `rsync -aHAXS --numeric-ids`, and a second `--dry-run --itemize-changes` pass printed nothing; after `rc-service docker start` the driver still read `overlayfs` on the snapshotter with `/var/lib/docker` as its root, all twelve container ids matched the listing taken before the move, `check-mount-guards` passed all seven mounts, and the start play brought the other seven containers up healthy with the same ids. **Left to do:** the old copy, `/var/lib/docker.sd` on the SD card, stays as the rollback until about 2026-11-02, then goes with the temporary `apk` virtual package `.docker-move` (rsync). |
| **`zero`'s `/var/lib/docker` moves to `sda2`, the SSD partition outside bcache, not to the array** | The owner's call, 2026-10-26, following `one` (the row above), whose procedure it reuses. **Not the array**, though it has the room: `zero`'s array is the two hard disks in RAID1 behind a writethrough bcache, so a write there completes only when both disks have it, and Docker's writes (container layers, logs, image unpacking, the dev containers' work) would run at disk speed while competing with Immich for the same disks. On `sda2` every write is SSD speed and Docker depends on the SSD alone, not on bcache assembling both backing disks. Cached reads would be about even either way. **Not more bcache cache** either: a cache set takes one cache device, so `sda2` could only join by rebuilding the cache on the critical box, to grow 393 GiB of cache to 457 in front of 1 TB. **What it costs:** no mirror, the same as the SD card today. And `sda2`'s old Ubuntu install, 22 GB, which the owner said holds nothing of value (2026-10-26). **64 GiB for 47 GB**, so the move trims first (all build cache and dangling images; images no container uses are listed, and the owner decides) and mounts with `compress=zstd:1`, which image layers take well and a Pi 5 can afford. **Copied twice, once live**: `hosts/zero/docker-move-prep.sh`, a one-shot deleted after its run (git history keeps it), formatted `sda2` only after proving it is that old ext4, and copies while everything runs; the window's pass with Docker stopped then moves only what changed, so Immich and the dev containers are down for minutes, not for 47 GB at SD-card speed. Docker on `zero` is the same shape as on `one`, the containerd image store under dockerd's own containerd (owner's check, 2026-10-26), so `/var/lib/docker` is still the whole of it. **Run 2026-10-26 by the owner, and proven:** the trim took the 10.3 GB build cache (no dangling images; 12 GB of images no container uses were listed and left for the owner), the Immich dump was 141 MB and complete, the live pass copied 33 GB in 11 minutes, which compression stored in 19 GiB of the 64, and the pass with Docker stopped moved 47 files, 44 MB, after which a `--dry-run --itemize-changes` printed nothing. Docker came back on the same driver with all eight container ids unchanged, Immich healthy by itself (`restart: always`), Syncthing through the start play, the dev containers through `make restart` and `docker start`, and `check-mount-guards` passed all four mounts. **Left to do:** `/var/lib/docker.sd`, the 47 GB old copy on the SD card, stays as the rollback until about 2026-11-02, then goes with the apk virtual package `.docker-move`. |
| **Unused images are pruned by a play that keeps by rule, not by `docker image prune -a`** | The owner's call, 2026-10-26, after the hand-listed prune on `zero` that followed its move. `prune -a` deletes every image no container uses, which on this fleet includes an image pulled ahead of its `up` (the redeploy play pulls before it plans) and the dev containers' base, which their builds need. `server-prune-images.yml` keeps three kinds and says which kept each: an image any container was made from, running or stopped, because a stopped container is a deployment or a dev container between sessions; an image a tracked compose file names; and the repositories in `prune_keep_images` (`group_vars/fleet.yml`), for what a rebuild needs and nothing kept just in case. It removes by name without `-f`, so the daemon refuses anything in use, and it never touches volumes or containers, which is why it is not `docker system prune`. Build cache older than a week goes, so a recent build stays fast. |

## `two` also runs a test bot, and what that bends

`two` runs a **test** instance of the `destiny-director` Discord bot plus its Postgres,
under rootless podman, deployed on demand over SSH. See
[`deployments/destiny-director/`](../deployments/destiny-director/). Two things in this
file bend for it, and both are scoped deliberately, because the whole point of writing
them down was to stop them being re-derived loosely elsewhere.

> ### ⚠ SUPERSEDED, Aug 2026 — read this before the rest of the section
>
> **There is no `dd-ctl` and no `root-setup.sh`.** Deploys are plain `podman-compose`
> commands run in the shell of an unprivileged account (`claude`) that is **not** in
> `wheel`. [`hosts/two/setup/README.md`](../hosts/two/setup/README.md) is the build.
>
> Everything below about the forced command, its argument-less verbs, the root-owned
> dispatcher, the dispatch key and `DD_CTL_KEY_B64` describes an arrangement that no
> longer exists. It is kept because the reasoning is still the reasoning — and because
> the last subsection below called this outcome and named the wrong trigger for it.
>
> **What changed and why.** That subsection concluded a dedicated deploy account was
> "worth doing on the day `gavin` loses sudo, and not obviously before." The trigger was
> different: the account is for an **agent**, which needs to deploy, tear down and retry
> freely — and a fixed six-verb dispatcher cannot express that. Given a full shell was
> going to be needed either way, the question stopped being "how tightly can the verbs
> be constrained" and became "which account should hold that shell". An unprivileged one.
>
> **What it bought.** The dispatcher existed only because an escape landed on an account
> with sudo. With the deploy account unprivileged, an escape lands on the deploy account
> — so ~800 lines of shell whose correctness *was* the boundary are replaced by uid
> separation the kernel enforces. Two properties that were script-enforced are now
> enforced by the OS: the deploy account cannot become root (no `wheel`), and cannot
> choose the deployed image (the checkout is operator-owned and group-readable, at
> `/srv/infra`). The ambient-login-shell problem below dissolves with it — `claude`'s
> shell is `/bin/sh` with an empty home.
>
> **What it did not buy.** Resource exhaustion is unchanged: no cgroup delegation means
> no memory limit is possible, and the plausible OOM victim is still `cloudflared`, the
> only way in. That is mitigated the other way round now — `cloudflared` is pinned to
> `oom_score_adj -1000`, everything the deploy account runs starts at `+500`. Lateral
> movement onto the LAN is closed with iptables rather than a VLAN.

### The `SOURCE` pin is absent here, and only here

The rule above is *"`SOURCE` records a sha, never pulls"*, and its reason is exact:
otherwise a restart at 03:00 silently deploys whatever upstream HEAD is, and you find
out from mid-ocean. That reason does not reach this stack, for three independent
reasons:

1. **Nothing here restarts into a new version.** There is no boot autostart on `two` and
   `restart: always` re-runs the *same* image. A power cut leaves the box running
   nothing. There is no 03:00 to be surprised by.
2. **There is nothing to pin.** No source is built on a 700 MHz core; the image is built
   for `linux/arm/v6` by the upstream repo's CI and pulled from GHCR. There is no
   checkout on `two` whose HEAD a sha could be compared against, so a sha in `SOURCE`
   would be a number nothing on either side could check — the shape of pass-for-the-
   wrong-reason this file ends on.
3. **The stakes are a test bot.** If it deploys the wrong build, a test guild sees a
   wrong reply. Nobody is mid-ocean.

So `SOURCE` keeps the upstream URL and carries no sha, and `bin/check-sources` reports
the stack as **registry-deployed** — a recognised state, not drift and not an error.
It is recognised narrowly: one field that looks like a URL. A truncated file, a second
field that is not a sha, a third field — all still fail loudly. Absence of a pin is the
design here; a garbled `SOURCE` must never pass for one.

**This does not generalise, and must not.** For `torrents`, `immich`, `ionic-traces`
and `send2ereader` (until 2026-10-25, when it moved to a CI image pinned by digest, which is
a different shape again: see its section) the original reason holds in full: they are built from checkouts, on
hosts that come back by themselves, and two of them are critical and remote. If a
future stack wants the same treatment, it has to clear all three tests above, not cite
this paragraph.

### Deploys are SSH-triggered, not commit-triggered

Every other stack changes by editing this repo. This one changes by
`ssh two deploy-beacon`, which pulls the branch tag in `compose.yaml` and recreates the
container. The deploy is not recorded anywhere now — the dispatcher that kept an audit
log is gone.

That is deliberate: it is a rapidly-iterated test bot, and a commit per deploy would be
pure noise in a repository whose value is that its history is all signal. The trade is
real and worth stating — **this repo cannot tell you which commit is running on `two`.**
It can tell you which *branch*, because that is a tracked literal in `compose.yaml`; the
commit is `podman inspect`'s answer alone, and the README says so rather than leaving the
gap to be found.

That split is the reason the branch is not a `.env` variable. The deployed version is
already deliberately invisible to git; putting the deployed branch in a gitignored file
too would leave two blind spots where there is currently one, and a one-line edit to
`compose.yaml` to test a feature branch *should* show up as local drift — "this box is
running something non-standard" is worth seeing.

**The dispatcher takes no arguments at all.** Not validated arguments — none. Six fixed
verbs (`deploy-beacon`, `deploy-anchor`, `down`, `status`, `logs`, `logs-postgres`),
matched against exact literals, each running a fixed command line. An earlier version
accepted `deploy <bot> [tag|digest]` and `logs [service] [--tail N]` behind charset
checks, arity checks and a controlled word-split; all of that existed only to make
arguments safe, and deleting the arguments deleted the whole class of bug along with the
code that could be wrong about it. The stricter form — one keypair per operation, each
with its own `command=` in `authorized_keys`, so sshd does the dispatch and the script
handles no input — was considered and costs six keypairs to hold; it is the fallback if
the `case` is ever judged insufficient.

### What that does and does not buy — the accurate version

**`gavin` is in `wheel` and `sudo` is installed**, so anything escaping the forced
command lands on an account that can become root. The dispatcher is the whole boundary
and there is nothing behind it. Nothing in this repo should describe it as contained or
unprivileged, and **it has not had a dedicated adversarial review** — what such a review
still owes is listed in
[`hosts/two/system/README.md`](../hosts/two/system/README.md).

Removing the arguments means the keyholder cannot choose which image or which branch
runs. It does **not** mean nobody can:

> `compose.yaml` names a **moving branch tag**, so anyone with push access to that
> branch determines what code runs as `gavin` on the next deploy.

That is the real trust boundary, it sits upstream of this repo entirely, and it is
recorded here because the tempting summary ("the keyholder no longer chooses the image")
is true and yet leaves the larger exposure unstated. The lever, if it is ever wanted:
point `compose.yaml` at a branch only the owner pushes to, at the cost of a merge per
deploy. Not done — the current setup is a deliberate position, not a locked-down one.

### The forced command runs inside `gavin`'s login shell

**sshd does not exec a forced command — it runs `$SHELL -c "<command>"`.** `gavin`'s
shell is fish, and fish reads `/etc/fish/config.fish`, `~/.config/fish/conf.d/*.fish`
and `~/.config/fish/config.fish` on every startup, including a non-interactive `-c`;
only `fish -N` skips them. Three of those paths are `gavin`-writable by construction and
`root-setup.sh` §8 writes one of them itself.

So the row above — *"the live `dd-ctl` is root-owned, and that is the whole mechanism"* —
is true about the file and wrong about the word *whole*. Root-owning the dispatcher stops
the keyholder rewriting the dispatcher. It does not stop the deploy path being decided
one level up, by a file the same account owns, and the documented `md5sum` drift check
cannot see that happen. `restrict` does not help either: it implies `no-user-rc`, which
is about `~/.ssh/rc`.

**The ambient login shell is inside the deploy key's trusted computing base.** That is
the honest statement, and nothing below removes it:

- `root-setup.sh` §4 checks those four files' ownership and modes, and the directories
  holding them, and warns about anything in `conf.d/` it did not write — so a *third
  party* cannot get in there unnoticed.
- `dd-ctl` re-execs under `env -i`, so nothing fish exported reaches podman.
- The drift check in [`hosts/two/system/README.md`](../hosts/two/system/README.md) now
  lists those paths alongside the `md5sum`.

Which brings back the entry near the top of this file: **no new user on `two`.** Its
stated reason was that rootless podman's isolation comes from the user namespace, so a
second unprivileged uid buys nothing. That reason is correct and it is not the whole
question, because a dedicated deploy account also buys **a `/bin/sh` login shell and an
empty home** — the only arrangement that takes the ambient shell out of this key's TCB.
That fact was not in front of the decision when it was made.

**Re-stated with the fact in it, the decision still stands, and it is now a trade rather
than an oversight.** Against the account: a second uid to manage, `authorized_keys` and
subuid/subgid to duplicate, a second home for podman's storage on a 29 G SD card that
already worries about wear — and podman's storage is per-user, so the images and the
`pgdata` volume would have to move, which is a migration on the box that is the fleet's
lifeboat. For it: the deploy key would no longer run through a file `gavin` edits daily.
The deciding consideration is the first paragraph of this section's parent: `gavin` is
in `wheel` with `sudo`, so an escape from the forced command reaches root regardless of
which account it started from. The dotfile path is a *shortcut* to a place the key can
already get to; a dedicated account closes the shortcut without closing the destination.
It is worth doing on the day `gavin` loses sudo, and not obviously before.

**Do not let a future reader re-derive this as "the forced command bypasses the login
shell".** It does not, and the previous version of `root-setup.sh` said so in those
words.

### The lifeboat tension, stated rather than left for a reviewer

The roadmap says of `two`: *"Do not put on it: DNS/Pi-hole, backups, a log sink (SD
wear), or anything Node.js-shaped"*, and `hosts/two/system/README.md` says nothing
household-critical goes there. A test bot is none of those and breaks no letter of it.
But it is not lifeboat duty either, and two costs are new:

- **~200–330 MB of a 475 MB board while deployed.** Removing docker and containerd buys
  back roughly 34 MB, so the net standing position is better than before — but the peak
  is much higher, and nothing on this box can set a per-container memory limit (rootless
  podman under OpenRC has no cgroup delegation for user slices).
- **Postgres writes continuously to the SD card.** Weaker than it was written, and the
  correction matters because this argument appears in three places. **The board is a
  decade old; the card is not** — confirmed by the owner, 2026-08-21. Every version of
  this bullet, and roadmap §5, said "decade-old SD card" and reasoned from a card that
  had had ten years to wear out. It had not. SD cards still wear, so a continuous
  Postgres write load is still a cost worth watching and the lifeboat still rests on
  that card outliving the boxes it watches — but the wear budget is a replaceable
  fiver's worth of flash of known age, not an unknown remainder. Anything that leaned
  on the stronger version, the diskless switch above included, leans on less than it
  appeared to.

**Settled for now: the bot yields.** If `two`'s lifeboat jobs are built (roadmap §5),
they take precedence and this stack moves or goes. It is a test bot; they are the
fleet's last way in. Recorded now so that when the two collide, it is not re-argued
from scratch under pressure.

Consequence worth keeping in view: it also weakens the case for the planned diskless
switch. A 512 MB board cannot hold its OS image in RAM *and* Postgres's buffers, and an
unsynced diskless system loses the data directory on power loss. Diskless and this stack
are not obviously compatible, and that has not been resolved.

## SSH between hosts: any box can be a jump host; none holds a key to another

> **Amended 2026-08-23.** This section used to read "`two` is a jump host, and that is
> all". All three are now, and the entry below is unchanged in the part that matters:
> **no box holds a key to another.** The two are separate facts and conflating them cost
> an outage — see the box at the end.

**Nothing in this repo runs over SSH between boxes on its own behalf.** Fleet work is
done *on* the box it concerns.

So there is no key on `zero` authorising it to reach `one` or `two`, and none should be
added for convenience. `zero` is the internet-facing box — it runs the tunnel and
Immich — and a key from it to the other two would mean a compromise of the most exposed
host reaches the whole fleet. The lifeboat direction is the safe one: `two` reaches out,
because `two` exposes nothing.

This is why `bin/check-system-drift` and `bin/hw-inventory` both **refuse to operate on
a host you are not standing on**. That is not a limitation to route around with SSH; it
is this decision expressed in code. Each compares repo state against the *local* `/etc`
or reads the *local* `/sys`, so running one "for" another host produces confident
fiction — `hw-inventory --host one` on `zero` would have overwritten `one`'s inventory,
including the record of its failing disk, with `zero`'s hardware.

The cost is real and accepted: facts about `one` and `two` cannot be verified from
`zero`, so anything unconfirmed is marked unverified in the docs rather than guessed —
`one`'s file modes are the current example. (Zram on `zero` was one until the owner's
`/proc/swaps` of 2026-10-26 showed none, only `/dev/sda3`; see *Zram swap on `zero`* below.
`one`'s zram was confirmed by the owner on 2026-10-25: `/dev/zram0`, 768 MB zstd, is its first swap at
priority 16383, holding ~400 MB in ~118 MB of RAM, with `sda2` behind it at −2 and empty.)

### The mesh, and why it does not breach any of the above — 2026-08-23

All three hosts now set `AllowTcpForwarding yes` with `PermitOpen` scoped to exactly the
three fleet addresses on port 22 (`hosts/*/system/sshd-infra.conf`), so a client can
reach any box through either of the others.

**This grants no box access to another.** With `ProxyJump` the *client's* key
authenticates end to end; the intermediate only forwards TCP and never authenticates to
the target. The rule above is about keys, and no key was added anywhere.

It reverses a "don't" written elsewhere, which is why it is recorded rather than merely
done. or3's `dev/README.md` § *"`ProxyJump zero` does not work, and must not be made
to"* argues against enabling forwarding on zero. The objection is about **arbitrary**
forwarding from the internet-facing box; `PermitOpen` makes the reachable set three
addresses the client can already reach directly. That document also concedes the setting
"was never a boundary against an authenticated user", since anyone with a shell can run
`nc` — which is exactly what the fleet did instead, for months, through
`ProxyCommand ssh zero nc %h %p`. **or3's README is now out of date on this point** and
should be amended when that repo is next touched.

`or3-dev` keeps the `nc` form deliberately: it targets `127.0.0.1:2224`, which
`PermitOpen` does not include, so a jump to it is refused. Verified.

> **Why the mesh exists at all.** On 2026-08-23 `two`'s tunnel was stopped while it was
> the only configured route to it. There was no `two-zero`, and — correctly — no key
> from zero or one that reaches it, so the box was unreachable until a `ProxyCommand`
> was assembled by hand mid-incident. The reasoning that left it unreachable was about
> keys; what was missing was a *path*. Those are different things, and the fix for one
> is not the fix for the other.

## One cloudflared build on all three, including the two that are `aarch64`

**All three hosts run the 32-bit `arm` build.** `two` is `armv6l` and needs it; `zero`
and `one` are `aarch64` and could run `arm64`. They do not, on purpose.

**Because the staggered rollout only tests what later hosts will actually run.** Updates
go `one → two → zero`, each stage refusing while an earlier one is unhealthy
(`playbooks/update-cloudflared.yml`). With per-architecture builds, `two` would be the
first and only host ever to run the `arm` binary — so the **lifeboat becomes the canary
for its own architecture**, and `one` being healthy would say nothing about it. Uniform
means every host runs something an earlier host already survived, which is the entire
value of the ordering. It is also one hash per release rather than two.

**Three costs, accepted rather than overlooked:**

- **The AArch32 compat layer is now a dependency.** A 32-bit binary on `aarch64` runs
  through kernel support that arm64 distributions have been drifting away from. If a
  future Alpine or Pi kernel drops it, `zero` and `one` lose cloudflared **at their next
  reboot**, with no warning, on the boxes everything is reached through. This is the
  strongest argument against and it is the one to watch.
- **A single point of failure the other way.** If Cloudflare stops publishing the `arm`
  build, all three break at once rather than one.
- **Performance, unmeasured.** No ARMv8 crypto extensions, so AES is software and QUIC
  leans on ChaCha20. On a Pi 5 the bottleneck is almost certainly the uplink rather than
  the CPU, but nobody has measured it, and "probably fine" is what it is.

**It arrived by accident and is kept by choice**, which is worth separating. Until
2026-08-23 `host-setup.md` documented a per-architecture install using an asset name that
does not exist (`cloudflared-linux-aarch64`), so `curl -L` without `-f` would have written
GitHub's 404 page over the binary. One working copy was evidently distributed to all three
instead. The uniformity was nobody's decision; it is now.

## `zero`'s encrypted volume

**Immich serves by default; a security concern keeps it down.** That veto is the design
— the monitoring exists to let you use it.

Which settles the unlock: **manual passphrase over SSH, every boot. No keyfile, no
tang, nothing automatic.** Anything that unlocks without you is a key at rest on
hardware an attacker may be holding. The payoff is that a reboot *re-locks* the data,
so rebooting into a root shell — the cheapest Pi attack — gets them a locked volume.

**Tang: rejected**, not deferred. It exists to unlock without you; all three Pis share
one column so a same-stack tang protects nothing; and Alpine packages neither `tang`
nor `clevis` on any architecture (checked Aug 2026). Reasoning in
[roadmap.md](roadmap.md#tang--rejected).

**bcache cache mode confirmed `writethrough`** (both devices, 0.0k dirty, Aug 2026), so
the cache SSD holds nothing the backing disks don't. It is a disposable accelerator
today — but that is a *setting*, not a guarantee, and switching to `writeback` would
make it live data. Re-check before trusting it.

## Two things the original inventory got wrong

Recorded because they're easy to repeat:

- **`send2ereader` was always its own compose project**, not part of `ionic` — its
  compose file declared no `name:`, so Compose derived one from the directory. Six
  containers carried `project=ionic`, not seven.
- **esmira and immich-ml weren't "down with no containers"** — each had an *exited*
  container and a registered project. Deleting their compose files alone would have
  orphaned them permanently; they needed a real `compose down`.

## A stack's `cloudflared` belongs in the stack, starting at Phase 3

**Decided 2026-08-24.** `send2ereader` is adopted with its own connector inside its compose
project, rather than being served by `one`'s host tunnel. This pulls Phase 5's mechanism
forward onto the stack Phase 3 was already adopting.

**Because the point is deleting the published port, not moving the connector.**
`bookit.gsrpi.uk` is a rule in `hosts/one/system/cloudflared-config.yml` aimed at
`http://127.0.0.1:3001`, and the compose file publishes `3001:3001` *only* to make that
reachable. A connector on the compose network reaches `send2ereader:3001` directly, so the
rule and the port both go and the service stops listening on the host. A connector moved
without the port deleted would have bought nothing.

**Because this is the cheapest place to get it wrong.** The only precedent is `infra-dev`,
a dev container holding a live agent session — breaking it costs the session that would fix
it. `send2ereader` is disposable, on the non-critical box, and its outage is a book that
arrives later. Phase 5 then converts the dev containers against a pattern that has already
run somewhere else first.

**The shape is deliberately left open.** `infra-dev` runs `cloudflared` from its own
entrypoint, which it can do because that image is ours; an upstream application image is
not, so this wants a second compose service instead. Sidecar versus baked-in is the first
thing Phase 3 settles, and it is a pattern decision for every stack after it.

⚠︎ **Settled 2026-10-24: sidecar**, and not on `send2ereader` — `calibre-web` set the
pattern first. See the next section.

## Sidecar, not baked-in — what a stack's own tunnel is

**Decided 2026-10-24**, building `calibre-web` on `one`, and agreed with the session
planning `garmin-mcp` (§ *garmin-mcp* below; its plan is retired), which builds on
the same pieces.

**A second compose service, because an upstream application image is not ours to build.**
`infra-dev` can start `cloudflared` from its own entrypoint because we own that image;
`lscr.io/linuxserver/calibre-web` is not ours, and a derived image just to add a connector
would put a rebuild between us and every upstream security fix. The sidecar is
`cloudflare/cloudflared`, pinned by tag and digest like any deployed image.

**`calibre-web` first, ahead of `send2ereader`.** The reasoning that picked `send2ereader` —
the cheapest place to be wrong — applies more strongly to a stack that does not exist yet:
nothing to move, no port to delete, no outage at all. `send2ereader` adopts the same pattern
when Phase 3 reaches it; what that phase still owes is the Ansible adoption and the port.

**One tunnel per stack, never the host's.** Two connectors on one tunnel are replicas, and
the edge splits requests between them — so a sidecar holding the host tunnel's credentials
would 404 at random on every rule the two configs do not share.

**Locally-managed, like every tunnel since 2g.** The ingress is
`deployments/<stack>/cloudflared.yml`, tracked; a dashboard token (`TUNNEL_TOKEN`) would
have made it the fleet's one remotely-managed tunnel and the dashboard its routing.

**Credentials outside the checkout, at `~/.<stack>-secrets/tunnel.json`, `65532:65532`
`0600`.** Outside, because the checkout is bind-mounted into `infra-dev`, which by design has
no route to the fleet — gitignored is not enough. `65532` because that is the image's
`USER`; root-owned `0600` is unreadable to it. Same `~/.<name>-secrets` convention as the
dev containers.

**The tunnel id reaches `tunnel run` from `.env`, written by the play.** The image is
distroless — no shell to read the id out of the credentials as `infra-dev`'s entrypoint
does — and `tunnel run` needs it as an argument or a `tunnel:` key. In `.env`, written by the
same run that wrote the credentials, the two cannot name different tunnels; a `tunnel:` key
in the tracked config would be a second copy that could, so the play refuses one. **And it is
written last**, after the probe has proved the login is in front: compose refuses to start
without it, so a run that dies part way leaves a stack that cannot start, never one serving
with nothing in front of it. (The first draft wrote it before the Access step; review caught
that a refused Access write would then leave a startable, unprotected stack.)

**Derived, not declared: the hostname is `<stack>.<dns_zone>`, the host is wherever
`hosts/<host>/<stack>` points from.** `deployments/<stack>/edge.yml` carries only what cannot
be derived — whether there is an Access login, and a path that bypasses it.

**Access is opt-in per stack**, because the clients differ: a browser login for
`calibre-web`; none at all for `garmin-mcp`, whose client (claude.ai's connector) cannot pass
Access and which carries its own OAuth. **Who may log in is a file on the control node**,
`~/.config/cloudflare/access-emails`, not a list here — this repo is public. A **bypass path**
is a second, more specific Access application with a `bypass` policy; Access matches by
prefix and the most specific wins, so the play proves, before the stack is started, that
`/` still asks for a login and the path does not — calibrated first on `torrents`.
**`edge.yml` is the whole truth about the hostname's Access**, and the play only adds: an
application on the hostname that `edge.yml` does not ask for — left after a `bypass_path` was
dropped — stops the run rather than staying live behind a green recap. Each policy is **read
back** after it is written, because the application is PUT whole on every run and whether
that keeps app-scoped policies attached is Cloudflare's behaviour, not ours to assume. One
copy of the application-and-policy code, `_cf-access-app.yml`, imported per application.

**A Cloudflare request-header rule sets `X-Scheme: https` for `calibre-web`**, chosen over
Calibre-Web serving TLS itself behind the sidecar. Calibre-Web learns it is behind HTTPS only
from `X-Scheme` (`cps/reverseproxy.py`, 0.6.27); the edge sends `X-Forwarded-Proto`, so
without the rule the Kobo is handed `http://…:443/kobo/…` and every download fails — found in
review, confirmed in the source, upstream as calibre-web#3595. The rule keeps the app stock
and is the proxy setup Calibre-Web documents; TLS inside the stack would have needed a
self-signed cert and two settings that live only in the app's own database. It is
`request_headers:` in `edge.yml`, and the play adds or patches **only its own rule** (by
`ref`) in the zone's shared `http_request_late_transform` list — never a PUT of the list,
which other hostnames may share. The cost is a sixth API-token permission, Transform Rules.

**`_cf-tunnel.yml` is shared with `_dev-container-tunnel.yml`**, its sections 0–2 moved word
for word. One change reaches the dev containers: an existing credentials file that cannot be
*read* now stops the play, where before it read as absent and would have minted a second
tunnel over the first. A sidecar's root-only file made that case reachable.

**Outside the staggered autoupdate (2h), by design.** The image's entrypoint passes
`--no-autoupdate`, and an in-container update would land in a layer the next recreate
discards. A bump is a commit. Nothing reports a stale sidecar yet — filed in
[`management-plane.md`](management-plane.md).

**No `SOURCE` for a registry stack pinned by digest.** `calibre-web` builds nothing, so there
is no checkout for `bin/check-sources` to compare; the image digest in `compose.yaml` *is*
the record of what is deployed, and git keeps it. The URL-only `SOURCE` shape stays as narrow
as `destiny-director`'s section says — that stack follows a moving tag, which this does not.

**Smaller choices made with it:** `mem_limit` on both services from day one, because `one`
has 1 GB (⚠︎ "no swap" was wrong when written: `one` swaps to 768 MB of zram first and its SSD
partition second, both in `/proc/swaps` on 2026-10-25 — the cap stands, for its own reason); `logging: max-size`, because the bypass path takes unauthenticated
hits; the two new subvolumes in fstab by `subvol=` name rather than id, because they are
made by hand after the commit and their ids are unknown until then. **Ebook conversion was
left out on purpose**: it works on arm64 (linuxserver's docs say otherwise; their build
says not), and if wanted it is a derived image with Calibre's hash-pinned arm64 tarball,
never the `DOCKER_MODS` line, which installs at every container start.

**Amended 2026-10-24 — the stack play pulls the host itself.** It used to compare the
checksums of the stack's three files and, on a mismatch, tell you to ssh in and pull. It now
does what `server-install-system-files.yml` decided on 2026-08-24: `git pull --ff-only` on the
host, refusal of uncommitted changes under `deployments/<stack>/` on either side, and the host's
HEAD required to equal the control node's. The checksum check stays as a second layer. No
deploy needs an ssh first any more; the control node's own `git pull` is still yours.

**Amended 2026-10-25: `send2ereader` moves to a sidecar, and keeps the name `bookit`.**
The owner chose to keep `bookit.gsrpi.uk`, the name typed on e-readers since before the
sidecar and short to type on one, over the derived `send2ereader.gsrpi.uk`. So `edge.yml`
takes an optional `subdomain:`, one DNS label that replaces the deployment's name in its
hostname. The play still appends `dns_zone` and still checks `cloudflared.yml`'s first
rule against the result, so the two files cannot name different hostnames. That check is
what derivation buys, and it holds. The tunnel, the secrets directory and the DNS record's
comment keep the deployment's name. Without `subdomain:` nothing changes for the other
deployments.

The cost is a short outage at cutover. The tunnel play points the existing `bookit` record
at the new tunnel before the sidecar runs. `server-deploy-send2ereader.yml` (since deleted) imports that
play and starts the deployment later in the same run, so the gap is the build and the
start: seconds with `one`'s build cache, minutes without it. A disposable service can take
that, and avoiding it would have meant a second hostname or a tunnel play split around the
DNS write.

⚠︎ **SUPERSEDED the same day by the paragraph after next: `one` builds nothing now.** The
build paragraph is kept because it is why the dry run used to check `SRC_ROOT`.

**The deploy play builds on every run.** The app image has no tag of its own, so Compose's
`build: policy` would keep a stale image after a new sha in `SOURCE`. Docker's layer cache
turns an unchanged source into the same image, so Compose leaves the running container
alone; a new sha rebuilds and recreates it. Its dry run proves `SRC_ROOT` and the source
checkout, the two things a real run needs that the tunnel play does not write, so their
absence shows before the record moves (found in review).

**Amended 2026-10-25, later: the app is the fork's CI-built image, and `one` only pulls it.**
The owner had the fork's CI publish `ghcr.io/gsfernandes81/send2ereader:<full commit>` for
arm64 and amd64, smoke-tested on native runners, so a deploy no longer waits out a build on a
Pi 4. `compose.yaml` names it as a literal, tag and digest, per the repo invariant. **`SOURCE`
is dropped**, as `calibre-web`'s was: the image's tag is the fork commit and its digest is
the record, while a `<url> <sha>` `SOURCE` means *built on the host from a checkout* to
`bin/check-sources`, which would report the missing checkout as drift. The play pulls with
`pull: missing`, right for a digest: unchanged is already there, a new one is missing. Its
dry run now proves what a real run needs that the tunnel play does not write — that `one`
can fetch that digest from ghcr anonymously, so the package must stay public — and a real
run checks the container's image ID equals the pinned reference's.

`edge.yml` says `access: none`: an e-reader's browser is the client, `bookit` had no login
before, and send2ereader's own four-character key, dropped 30 seconds after the reader
stops refreshing it, is what pairs a sender with a reader. The move also ends
`send2ereader`'s published port 3001, which is the reason § *A stack's `cloudflared`
belongs in the stack* gave for doing it.

## garmin-mcp — a Garmin MCP for claude.ai, on `one` (read-only; five writes added, amended below)

**Decided 2026-10-24** with the owner, after a security audit of the upstream and nine
alternatives. It builds on § *Sidecar, not baked-in* above and does not restate it.

**On `one`, with no Access in front.**
- **Not `two`:** an armv6 Pi 1 with about 475 MB, where the Python dependencies have no wheels.
- **Not `zero`:** critical and remote. A third-party, internet-facing service holding a Garmin
  session should fail on the box where a reboot costs nothing.
- **No Access:** its only client is claude.ai's custom connector, which speaks the MCP
  Authorization spec and cannot pass Access.
- **The gate is upstream's OAuth shim.** In-process, 43 of 44 attacks on it held; the one
  that did not is a consent lockout that blocks only *new* connections. So `edge.yml` says
  `access: none`.

**Taxuspt, read-only, over Garmin's Personal API.** The Personal API (launched 2026-10-21) has
the better credential: a key you set the expiry of, revocable, read-only. It lost on coverage
for what the owner does, running and lifting:
- **Strength:** per-exercise totals only, with no individual sets.
- **Missing entirely:** training status, readiness, load and VO₂ max trends, race predictions,
  the personal-record list.

Read-only on Taxuspt is `GARMIN_ENABLED_TOOLS` (its 108 read tools). The deploy proves it
against the live server, not the config. The revisit trigger is filed in management-plane.md.

**Amended 2026-10-24, the same day: five writes, chosen by the owner** — `upload_workout`,
`upload_workouts`, `schedule_workout`, `unschedule_workout`, `set_activity_description`, so
Claude can plan training onto the calendar and annotate sessions. Each is in
`GARMIN_ENABLED_TOOLS` and in the play's `garmin_allowed_writes`, and the probe fails on any
other non-read name. None takes a file path; `set_activity_description` int()s its id before
building the URL, so no path injection. Still nothing that deletes recorded data. A leaked
bearer now also costs junk workouts, calendar changes and overwritten activity notes.

**What a leaked bearer token costs:** read access to health and location history until it is
rotated. Accepted.

**The shim's remaining findings are known and deliberately not reported upstream** (owner,
2026-10-24). The owner may file them if the stack stays in use:
- the global consent lockout;
- no frame protection on the consent page;
- an attacker-chosen client name on that page;
- dependencies resolved fresh at each build — neutralised here by a sha-tagged image built
  only when the tag is absent;
- a 500 from `/register`.

## Data subvolumes are `media-<stack>-<name>`, mounted at `/media/<stack>/<name>`

**Decided 2026-10-24**, the owner's convention, first applied to `calibre-web`
(`media-calibre-library` → `/media/calibre/library`, `media-calibre-config` →
`/media/calibre/config`). It applies to every new data subvolume on an array.

**Because the name carries both facts.** A subvolume listing (`btrfs subvolume list`) then
says what each one holds and where it mounts, with no fstab to cross-read. The four older
subvolumes on `one` are known only by id in fstab (`subvolid=256`…`259`), and what they hold
is answered by the mountpoint beside each id, nowhere else.

**At the array's top level, and in fstab by `subvol=` name.** `subvol=` resolves relative
to the top level whatever the default subvolume is, and a new subvolume's id is unknown
until it is made, by hand, after the commit that adds its fstab line. Creating it needs the
top level mounted, which is what `/mnt`'s `noauto` entry is for; the setup checks
`get-default` says ID 5 first, because `/mnt` mounts the default, not the top level.

**One directory per stack under `/media`.** A stack's mounts sit together, and
`/media/<stack>` is a plain directory on the root filesystem, never a mount and **left
mutable**, so a later subvolume can be added beside the others. The guards go where the
mounts land — `nofail` on each fstab line, `chattr +i` on each `/media/<stack>/<name>` —
and `bin/check-mount-guards` needs no change: it finds every `/media/` entry in fstab at any
depth and reads the bare directories through a non-recursive bind of `/`.

**The four existing mounts are not renamed.** `/media/ionic-mysql`, `/media/torrents`,
`/media/torrents-config` and `/media/syncthing-config` hold live data behind working guards.
Moving them buys a tidier listing at the cost of a stop, an unmount, re-guarding and an fstab
change on a box that is fine; do it only when one of those stacks is being rebuilt anyway.

## Ansible output: one title line per task, as it starts — ON TRIAL

⚠︎ **SUPERSEDED 2026-10-24, the same day, by § "Ansible output: this repo's own callback"
below.** The look stayed; the `diy` templates did not. Kept for why `diy` was tried first.

**Decided 2026-10-24, on trial with the owner.** `ansible.cfg` sets `stdout_callback =
community.general.diy` with templates in its `[callback_diy]` section: a ━━ banner per play,
one ▸ line per task **as it starts** (cut to 56 columns, a phone in portrait) so a long run
shows what is happening, like `docker build --progress=plain`, and under it only changed,
failed, retry and `debug` lines. A plain ok and a skip print nothing, as before.

**Why `diy` and not a live status line.** A line that rewrites itself in place (`docker
compose up`'s view) needs state the templates do not have, and the stock callback that does it,
`community.general.dense`, writes terminal escapes even when its output is not a terminal,
which garbles the pasted transcripts this repo diagnoses from. A small custom callback could do
it safely; it is repo-owned code, so it waits until the scrolling of this one proves a problem.

**What the templates have to rebuild,** because `diy` silences the default callback whenever a
template renders: `display_ok_hosts = False` (an empty render), the DRY RUN marker (on the play
banner), and `debug` messages in full, lists included. Without that last one, the MFA block and
the Done block in `server-deploy-garmin-mcp.yml` (since deleted) would print as a bare "changed".

**The escape hatch** is `ANSIBLE_STDOUT_CALLBACK=default` for one run: a full transcript, or
`-v`, which the templates ignore. **The known cost:** `diy` calls template APIs that
ansible-core 2.23 removes (management-plane.md has the item), and prints two deprecation lines
per run until community.general updates it.

## Ansible output: this repo's own callback

**Decided 2026-10-24 by the owner**, after trying `community.general.diy`.
`ansible/callback_plugins/infra.py` is the stdout callback (`ansible.cfg`). It keeps the
look above and adds what `diy`'s templates could not do:

- **The terminal's real width,** measured on every line, with long lines wrapped under their
  own indent (the owner's ask was Helix's soft-wrap) and nothing cut off with "…".
- **A timer ticking at the end of the running step's title,** with the final time left there.
- **No trace of a skipped step.** On a terminal its title is drawn, then erased once every host
  has skipped it; in a log the title is printed only with a first result.

**Why our own code, against "prefer the interface an outsider already knows".** Each of those
three needs state between events, and `diy` renders one template per event with none. The
stock live-progress callback, `community.general.dense`, writes terminal escapes into logs and
pasted transcripts. roots/ansible-output-prettify was the model for measuring the terminal and
timing steps, but it prints nothing until a step ends, and it has no licence, so nothing was
copied from it. The plugin is about 250 lines and uses only `CallbackBase`. Leaving `diy` also
removed its two deprecation lines per run and the ansible-core 2.23 risk filed for it. The
plugin itself reads results through `TaskResult.result`/`.task`/`.host`, falling back to the
underscored names older cores have, because those underscored names are deprecated for
removal in 2.23.

**Workers are forked, and the timer thread holds a lock.** A Fable review found, and a test
reproduced, that a fork taken while the timer held it left the child with a lock nobody could
release, so the child's first output hung the run. A forked child now drops the lock and the
redraw logic (its output is proxied to the controller anyway). The same review restored what
the first version dropped from failures (a command's stdout, a module failure's
`module_stdout`, the exception), printed `debug: var:` values and loop diffs, and stopped
redraws across a terminal resize, where counting lines back up would land on the wrong ones.

**What makes redrawing safe.** The plugin redraws or erases only while its own title is the
last thing on screen. It wraps `Display.display`, which every other line Ansible prints goes
through (warnings, deprecations, errors, prompts, and worker output proxied to the main
process), and that wrapper commits the title with a newline first. So a redraw can never land
on top of anything else. A test run had a real warning appear while a title was live; it
printed below the committed title and stayed. On anything that is not a terminal the plugin
writes plain, append-only lines.

**The escape hatch is unchanged:** `ANSIBLE_STDOUT_CALLBACK=default` for one run.

**Restyled after prettify the same day (owner):** one line per task with gray dots out to a
right-aligned time and status word, prettify's symbols (`✓ ~ ✗ → ⚠ ●`), ANSI colours, status
words, `PLAY [name]` header, `Error:` lines, per-host recap and closing line. Every status word
starts in one column, the furthest right it can: the longest word is seven letters, so an
unreachable host is `DOWN`, and the terminal's last column stays empty so a redraw never meets
an early line wrap. Long lines wrap as Helix soft-wraps (the line's indent kept, marked `↪`).
Kept from before, against prettify: the running step's `● … RUNNING` line with its timer,
skipped steps not shown, nothing truncated, and a closing line that says when the run failed.
Ansible's own exception block (an `[ERROR]` with a source excerpt) now prints only with `-v`:
the cause is already in the step's `Error:` and output lines.

## The fleet inventory commits itself, and asks before it pushes

**Decided 2026-10-25 (owner).** A full run of `server-generate-fleet-inventory.yml` whose
report changed commits `docs/fleet-inventory.md` with a message the play writes:
`fleet inventory: regenerated 2026-10-25 14:02 UTC, changed on one, two`. Then it shows the
commit and asks `Push this commit to origin/main? [y/N]`.

**Because a hand-written message added nothing, and a hand commit could carry the wrong
report.** The host list in the message comes from comparing each host's section of the
committed report with the new one, with the `Generated` line ignored. A report that differs
only in its timestamp is not committed at all.

**The guard runs before anything is written**, right after facts are gathered. It fetches
`origin`, then refuses unless this checkout is exactly `origin/main` (no commits ahead or
behind) and the report has no edits beyond its `Generated` line. A play that commits on its
own must not stack a commit on top of work nobody has pushed, and it must not commit over a
hand edit. It refuses rather than pulling: a pull from inside a playbook would move a
checkout the owner may be working in. The timestamp an unchanged run leaves behind is not
an edit, so the next run is not refused over it.

**What it will not do.** A partial run never commits, and neither does `--check`. Partial
means a host left out by `-l`, or one that did not answer: a down host would otherwise be
committed as a section saying UNREACHABLE, over its last real one. The template already said
a partial report must not go over a full one. The commit holds the report and nothing else
(`git commit -- <path>`), after a scan for the CLAUDE.md secret names. The default is to ask
before pushing, because `main` is what the hosts pull. `-e push=true` skips the question,
for a future scheduled run. `-e push=false` commits and stops. `-e commit=false` only writes
the file, as before. A run that commits nothing says why.

## The fleet's ssh hostnames are gated by per-client service tokens

**Decided 2026-10-25 (owner),** after an outside probe found `ssh-zero`, `ssh-one` and
`ssh-two` with no Access in front: a WebSocket upgrade with no credentials reached sshd's
banner on all three, so sshd's keys-only settings were the only gate
([infra#12](https://github.com/gsfernandes81/infra/issues/12)). The plays are
`server-create-fleet-ssh-access.yml` and the fleet halves of `client-home-ssh-config.yml`.
A Fable review of the plan shaped the parts marked below. **Rolled out the same day** by
the owner to all three hosts and both clients; an outside probe with no credentials then
got 403 from all three, where that morning it had reached sshd.

**Service tokens, one per client, over a browser login.** A browser login's session
expires, and an expired one broke `ssh zero` from the phone on 2026-08-23 with
`websocket: bad handshake`. The dev containers already run per-client service tokens
(`<container>-<client>`), so the fleet gets `fleet-<client>` from the same client play. A
lost laptop is one token to disable: a token a policy lists cannot be deleted, and the
server play leaves disabled tokens out (review).

**The tokens never expire (review).** Cloudflare's default lifetime is one year, and the
dev containers' tokens were minted with it (and, until 2026-10-25, the dev play still did:
it now mints `forever` too, with the same read-back, the existing ones having been set by
hand). A fleet token minted that way would shut every
client out of every Pi on the same day, a year later, with the August symptom. So the
client play mints with `duration: forever` and reads the token back before writing the
file, and the server play refuses to admit any fleet token that expires. A token reported
as leaked is disabled by Cloudflare itself, which this does not change.

**Clients first, then the gate.** The dev containers' order, an application with no
policy that each client then joins, would admit nobody between the two steps, which on
the fleet means no way into any Pi. Presenting a token to a hostname with no gate changes
nothing, so every client starts presenting its token first, and the server play admits
every `fleet-*` token that exists and stops for a yes on the list.

**One reusable policy, one application per host (review).** `fleet ssh service tokens` is
linked from `fleet ssh zero`, `fleet ssh one` and `fleet ssh two`, each created already
linked, so no application exists admitting nobody, a client's token is added once, and
undoing one host is deleting its application without touching the other two. One
application on three hostnames was the first draft; rolling it back would have meant
editing an object that was already gating a live host.

**Probes that cannot pass for the wrong reason (review).** The ssh probe runs first
against the open host, so a probe that cannot pass from this client (a key behind a
passphrase) stops the run before anything is written. After the write the play waits
until the hostname refuses an unauthenticated request, because Access changes take time
to reach the edge, and only then runs the ssh probe again, with `-S none`, so an open
multiplexed connection cannot answer for Cloudflare. Any failure after the application
exists deletes it. The play can prove only its own client's token, so the laptop checks
itself before the next host is gated.

**The fleet ProxyCommand falls back; the dev containers' does not.** Without a whole token
the fleet script warns and connects without one, so a client that has not caught up still
reaches a host that is not gated yet, and on a gated one the warning names the fix. The
dev containers' ProxyCommand stops instead, because their applications have only ever
admitted tokens.

**Not covered:** `KbdInteractiveAuthentication` is still on in `sshd-infra.conf`; turning
it off is a change to sshd itself, for the two-phase procedure, and is not chosen.

## Pinned images are bumped by a pull request, from Dependabot

⚠︎ **SUPERSEDED 2026-10-25 by the next section: Renovate, not Dependabot.** Kept because the
reasoning for a proposing bot, and the registry-prefix lesson, still stand.

A stale sidecar `cloudflared` is invisible to the hosts' autoupdate, and the fix is a bot
that proposes: Dependabot opens a PR bumping `tag@sha256:` in a deployment's
`compose.yaml`, the owner merges, and deploys as with any bump. Dependabot and not a
workflow because its config, `.github/dependabot.yml`, is not a workflow file, which the
agent's `gh` token (no `workflow` scope) can push, and the repo is public, so it costs
nothing and holds no secret. The bot is scoped to deployments whose images are already
digest-pinned; `send2ereader`'s app image, `garmin-mcp`'s local build and Immich's images
are ignored (the reasons are in the file). Floating tags are to be pinned to the digest
each box runs, then tracked the same way; if Dependabot does not move a digest alone, a
workflow for exactly those images is the fallback. Renovate is the fallback if it cannot
parse our compose files (it can). **A dependency name has no registry prefix** in
`ignore:`; the first run proved it by proposing a major Postgres bump that the ignore was
written to stop.

## Renovate replaces Dependabot, and Immich's compose file becomes an override

Dependabot's first run showed what it could not do. It moves a tag and a digest, and
nothing else: no release notes in the PR, no way to hold a Postgres tag on its major
version, no way to take two images as one version except per-directory groups. Renovate
does all of those from `renovate.json`, which, like `dependabot.yml`, is not a workflow
file and so can be pushed from here. The hosted Mend app is installed by the owner on the
repo; until it is, nothing proposes bumps. Installed 2026-10-25, owner-reported.

**Neither bot sees Immich change the shape of its compose file** (a new service, a renamed
variable), and Immich has done that before. So `deployments/immich/compose.yaml` is now
Immich's release file *unmodified*, `compose.override.yaml` beside it holds the changes
that are ours, and Compose merges the two with no command change. Taking a release is
replacing one file with the release's own and reading a plain diff, with nothing to merge
and no workflow to maintain. A merge workflow was designed and set aside for this.
Renovate is switched off for the vendored file, because its postgres and valkey lines
follow the release, and runs on the override, where the server and machine-learning
images are pinned once the owner has read the digests off the box.

**What the override holds, measured with Compose 5.6.1 on 2026-10-25:** the memory and CPU
limits. The `:?` guards on the two data paths are *not* in it: upstream's own
`${UPLOAD_LOCATION}:/data` already stops Compose when the variable is unset (`invalid
spec: :/data: empty section between colons`), so the guard's purpose holds without our
line and only the message is worse. That rests on how Compose parses short volume syntax,
so it was tested for both variables, with and without the override, before the guard lines
were dropped. The rendered `config` differs from the previous file in exactly the lines
Immich's release changed: the postgres digest, an empty `healthcheck` on the database
and valkey's digest and health test.

**`infra-dev` carries the docker CLI and the Compose plugin to make that comparison**, and
no daemon (`dev/Dockerfile`): the point is `docker compose config`, which CLAUDE.md asks
for before any compose change and which the container could not run. `DOCKER_HOST` points
at a path that does not exist, so a command needing a daemon fails with a message.

## garmin-mcp stays built on `one`, and nothing watches its upstream

Considered 2026-10-25 and set aside, the owner's call: building the image on GitHub CI, and
a check that says when upstream has moved. `garmin-mcp` is the one deployment still built
on a box, from `SOURCE`'s sha, and a bump is a deliberate review of two upstreams and the
tool allowlist, which no bot can do for you. A CI build would remove the Pi's build and pin
the Python dependencies by digest, at the cost of a two-commit bump (the digest exists only
after CI has run) and a workflow file pushed by someone with the `workflow` scope; a
notifier would only say "upstream moved". Neither was worth it for one deployment that
changes rarely. The way back is the `send2ereader` shape: CI publishes to ghcr, compose pins
`tag@digest`, and Renovate then covers the image like the rest.

## One redeploy play for the plain compose deployments, asking once per deployment

`server-deploy-compose.yml -e deployment=<name>|all`. One play and not one per deployment,
because immich, syncthing, torrents and calibre-web need nothing beyond `docker compose up`,
and `garmin-mcp` and `send2ereader` had plays for their tunnels, `.env` and probes. What
made those two different was small: a pre-check and a set of probes. So the play takes
**hook files** per deployment (`ansible/deploy-hooks/<name>/preflight.yml`, `probe.yml`),
read `${VAR:?}` names out of `compose.yaml` to check `.env` instead of keeping lists by hand,
and leaves tunnel provisioning to `server-bring-up-deployment.yml`, because the tunnel play
PUTs Access policies unconditionally and a routine image bump must not touch Cloudflare.
As of 2026-10-25 `send2ereader` is on it and `garmin-mcp`'s play is still its own
(a plan, since done and deleted); `garmin-mcp` joined later that day, in the row
*garmin-mcp joins the redeploy play*, and both old plays were deleted on 2026-10-26. The question is per **deployment**, never per container:
gluetun and qBittorrent share a network namespace and must be recreated together, and
Immich's four containers are one application, so a per-container question invites answering
"no" to half a pair. `all` is the owner's addition: it goes through every deployment in turn,
`one` before `zero`, each with its own plan and its own question, stops at the first failure,
and refuses `assume_yes`, so the question that keeps each prompt meaningful cannot be switched
off for the lot. The plan is Compose's own dry run, printed before anything changes; the
result is read from container ids before and after. Written 2026-10-25 from `infra-dev`,
which has no route to a box; the module's `actions` output is printed defensively, and the
plan paths were then run on `one` and `zero` the same day.

## The pull-and-verify step is two shared files

The step that makes a host run the reviewed commit was written out three times:
`server-install-system-files.yml` (2026-08-24), the tunnel play, and the redeploy play.
It is now `ansible/playbooks/_review-anchor.yml` (the control node's commit and a check that
what is about to be delivered is committed) and `_sync-host-checkout.yml` (pull the host's
checkout fast-forward only, then require it clean and on exactly that commit), imported
by all three. A new play that delivers the repo to a host imports them, and does not copy
the tasks. The design is unchanged and so are its messages; each caller names its own paths
and its own closing sentence. The tunnel play keeps its extra checksum comparison of the
files it will run, which is specific to it. Checked from `infra-dev`: every play
syntax-checks, and the two files run clean and fail correctly against this checkout.

## calibre-web's kepubify is a symlink the deploy play makes, in a directory

Found 2026-10-25 at bring-up. The image ships kepubify as `/usr/bin/kepubify`, and its
first-run script writes that path into Calibre-Web's database, but saving the settings page
runs Calibre-Web 0.6.27's own check (`cps/binary_helper.py`), which accepts a file only if its
real name is `kepubify-linux-64bit` or `-32bit`, and fails with *Kepubify binary not found*. A
directory is searched for those names without the real-name test, so the setting is the
directory `/config/kepubify`, holding a symlink of the right name to the image's binary. The
link is made by `ansible/deploy-hooks/calibre-web/prepare.yml` after the question is answered
and before `up`, not by an image script: LinuxServer's custom-script directory wants
root-owned executable files, and this checkout is owned by the uid the container runs as, so
whether it would run was not something to find out at bring-up. The deployment's probe runs
the binary through the link and checks both memory limits are in force, which the README used
to ask a person to check by hand. The hook is the first `prepare.yml`: a hook point after the
yes and before `up`, so nothing is written for a change that was declined. Remove it if a
later Calibre-Web accepts a binary named `kepubify`.

## garmin-mcp joins the redeploy play, which changes in three ways to take it

Decided 2026-10-25. `server-deploy-garmin-mcp.yml` became three hooks in
`ansible/deploy-hooks/garmin-mcp/`, and `server-deploy-compose.yml` needed three changes for them.

**`pull: policy`, never `pull: missing`.** Compose applies any `--pull` to every service and
overrides each one's `pull_policy` (compose v5.6.1, `cmd/compose/create.go`). So `missing` would
have made `garmin-mcp` look for its tag on Docker Hub before building it, and a same-named image
published there would have won over the reviewed source. Refusing that is why its
`pull_policy: never` exists. No other deployment sets a `pull_policy`, so they get Compose's
default, which is `missing`, as before.

**A preflight hook may create what is missing, and it runs before the `.env` check.** Compose
cannot plan a first bring-up of `garmin-mcp` without the four `.env` lines it generates and
without its build context. The hook writes each of them only when it is absent, and never under
`--check`. Values that change on purpose, a rotated consent secret or a new upstream sha, are
written by `prepare.yml` after the yes. So on a routine redeploy the plan you answer is still the
whole change.

**`-e recreate=true`, for one named deployment, refused with `all`.** Probes run only after a
redeploy. The old play probed on every run, and its README relied on that twice: a re-run
finished the first Garmin login, and a restart then a re-run caught a lapsed one. A recreate
gives both cases a redeploy to probe after. It also lets any deployment's probe be exercised with
nothing changed, which is what deleting the two old plays waits for.

The Garmin login moved to the end of the probe, where the play prints the login block and
pauses until it has been run. `tools/list` answers without a login, because upstream registers
its tools at start-up and logs in on a background thread, so the allowlist is proved first,
even on a first bring-up.

**The two old plays were deleted on 2026-10-26**, after the owner's runs of this path:
`garmin-mcp`'s `--check` planned nothing to change, and each deployment's `recreate=true` run
recreated both its containers and passed every probe, the Garmin login included.

## `ionic-traces` comes off `hosts/one/`; its deployment stays

**Decided 2026-10-25**, the owner's call. `hosts/<host>/` says where a deployment runs, and
`ionic-traces` has not run anywhere since it was stopped by decision in 2c. A link saying it
runs on `one` was a statement the fleet contradicts, and the reason the redeploy play needed
an exclusion for it. **Only the link goes.** `deployments/ionic-traces/` stays, because the
deployment is not gone from `one`: its three exited containers, its compose project `ionic`
and the data on `/media/ionic-mysql` are all still there ("Exited" is not "absent", CLAUDE.md
§ Landmines), and a teardown or a repair needs the compose file. The redeploy play keeps its
exclusion as a second lock, and `fstab` keeps the mount, behind its guards.

## Immich to v3.3.5, with machine learning's v2 models

**Decided 2026-10-25**, the owner's call, for memory on `zero`. **Deployed by 2026-10-26**
through the redeploy play (`docker ps` on `zero` names v3.3.5 for both images), after a database dump off the array (its own
hook, the next section), because the
server migrates the database on its first v3.3.5 start and there is no way back but that
dump. `compose.yaml` was already v3.3.5's release file, and its postgres and valkey lines are
what `zero` runs, so the change is the two app images in the override and one variable.

**Measured here, on x86 CPU, with Immich's default models** (ViT-B-32 for search, buffalo_l
for faces) loaded and called repeatedly, memory read from the processes themselves:

| machine learning | idle | models loaded | peak during calls |
|---|---|---|---|
| v3.0.1 (`zero` today) | ~250 MB | ~1.19 GB own | ~1.5 GB own, ~1.6 GB in all |
| v3.3.5, v1 models | ~235 MB | ~270 MB own + ~770 MB mapped files | ~520 MB own, ~1.3 GB in all |
| v3.3.5, v2 models | ~235 MB | ~266 MB own + ~770 MB mapped files | ~506 MB own, ~1.3 GB in all |

**The saving is v3.3 itself**: it maps model files from disk instead of copying them into the
process, and those pages are clean, so under pressure the kernel drops and re-reads them
rather than swapping. v2 against v1 differed by little on x86; it is set anyway because the
release notes say the improvements reach every backend and many depend on the new exports,
the arm64 build is the one that matters and was not measured, and it becomes the default in
a later release. Its outputs are numerically equivalent, so no job is re-run. **Idle is
unchanged**: both versions end the worker after `MACHINE_LEARNING_MODEL_TTL` (300 s) without
a request and come back with nothing loaded, which is the ~250 MB `zero` showed. Read
cgroup-wide, v3.3.5 looked far smaller still; that was an artefact, the model files' page
cache having been charged to an earlier container, and the per-process figures above
replace it.

**Release notes read, v3.0.1 to v3.3.5:** no change to the database or Valkey images, the
compose file or any variable. Behaviour changes worth knowing: v3.1.0 drops iOS 14 and syncs
an OIDC role claim to `isAdmin` on later logins; v3.3.0 syncs quota, role and username
claims on every login; new thumbnail settings reach existing assets only if thumbnail
generation is re-run for all. v3.2.0's notes were read only in part.

**`MALLOC_ARENA_MAX` was considered for the server and dropped, 2026-10-26.** It caps
glibc's per-thread memory pools, a known fix for Node processes that hold memory after
image work, but v3.3.5's `server/bin/start.sh` preloads mimalloc, so glibc's allocator is
not the one in use and the setting would do nothing.

**Job concurrency is left in the web UI.** The config file Immich offers replaces every
setting saved from the UI — the code reads the file *instead of* the database, and a key the
file omits falls back to Immich's default — and makes the settings page read-only. If it is
ever wanted in git, the way is the API (`GET`, then `PUT /api/system-config` with only the
concurrency changed, an admin key scoped to system config), which applies live.

## Immich redeploys dump the database first, off the array

**Decided 2026-10-25**, the owner's suggestion when the v3.3.5 deploy was handed over with a
dump to paste first. The dump is now `ansible/deploy-hooks/immich/prepare.yml`, so it cannot
be forgotten, and [`docs/recovery.md`](recovery.md) § *Immich's database* says where it goes.

- **A prepare hook, not preflight.** Preflight runs before the question and under `--check`,
  so it would dump on every plan and every "no". Prepare runs only after you answer y, before
  `up`, which is the moment the old database is still the old one.
- **Every confirmed redeploy, not only a version change.** It costs about a minute and
  141 MB (the first, 2026-10-25). Deciding from the plan which change can touch the database is a guess, and a
  wrong guess is the one case the dump exists for.
- **`/var/backups/immich` on the SD card, 0700, newest three kept.** Off the array is the
  point: Immich's nightly dump is on the array it would be needed for. Three, the owner's
  number, because the SD card also held `/var/lib/docker` (until 2026-10-26, when it moved to `sda2`); the hook refuses to start with
  less free than 2 GiB or twice the largest dump kept. The dump just taken is never ranked
  for deletion, so a control node whose clock is behind cannot rotate it away.
- **It refuses rather than guesses**: no dump if `immich_postgres` is not running, and a dump
  whose last line is not pg_dumpall's "dump complete" stays a `.partial` and stops the run.
  Both stop before `up`. `-e immich_dump=false` is for the one case a dump cannot be taken: a
  redeploy that is itself what brings the database back.
- **No standalone dump play.** The manual block in `recovery.md` covers the invasive work
  that is not a redeploy; a play for it can be added if that comes up more than once.

## The redeploy play pulls missing images before its plan

**Decided 2026-10-25**, after the first `--check` of an image bump (Immich v3.3.5) failed at
the plan with "No such image". Compose's dry run fakes the pull and then asks the real daemon
about the image when it plans the recreate (v5.6.1, `pkg/dryrun/dryrunclient.go`), so it
cannot plan any image the host lacks. Every bump would have failed the same way.

- **A real run pulls when anything is missing, before the question.** `compose pull`
  refreshes every pullable image, so those already present get a registry check and no
  download. It touches no container, and a
  "no" leaves only images on the host, which `up` would have pulled anyway. The plan you then
  answer is Compose's own, as before.
- **Through `compose pull` with no `--policy`.** `--policy` overrides every service's
  `pull_policy`, as `up --pull` does, so it would send garmin-mcp's locally built tag to Docker
  Hub. `--ignore-buildable` leaves an image with a `build:` section to `up`.
- **`--check` pulls nothing.** `pull --dry-run` asks the registry for each reference, so a
  digest that does not exist still fails there, and the plan names the missing images instead
  of Compose's container list. An image only `up` can build is planned the same way in a real
  run.
- **One image at a time, detached.** The first real pull, Immich's two images at once, put
  `zero`'s load at 11.2 and dropped the run's ssh session. `COMPOSE_PARALLEL_LIMIT=1` and
  `async` answer that from the play; the daemon's own download limit is filed in
  [`management-plane.md`](management-plane.md), as a host file rather than a play setting.

## Zram swap on `zero`

**Decided 2026-10-26**, the owner's ask, after `free` showed 1.1 GB available with 660 MB
already swapped to the SSD. **Installed 2026-10-26**: `hosts/zero/system/zram-swap`, read back from
`/proc/swaps` (`/dev/zram0`, 2 GiB, priority 100, `[zstd]`); its place in the default runlevel
is owner-reported.

- **Ahead of the SSD, not instead of it.** zram at priority 100 takes swapped pages first,
  compressed in RAM; `/dev/sda3` at −2 stays behind it as the overflow, so a full or failed
  zram costs nothing that is there today.
- **2 GiB of capacity, zstd.** The size is what it can hold uncompressed, and RAM is taken
  only as pages arrive. `one`'s zram holds ~400 MB in ~118 MB, about 3.4:1, so a full 2 GiB
  typically takes ~600 MB, and up to the full 2 GiB if the pages do not compress. Half of RAM
  is the default of Fedora and systemd's zram-generator; `one` runs 768 MB on 1 GB. The
  first draft said 1 GiB, and the owner questioned it before install: `zero` already had
  624 to 660 MB on the SSD, which 1 GiB would have held with little room for a peak. The
  size is revisited from `/sys/block/zram0/mm_stat` and `/proc/swaps` after a few days.
- **An OpenRC service, not an `/etc/local.d` script**, so `rc-status` shows it, `rc-service
  zram-swap stop` removes it, and `install-system-file` checks its syntax. `before docker`,
  so it stops after the containers, and it skips the swapoff at shutdown or reboot, where
  bringing every page back is wasted work. A failed start leaves the SSD swap as it was.
- **No sysctl change with it.** `vm.swappiness` and `vm.page-cluster` are often tuned with
  zram. They are global and would change how the SSD swap behaves too, so they wait until
  zram alone has been measured.

## Dev containers: one compose file in `infra`, one memory pool, `claude-sessions` only in a hub

**Decided 2026-10-25**, the owner's three calls on [`plans/dev-pool.md`](../plans/dev-pool.md).
**Built 2026-10-26 on a branch and not yet on the fleet** (*The hub, as built* below). Until
the owner brings it up, every row it marks ⚠︎ above still describes the boxes.

- **One compose file in `infra` for every dev container**, the hub and the sidecar, so
  starting, stopping and limiting them is one place. This reverses *Claude dev containers
  stay in their own app repos*, knowingly: `make dev` from a fresh app clone stops being
  the way in. The child repos keep their own Dockerfiles; the compose file builds them from
  ~~an absolute checkout path in its `.env`, never `..` (Repo invariants)~~ — ⚠︎SUPERSEDED
  2026-10-27: from each repo's GitHub URL (*The hub, as built*, below).
- **cgroup v2, set up as Alpine recommends**, is what `zero` runs, on the owner's word; the
  pool file is written for v2 and its first step confirms it on the box.
- **`claude-sessions` runs only in the hub**, which manages every other container over ssh:
  the menu, attaching, stopping, and the offloader, which keeps its rule (measured activity,
  ten quiet minutes, a keep-alive holds) and measures each container's slots remotely. The
  owner is its only consumer, so it is rewritten for that rather than kept general. What a
  dev container must still provide for the hub to read — its slots, their activity, a
  keep-alive a claude can set, Claude Code's hooks and status line — is the hub mode's design,
  settled in the claude-sessions repo.

**The hub's key reaches every dev container, and that is accepted**: the hub is behind
public-key auth and a Cloudflare Access login, and an ssh login on `zero` already reaches
every container (an attacker there waits for the next `sudo`). The rule that comes with it:
the key lives only in the hub, which runs no agent, and is never mounted into a dev
container.

### The hub, as built (2026-10-26)

The owner's request that day: "All dev containers move into one compose. One claude sessions
door container runs cloudflared and claude sessions door … manages all the other containers'
claude sessions via ssh including offload. Still one container per repo but favour just using
gh to clone the repo to a volume and maybe another volume for .env … Your call on that." Then,
during the build: a sidecar for cloudflared is fine, the alias is `ssh dev`, and the menu's
shape (below). claude-sessions' side is its `docs/design.md` § *The hub*, released as 0.5.0.

- **claude-sessions still RUNS in every dev container; it is only pinned in the hub.** The
  offloader's measurement reads `/proc` and the socket-diagnostics netlink, which answer only
  inside a container's own namespaces, and a slot's lock is a `flock` in the container's own
  registry — so a hub reading containers from outside would have had to re-implement both
  over ssh, worse. What moved is the menu and the timer. The binary reaches the containers by
  the hub's start running `claude-sessions install /opt/claude-sessions` into a volume every
  container mounts **read-only**: one pin, in `dev/hub/Dockerfile`, the same bytes on both
  ends of every ssh call, and a release reaches every container at the hub's next start with
  no base or child bump. The 2026-10-25 wording "`claude-sessions` runs only in a hub" is
  read as *the menu and the offloader run only in the hub*.
- **The hooks drop-in is the volume's `managed-settings.d` subpath, mounted over
  `/etc/claude-code/managed-settings.d`**, not a symlink into the volume: Claude Code then
  reads a plain directory of plain files, and nothing depends on how it treats a link.
  Read-only, so no claude can rewrite the hooks every claude runs. Every container
  `depends_on` the hub being healthy — the install done — because a subpath that does not
  exist cannot be mounted at all.
- **The hub's key is made in the hub's own volume at first start and never leaves it**; only
  its public half is published in the shared volume, and each container's entrypoint
  authorises it as `restrict,pty` — commands and a terminal, no forwarding, no agent. The
  hub learns each container's host key on first contact (`accept-new`) over the compose
  network nothing else joins, and pins it in its volume; a changed key still refuses.
- **cloudflared is a sidecar** with one hostname, `dev.<dns_zone>`, the owner allowing either
  and Phase 3 having settled sidecars for deployments. It runs as the checkout's owner rather
  than the image's 65532, so the dev-container edge play's credentials (gavin, 0600) serve it
  unchanged, and it is behind a `tunnel` profile so the rest comes up before the tunnel
  exists. The dev containers lose their own tunnels and their per-container hostnames; the
  break-glass path is the one that never needed a tunnel, `make shell C=<c>` on zero.
- **Except or3-dev's hostname, which moves onto the hub's tunnel instead of going** (owner,
  2026-10-27: "the only concern I have is or3-tunnel"). The phone's `or3-tunnel` holds `ssh -N
  -R 2236:10.1.0.236:22 or3-dev-sh`, the only route to the vessel LAN, and the forward has to
  land inside or3-dev (or3's `docs/dev-tunnel.md`). A second ingress rule, and the CNAME
  re-pointed by `-e via_hub=true` at move-in, keep the phone's alias, its Access token and
  or3's tool exactly as they are. **Not a jump through the hub**: `ssh -J dev or3-dev` would
  need the hub's sshd to forward, on the one machine holding a key to every container, and
  would change or3's tool and the phone's config. The bytes over the metered link are the
  same either way.
- **The alias is `dev`** (owner), through the existing dev-container edge and client plays
  with `-e container=dev`, so the tunnel, the Access application and each client's service
  token are made the way every container's always were.
- **Each workspace is a volume, cloned once from `DEV_REPO`** (⚠︎SUPERSEDED IN PART 2026-10-27:
  the clone is over https with the hub's token, the only GitHub path — see *The hub's App is
  the only GitHub credential* below) — with `gh repo clone` when gh
  is logged in (the owner's preference), else over ssh with the deploy key, so a first start
  does not wait on `make login`; `make login` clones when neither worked. It ends the shared
  working tree with the host: zero's `~gavin/infra` is only what the box runs, and the
  2026-10-25 divergence (a container commit left behind in the host checkout) cannot recur.
  ~~**or3-dev keeps its bind mount**, which is or3's design and its call (plans/dev-pool.md).~~
  ⚠︎SUPERSEDED 2026-10-27 by *No workspace is a bind mount*, below.
- **One cutover for all four, not one container at a time** (owner, 2026-10-27: "Could we
  simplify to one big bang cutover?"). What made the staged order necessary was each child
  repo changing first; none has to. Every child Dockerfile already takes `BASE_TAG` as a
  build arg, so `dev/compose.yaml` builds each on the new base from its own clone, and each
  repo drops its compose file afterwards. ~~**dd-dev and ds-dev keep their bind-mounted
  clones too**, as their repos had them: their `.dev-ssh/` keys and dd's `.env` live there,
  and moving to a volume mid-cutover would be a migration nobody asked for.~~ ⚠︎SUPERSEDED the
  same day by the next bullet. **dd-dev brings its
  `dd-postgres` sidecar**, aliased `postgres` on the network because that is the host its
  `DATABASE_URL` names. **The two stop mounting zero's `~gavin/.ssh`**: their drop-in served
  the host account's authorized_keys for a published port that is gone, and blanking it
  (`dev/child-authorized-keys.conf`) leaves the hub's key as the way in and gavin's private
  keys out of both containers. dd-dev and ds-dev stay stopped at rest, as they were, by
  profile. ⚠︎SUPERSEDED IN PART 2026-10-27: every container starts by default now (*Every dev container starts by default*, below). The old volume names come from the 2026-10-25 fleet inventory — the guesses made
  the day before were wrong for both (`dd-dev_*` for `destiny-director_*`, `ds-dev_*` for
  `dossier_*`), which is what the artefact-wins rule is for.
- **No workspace is a bind mount: all four clone into volumes** (owner, 2026-10-27: "Could we
  remove support for bind mounted clones and switch entirely to clones in volumes?"). This
  ends or3's shared working tree, the trade management-plane.md said should be made
  knowingly in or3 — the owner made it. ~~Each host clone on zero stays, as the build
  context only.~~ ⚠︎SUPERSEDED the same day: each child builds from its repo on GitHub
  (`main`) — or3 over ssh with its existing deploy key, dd and ds over https — so no clone on
  zero is read by anything, and none can build a stale Dockerfile because nobody pulled it. What a clone held that git does not — dd's `.env`, dd's and ds's `.dev-ssh/` — moves
  into an env volume and a secrets directory at the cutover; uncommitted work, stashes,
  worktrees and ignored directories are listed first and stay behind on the host, untouched.
  dd's compose-level `env_file` is dropped rather than pointed at a host file: dd reads its
  `.env` itself, and a host path would be secrets outside their volume again.
- **The hub holds one GitHub App key and mints each container an hourly token for its own repo
  only** (owner, 2026-10-27: "bonus points if claude sessions door can hold a GitHub token …
  restricted to that repo only"). **An App, because nothing else can be restricted to one repo
  and minted by a program**: a classic token or a gh login spans every repo the account can
  reach; a fine-grained PAT can be scoped to one repo but only made by hand in a browser, one
  per container and per expiry; an App's installation token takes a `repositories` list at
  mint time. The cost is authorship — PRs and issues from a container appear as the App's bot,
  commits are still authored by the owner. **The key lives only in the hub**, as its ssh key
  does, and widens nothing: the hub already reaches every container. **Delivered by volume,
  not ssh**: each container mounts its own subpath of a tokens volume read-only, so a
  container reads only its own token and gets it before its first clone (the hub's healthcheck
  waits on the first pass, bounded, so GitHub being down delays nothing past a minute). The
  broker checks GitHub's answer names exactly that one repo and writes nothing otherwise.
  **Off by default**, with every container's own gh login and deploy key as before: the App is
  the owner's to make (dev/README.md). ⚠︎SUPERSEDED 2026-10-27: required, and the only path —
  the next bullet. Built in Python's standard library plus `openssl`, in
  infra's hub image and not in claude-sessions, whose zero-dependency build has no TLS.
- **The hub's App is the only GitHub credential in any dev container** (owner, 2026-10-27,
  on the design review: three paths — deploy key with an https-to-ssh rewrite, a gh login,
  the token — where one does the job). Deploy keys, their generation in the host play, the
  `gh repo deploy-key add` step, the rewrite and the gh/ssh clone branches are gone, about 300
  lines; every origin is https. The cost, accepted: the App is made before the cutover, and a
  hub down for over an hour stops pushes until it is back. or3's deploy key stays, for
  BuildKit's fetch of its private repo only. infra-dev's host play had nothing left but a
  directory, so it is one play with the hub's (`_dev-host.yml`), and the dev-container play
  takes only `dev` and `or3-dev` (via the hub) — no other container has a tunnel to make.
- **The pool reclaims from 2048M (memory.high) before its 2560M kill line** (owner,
  2026-10-27, on the design review's point that cgroup memory limits do not limit IO): the
  soft limit makes idle sessions give memory back early and gradually, into zram first, so the
  6G of swap is reached only by a runaway rather than by the pool filling and swapping at once
  beside Immich's SSD.
- **Every dev container is 2048m of RAM and about 4G of swap, the same for all** (owner,
  2026-10-28: "for the sake of standardisation and can be challenged in the future").
  `memswap_limit: 6144m`, set once in the shared `x-dev` block of `dev/compose.yaml`, and no
  child sets its own. infra's `DEV_MEM_LIMIT` and `DEV_MEMSWAP_LIMIT` are gone with it, so a
  value left in zero's `dev/.env` cannot quietly override the standard. This lowers infra,
  or3 and destiny-director from 2560m and raises the other five from 1536m. The pool keeps
  its own numbers. One container now reaches the pool's 2048M soft line but not its 2560M kill
  line, and cannot fill the 6G of swap alone. A container that needs more is argued here.
- **The pool is 2560M of RAM and 6G of swap** (owner, 2026-10-27: "allow 6G of swap so both
  zram and normal swap can be utilized"), and ~~**each container's swap cap is its RAM plus
  those 6G**, so the pool, not a container, says how much dev work may swap~~ ⚠︎SUPERSEDED
  2026-10-28 for the per-container part: each container's swap is 4G (the row above); the
  pool's 6G still bounds them together. Before this the
  containers' own `memswap_limit`s allowed 256–512 MB each, which would have left the pool's
  swap unreachable. The cost until the pool is installed: a container may swap up to 6G on
  its own (4G since 2026-10-28). **dd-postgres is in the pool too** — it is dev work's memory. ~~**infra-dev's own
  limit rises from 1024m to 2560m**, or3-dev's figure (owner: "quite restrictive for work")~~
  ⚠︎SUPERSEDED 2026-10-28 by 2048m for every dev container (above). The pool, not each
  container, is what keeps the total off Immich.
- **The dev project is a deployment of server-deploy-compose.yml** (owner, 2026-10-27, on the
  design review: `make up` could recreate every container, and every claude in them, with no
  preview). `deployments/dev` is a link to `dev/` and `hosts/zero/dev` places it, so it gets
  that play's dry-run plan, its y/N, its before/after container-id comparison and its hooks: a
  preflight that builds every image before anything is touched — the cutover's riskiest step,
  or3's private build, fails with the old layout still running — and then refuses while old
  projects hold the names; a probe that the hub reaches each container. This reverses "the
  lifecycle is dev/Makefile's" for the guarded path; `make up` stays as the unguarded break
  glass. For compose to run without make, the base tag moved into compose.yaml
  (`x-base-tag`) and the checkout owner's uid/gid into `.env`. The smoke test checks that
  changing one container's settings recreates only that container, the hub included.
- **A smoke test brings the project up in CI** (owner, 2026-10-27), because most of what
  could break at the cutover — mounts, keys, the door, the token path — was untested anywhere
  but on zero. GitHub's runner, not zero: infra is public, so its minutes are free, and a
  failed run there costs nothing on the fleet. It builds an unreleased claude-sessions from
  source by replacing the hub image's `fetch` stage with a named build context, so the
  Dockerfile zero builds is the one tested, with one stage swapped. Writing it found the
  Makefile passing `BASE_TAG` to Compose empty since the tag moved there (`:=` before the
  variable was set), which only worked because compose.yaml's fallback was kept in step. Each child builds
  from its repo on GitHub (`main`), so no clone on zero is read by anything.
- **One offload switch, one container list, one way in per door** (design review, 2026-10-27;
  owner: do it before the cutover). `HUB_OFFLOAD` in the hub is the only offload switch: the
  per-container `DEV_IDLE_OFFLOAD`/`CLAUDE_SESSIONS_OFFLOAD` pair said the same thing a second
  time in each container, and a container that disagreed with the hub was offloaded anyway by
  the hub's pass. The hub's container list is derived from its `HUB_REPO_*` lines
  (`github-tokens hosts`), not written again as `HUB_HOSTS`, so a container cannot be in the
  token list and missing from the menu. infra-dev's `extra_hosts` entry for `zero` went too:
  it was kept for a fleet key no container holds, by decision. And the clients keep two doors, `dev` and `or3-dev`: infra-dev's, dd-dev's and
  ds-dev's blocks are removed by `_client-retired-dev-ssh.yml` (a `state: absent` per marker
  ever used, per the rename rule), and `server-add-authorized-keys.yml` writes the hub's and
  or3-dev's authorized_keys — the only two sshds a client reaches — instead of infra-dev's.
- **The hub's `claude-sessions` on PATH is a wrapper that derives the container list**
  (2026-10-27, found by the extended smoke test): the derived list lived only in the
  entrypoint's environment and ssh logins, so `docker exec dev-hub claude-sessions` — `make
  claude`, `make idle` — fell back to `local` and showed the hub itself, where nothing runs. A
  wrapper rather than the list back in compose.yaml, which would be the second copy the
  derivation exists to avoid; rather than a file the binary reads, which claude-sessions
  dropped the same day for the same reason.
- **The base carries a language server only where Claude is likely to use it** (owner,
  2026-10-27, asked whether Claude needs a Markdown one): marksman went, as it serves an
  editor's link completion and nothing an agent reads Markdown for — and it needed .NET's
  invariant-mode switch to start at all, which the smoke test found.
- **Claude Code's code intelligence is on in every container, for Python only, through ty**
  (owner, 2026-10-27: "drop pyright in favour of ty and ruff"). A local marketplace baked at
  `/opt/claude-plugins`, enabled by managed settings, so it needs no network and cannot
  auto-update. ty and not pyright: lighter (Rust, against a Node process that indexes the whole
  repo) on a pool every session shares, and the type checker the repos already use. ty and not
  ruff as the server, because Claude Code gives each extension one server, and ty's diagnostics
  and navigation are what an agent cannot get by running a command; ruff stays that command.
  No plugin for the other languages: they have no official one, and no repo here is mostly
  them. The server is the repo's own ty where it has one (owner: "allow the use of local / venv
  ty"), through `dev/ty-lsp`, so diagnostics match the version and imports the repo checks with.
- **A fresh workspace volume that holds only the image's copies of the repo's files is cloned
  into** (2026-10-27, found by running the smoke test's dd-dev step locally). dd's and ds's
  images COPY `pyproject.toml` and `uv.lock` into `/workspace` to bake their dependencies, and
  Docker copies those into a new named volume on its first mount, so the entrypoint's "holds
  files but no checkout" refusal fired on every first start and dd-dev and ds-dev would have
  come up with no clone. Not `nocopy` on the mount: that leaves the volume root's, which dev
  cannot write. The entrypoint clones beside the files and adopts the clone only when every file
  there is one the repo tracks, keeping any that differ in `~/.workspace-pre-clone`.
- **A repo's untracked secrets live in a second volume, `~/.env.d`, symlinked into the
  workspace** (`DEV_ENV_FILES`). Not hard links: two volumes are two mounts and `link(2)`
  refuses across mounts. A regular file found where a link should be — an editor that saves by
  rename — is reported and left, being the newest copy; each link goes into the checkout's
  `.git/info/exclude`, so it is never committed whatever `.gitignore` says.
- **The menu is containers first** (owner: "the highest part of the hierarchy is the
  container, followed by loaded / offloaded / archived one level deeper"), and inside one
  **Loaded, Offloaded and a folded Archived** holding everything closed, with a session
  waiting for the owner **marked by an amber `!`** rather than grouped (owner: "make needs
  you just a yellow highlight or icon … keep loaded / offloaded and a click to expand archived
  section"). claude-sessions' mockups 1 to 15 were redrawn for it.
- **The base drops claude-sessions and cloudflared**, keeping the two mountpoints, and the
  per-container offload loop, tunnel and menu door go with them; `DEV_TUNNEL_HOSTNAME` and
  `DEV_IDLE_OFFLOAD` leave the containers (the latter survives in `dev/.env` as what compose
  turns into `CLAUDE_SESSIONS_OFFLOAD=0`). Base `2026.10.26`. ⚠︎SUPERSEDED IN PART 2026-10-27:
  `DEV_IDLE_OFFLOAD` is gone too — see *One offload switch* below.
- **`dev/.env` now serves the whole project, so the plays write it by line**, starting one
  from `.env.example` when there is none; `_dev-container-host.yml` used to write it whole,
  which would now wipe the hub's lines. Every container's paths are required from the start:
  Compose refuses a required variable even in a service whose profile is off (measured,
  Compose 5.6.1); the profile is what keeps a container from starting. ⚠︎SUPERSEDED IN PART 2026-10-27: every container starts by default now (*Every dev container starts by default*, below).
- **The pool is opt-in until its boot file exists**: `cgroup_parent: ${DEV_CGROUP_PARENT:-}`,
  which Compose drops when empty (measured). `:-` and not `:?`, because absence here is the
  supported state, not a mistake to stop on.
- **The dev containers mount the hub's volumes `nocopy`; the hub's own mount copies** (zero,
  2026-10-27). Docker copies an image's mountpoint, ownership included, into an empty volume at
  every container *create*, and Compose creates every container before it starts any, so on a
  whole-project `up` infra-dev's and or3-dev's root-owned mountpoints were copied over the
  hub's still-empty `claude-sessions` volume after the hub's dev-owned one, and the hub could
  not install into it. With `nocopy` on the dev side only the hub's mountpoint decides. This is
  the opposite of the workspace call above for the opposite reason: a workspace has one
  mounter, so `nocopy` there would leave it root's; a hub volume has the hub as well. The smoke
  test now creates a dev container beside the hub before the hub starts, which is the
  mechanism (the copy happens per create), and checks the owner.
- **The deploy play refuses a host whose Compose is older than 5.5.0** (zero, 2026-10-27).
  `one` and `zero` run Docker's containerd image store, where a rebuild moves a tag and the
  daemon drops the image record a running container was made from; it does this even for an
  identical rebuild, because the provenance attestation makes every build a new index digest.
  Compose before 5.5.0 then fails `compose images` for the whole project (docker/compose#14014),
  and `docker_compose_v2` runs it after every plan, so the deploy stopped with "No such image"
  and named an image nothing in the repo refers to. Compose 5.5.0 and later reads the
  container's own record instead, and labels containers by per-platform manifest digest, so
  identical rebuilds no longer churn recreates either; provenance is therefore left on. A floor
  rather than `state: latest` in the package play, which stays install-only: the guard names
  the one command, `apk add -u docker-cli-compose`, which restarts nothing.
- **dev's Compose runs with `BUILDX_BAKE_ENTITLEMENTS_FS=0`** (owner, 2026-10-27). Compose
  builds through `buildx bake`, which from buildx 0.38 refuses to read a file outside its working
  directory unless granted; Compose 5.6.1 grants its build contexts but not a build's `ssh:` key,
  and or3-dev's deploy key is in `OR3_SECRETS`, outside the checkout on purpose, so its build
  failed "additional privileges requested" on zero after the upgrade. The check exists for a
  bake file nobody reviewed, and this one is written by Compose from `compose.yaml`. Rejected:
  moving the key under `dev/` (a secret in the checkout's tree), making the secrets directory a
  named build context (or3's Dockerfile could then `COPY` the key into a layer), and an
  `ssh-agent` per build (machinery the podman move would not need). Set in `dev/Makefile`'s
  `COMPOSE`, which `make build` and `make up` use; the deploy play's own `up` builds nothing,
  because `make build` ran first.
- **The dev containers share one Claude login, on an undocumented setting, behind one switch**
  (owner, 2026-10-27): `CLAUDE_UNDOCUMENTED_SHARED_LOGINS`, `true` or `false`, its value the
  default written into `dev/compose.yaml` (`:-true`). In `compose.yaml` and not `.env` (owner, the
  same day): it is how the fleet behaves, not a host value or a secret, so it belongs where git
  records when it flipped and the deploy play applies it; a `.env` line is invisible to the repo
  and to a rebuilt host. Compose has no variables of its own, so the value is a default, and
  `make check` refuses a `.env` that sets it (the Makefile's `sudo env` already drops the shell's),
  so a default can never be overridden unseen.
  Wanted: one login for every container *with* Remote Control. A `setup-token` token is the only
  documented shareable login and makes model requests only, so no Remote Control and no
  claude.ai connectors; copying a full login is what failed on or3-dev (the copies refresh on
  their own, the refresh token rotates, and all but one are logged out). Claude Code 2.1.311's
  code reads its login file and takes its refresh lock in `CLAUDE_SECURESTORAGE_CONFIG_DIR`,
  undocumented; after the lock it re-reads the file and uses another process's refresh rather
  than refreshing again; and the lock's owner record carries the PID namespace, so a holder in
  another container is never taken over as dead. **Proved, not inferred**, with that Claude Code
  in four containers against a stand-in `platform.claude.com` that rotates refresh tokens and
  refuses an old one, calibrated first: four *copies* of a login gave one refresh and three
  logged out, as on or3-dev; one *shared* directory gave one refresh and four logged in, four
  runs out of four, three with a slow refresh. A holder killed mid-refresh cost its peers that
  one request ("retry in a minute") and no login; the stale lock cleared inside 90 seconds. Not
  proved here: a real Remote Control session, and a long-running session picking up a refresh
  made elsewhere (the code watches the file's mtime for it). **Reversible by design**: both
  directories are mounted always, `false` being each container's own `*-claude` volume mounted a
  second time, so the switch is one value, a commit and a redeploy, and nothing is deleted either way.
  `make verify`'s `login dir` line asks for the login once as configured and once pointed at an
  empty directory, so the day an update drops the variable it reads NOT HONOURED (calibrated by
  passing a name Claude does not read). A logout in one container is a logout in all, and one
  credential is reachable from every container, as with the token it was weighed against.
- **invective, nibbles and ionic-traces join as dev containers** (owner, 2026-10-27):
  `invective-dev`, `nibbles-dev` and `ionic-dev`, each from its own repo's `Dockerfile.dev` and
  resting stopped behind its profile, the shape ds-dev has. ⚠︎SUPERSEDED IN PART 2026-10-27: every container starts by default now (*Every dev container starts by default*, below). No secrets mount, since none
  carries an ssh identity and the base reads only what it finds there; login and history
  volumes external from the start, so `make down-volumes` can never take a conversation
  history, at the cost of one `make volumes` before the first `up`. No dev database for
  ionic-dev until one is wanted: its production one is on `one` and stopped by decision.
- **Every dev container is named for its repo, with nothing appended** (owner, 2026-10-27):
  `infra`, `or3`, `destiny-director`, `dossier`, `invective`, `nibbles`, `ionic-traces`, where
  they were `infra-dev`, `or3-dev`, `dd-dev`, `ds-dev` and so on. The service, container,
  hostname, profile, token directory and `HUB_REPO_<NAME>` all change together, because the hub
  derives its list from those variables and the menu should read as the list of repos. **What
  keeps its old name, and why:** the volumes (a volume name is where a login and a history
  live, and Compose cannot rename one); the host secrets directories (paths on zero, written
  by plays and or3's seed script); and `or3-dev.gsrpi.uk` with the phone's `or3-dev` alias
  (Cloudflare's and the clients', a change of their own). Only `cloudflared.yml`'s target
  follows the container. Images are renamed with their containers. Two guards came with it,
  because the rename has two silent failures: Compose ignores a `COMPOSE_PROFILES` entry no
  service has, so zero's `.env` would have started no `or3`; and neither `up` nor the deploy
  play removes a container whose service left the file, so `infra-dev` would have run on
  beside `infra` on the same volumes. `make check` refuses the first, `make check-names` the
  second. Comments in the base image's files still say `infra-dev`: editing them would force a
  base bump and a rebuild of every image for prose, so they wait for the next real bump.
- **claude-sessions gets a dev container of its own, and stays its own repo** (owner,
  2026-10-27): `claude-sessions`, from that repo's `Dockerfile.dev` (claude-sessions#16, the
  base and a pinned Rust 1.99.1), resting stopped like the others. It replaces the checkout and
  toolchain kept in `infra`'s `~/.local/share` since 2026-10-01, which go once it has run the
  tests. Merging the repo into infra was weighed, since infra is its only consumer, and
  declined: infra is config and no source, its `main` is what the fleet runs while the
  release-and-pin step is the gate that held Stage B on claude-sessions#9, and the two repos'
  licences differ (AGPL-3.0 and none). What a merge would save is the pin handoff, and that
  could be cut without one: a release workflow there opening infra's pin PR was suggested, not
  decided. ⚠︎SUPERSEDED IN PART 2026-10-27: every container starts by default now (*Every dev container starts by default*, below).
- **Every dev container starts by default** (owner, 2026-10-27): the repo containers and
  `dd-postgres` have no profile, so `make up`, the deploy and a plain `docker compose up`
  start them all; `make stop C=<name>` stops one until the next. Only the tunnel keeps its
  profile, because a box or a CI runner without its credentials must still come up. Profiles
  had kept destiny-director and dossier stopped at rest, for memory: zero has 4 GB, and
  destiny-director's container was recorded idling at ~1.4 GB. The owner's condition was
  that no container start anything heavy at boot, and none does: every public child's
  `child-init.sh` (destiny-director, dossier, invective, nibbles, ionic-traces, read
  2026-10-27; claude-sessions has none) syncs its venv or clones and returns, and
  destiny-director's bots start only by hand, `make devbot-up`. or3 is private and was
  not read, but it already ran at rest. That is now the rule for a container added later
  (dev/README.md § *A container added later*). It is a rule, not a mechanism: nothing in
  the base stops a `child-init.sh` from starting a daemon, and the pool
  (plans/dev-pool.md) is what caps them all together. `make check` still refuses a
  `COMPOSE_PROFILES` name no service has, so an old `.env` naming `or3` is refused rather
  than read as a switch that does nothing.
- **Every dev container is always on the newest base, and moving it is infra's alone**
  (owner, 2026-10-28): a base change is a bump of `x-base-tag` in `dev/compose.yaml` and the
  recreate play (`server-deploy-compose.yml -e deployment=dev -e recreate=true -K`), nothing
  further. That already held by construction: every service passes `x-base-tag` as
  `BASE_TAG` (checked 2026-10-28: all eight, and the six public children's `FROM` reads
  `${BASE_TAG}`; or3's is private and was not read), and 2026.10.26 was the newest tag on
  ghcr. What changed is the rule, not the mechanism: a child's `ARG BASE_TAG` default is a
  fallback for a build by hand and never needs moving, so the handoff's and the base
  workflow's "move each child's tag when that repo is ready" are gone. `Dockerfile.base`'s own
  header still says it; editing it would force a base bump for prose, so it waits for the next
  real one. With it, `make build`, which the play's preflight runs (async, as the pull is) and
  `make up` runs first, builds one image at a time: Compose alone builds them all at once, which after a base bump is nine concurrent
  builds on a 4 GB box running Immich.
- **The claude-sessions container reuses its repo's CI layer cache, not its CI image**
  (owner, 2026-10-28, who asked that repo's agent to build the image in CI so zero stops
  compiling cargo-mutants). Its `dev-image` workflow pushes `claude-sessions-dev:sha-<commit>`
  built on that repo's own `BASE_TAG` default, and suggests pinning it as the service's
  `image:`. Not taken: a pinned prebuilt image stays on the base it was built against, so a
  base bump would need that repo to move first, against the row above. Instead the service
  keeps its `build:` from GitHub with `x-base-tag` and lists the workflow's per-architecture
  registry caches in `cache_from`. Where the two bases match, every layer is a pull; where
  they do not, nothing after `FROM` matches and zero compiles, slower and still correct.
  The package is public, as the base's is: ghcr linked it to the public repo at its first
  push (checked 2026-10-28, anonymous pulls of both cache tags).

## Agent mail: the hub carries messages between dev containers

**Decided 2026-10-28**, the owner's calls over the two sessions of 2026-10-27/28; **nothing
built** — [`docs/handoff/2026-10-28-agent-mail.md`](handoff/2026-10-28-agent-mail.md) is the
build list and the split with claude-sessions.

- **Files carried by the hub, not GitHub issues and not ssh between containers.** Issues are
  slow, unwatched for follow-ups, verbose and public; direct ssh is a mesh of keys. A sender
  writes `/workspace/.mail/out/<to>/`, the hub's loop pulls it over the ssh it already has,
  stamps the sender from the container it read, stores `mail/<to>/<from>/<stamp>.md` in a hub
  volume as the record, and pushes into the receiver's `/workspace/.mail/in/<from>/`. **No
  container gains a credential**, which the earlier push design (a per-container key into
  the hub) would have ended. The sender's outbox copy is deleted; the volume is the one record.
- **The policy is a managed `CLAUDE.md`, which no repo can exclude, root-owned in a volume
  a one-shot service writes.** Claude Code 2.1.311 has a fourth memory type, *Managed*, read as
  `CLAUDE.md` from the managed-settings directory the base already owns (`/etc/claude-code`,
  hard-coded); `claudeMdExcludes` cannot drop it and `managed-only` mode keeps it. It follows
  a symlink there — but a file the session's own uid could have written, or with one such
  directory above it, loads *unverified*, under a banner that it may not be policy, and the
  hub's volume is uid 1001 throughout. So a `policy` service runs as root once per `up` and
  installs the tracked text root-owned into its own volume, mounted read-only inside
  `/etc/claude-code`, and the base bakes the symlink. Chosen over baking the file itself
  because an edit is then a hub rebuild, not a base bump and a recreate of every session,
  ~~open sessions re-read the managed folder on a timer~~ (⚠︎ measured untrue, next row), and
  there is one copy rather than one per base tag. Read from the binary in the `infra` container
  on 2026-10-28, not run; the handoff carries the verification, calibration run first.
- **Measured 2026-10-28 in a cloud sandbox, Claude Code 2.1.311 (gate also off in 2.1.312):
  the unverified check is off, an edit reaches new sessions only, and a dangling link is
  harmless.** A non-root user's `claude` was run against a local fake API and its requests
  captured. An owner-writable managed file, a writable directory above a root-owned one,
  and a root session all loaded with the same header, `Contents of /etc/claude-code/CLAUDE.md
  (organization-managed policy instructions):`, and no banner. That held across five
  entrypoints and with the fleet's managed settings installed. The root-owned design
  **stays**: it costs nothing, and the gate may turn on, possibly per organization, which a
  run with no account cannot rule out. An open session got the *first* edit once, as a
  "changed on disk" note at its next turn, and no later edit in 10 minutes. So *open
  sessions pick a change up* is not a reason for the volume; the other two reasons are, and
  they still hold. Results in full: the agent-mail handoff, item 2, *Results*.
- **Every message gets a reply, an acknowledgement sufficing; requests for work are always
  permitted and judged on their merits**, under the receiver's own repo process, vigilant
  against an attack from another repo but never refusing as a blanket policy (owner). A
  message never starts a privileged handover; a fleet-change request is a finding.
- **Inbox and outbox under `/workspace/.mail`**, in the workspace volume, so they survive a
  recreate; kept out of every commit by the base entrypoint ensuring `.mail/` in the clone's
  `.git/info/exclude`, so no repo's `.gitignore` changes and no agent has to remember.
- ~~**The skills (`mail-send`, `mail-read`, `mail-reply`) are infra's**~~ ⚠︎SUPERSEDED 2026-10-29:
  they move to claude-sessions with v2, because they say when to run tools that repo owns and
  must move with its flags; infra keeps the policy. Shipped through the hub
  volume like the keepalive skill; the loop, the hook, the read cursor, idle notification and
  the owner's view of traffic are claude-sessions', the last deferred to an open issue there.
- ~~**No HTTP API on the hub.** It would be a second door on the dev network with its own auth,
  or trust in a bridge address, weaker than the ssh identity the hub already holds.~~ ⚠︎SUPERSEDED
  2026-10-29 by *Agent mail v2*, below: the per-container token the hub already delivers is the
  auth, and the sprawl of the files design outweighed the listener.
- **The hub side is claude-sessions 0.8.0, pinned 2026-10-28**, the day it was released: its
  `mail-loop` runs in the hub, supervised and health-checked like the token loop, the `mail`
  volume is the hub's alone, and the limits are the release's defaults as `HUB_MAIL_*` lines in
  compose, so a change is one visible line. The `.mail/` exclude is the base entrypoint's and so
  a base bump (`2026.10.28`). The hub went to zero the same day and a round trip was proved.
- **Pinned claude-sessions 0.8.1 the hour it was released (2026-10-28)**, on the mail from
  that repo's agent announcing it, verified against the release's `SHA256SUMS`: a slot renamed
  with `/rename` now shows its new name at the hub within one agent poll. Agent-side only, so
  no change to the wire, the registry, the drop-in or compose; it reaches every container when
  the hub is rebuilt and recreated. On zero the same afternoon, by the deploy play's full run,
  which also carried the policy volume and base `2026.10.28.1` to every container.
- **The deploy play knows a one-shot by the dependency that waits on it (2026-10-28).** Both
  of that rollout's runs ended `FAILED` on `dev-policy Exited (0)` after a successful `up`,
  and the second had planned only `dev-policy: Starting` and asked. So `files/compose-oneshots.py`,
  run on the host, prints every service some other service `depends_on` with
  `condition: service_completed_successfully`, from `docker compose config` (merge keys resolved,
  the project name as Compose uses it; names only leave it). In `_deploy-compose-one.yml` those
  may read `Exited (0)` in the all-up check, but only with a `FinishedAt` that moved across the
  `up`, so a one-shot `up` left untouched is still "did not run"; and their `Starting` alone is not
  a change. In `server-stop-deployments.yml` a start leaves them exited, since `compose start`
  would run one again and the check would fail on its exit. Keyed on that declaration and not on
  `restart: "no"`, which every dev container carries too, and one of those exiting is exactly
  what the check is for. The dev probe never ran on either rollout run; the next dev deploy is
  the first with this in it.
- **The policy text is `dev/hub/managed-CLAUDE.md`, installed by a one-shot `policy` service,
  and the skills are `dev/hub/skills/`** (2026-10-28, base `2026.10.28.1`). In `hub/` because
  that is the hub image's build context, and the hub is what carries both to the fleet: the
  service runs that image as root for one `install` into the `policy` volume and exits, the
  only root process in the project; the skills go into the shared volume beside keepalive and
  the base entrypoint copies a fixed list of four into each container's config dir, removing
  one the hub stops shipping. The base bakes the symlink and the empty mountpoint, nothing
  else, so the text changes with a hub rebuild. The sandbox test (handoff item 2, *Results*)
  found the unverified gate off in 2.1.311 and a dangling link harmless; the root-owned chain
  is kept because it costs nothing and the gate reads organization state the sandbox had none of.

## Agent mail v2: a mail server in the hub, sessions as addresses, tools instead of files

**Decided 2026-10-29** by the owner over two sessions with infra's agent; **briefed to
claude-sessions by mail the same day, nothing built**. The brief is the contract; this row is
the why. Supersedes the two struck bullets in *Agent mail* above; the rest of that section
(files carried by the hub, the managed policy, root-owned via the one-shot) stands.

- **Why v1 goes.** The files design worked but had grown one small piece in each of a dozen
  places — an exclude line in the base, a `.mail` tree in every workspace, a cursor per reader,
  a directory file, hooks that knew all of them — and it had no per-session identity, so
  several sessions in one container shared an inbox and the duplicate-action problem wanted a
  claims scheme. The owner refused that as complexity retrofitted onto a simple system. One
  centralised piece instead: a mail server in the hub.
- **Auth is the token the hub already delivers.** The earlier "second door" objection assumed a
  new credential class; the per-container GitHub token mount is already a hub-minted secret in
  every container, and a `mail-token` beside it (same directory, `/run/github`, until a base
  bump renames the mount) grants only the mail API. The slot is self-declared from
  `CLAUDE_SESSIONS_SLOT` and validated by the hub against the registry it already reads; one
  repo's slots are one trust domain. Every request authenticated from day one, because the
  owner intends Cloudflare Access in front later for owner mail, as a second layer.
- **A session's address is its slot**, `repo/claude-2`, which already survives offload and dies
  on close; `repo/*` is every live session of a repo, `*` every live session on the hub, a bare
  `repo` is `repo/*`. **Offloaded is refused** at send time; **offline queues with a warning**
  to the sender. From is generated and validated, never typed. Headers are RFC-822 shape. A
  reply is wanted for one address and not for fan-out unless asked. 60 messages per half hour
  per slot.
- **Tools, not hoops**: `mail who/send/list/read/reply/wait/status` as subcommands of the
  binary every container already runs from the hub's volume, so a hub rebuild updates them
  fleet-wide with no container restart. `mail wait` holds a keepalive and is how an agent gets
  an answer in the same turn.
- **Notification**: hooks on start, prompt and Stop (block once per unread message), a
  fixed-prefix nudge typed into an idle DETACHED slot and tagged by the hook as the hub's, no
  status-line count (owner), no PostToolUse. Claude Code's own daemon messaging would be
  better and is off on this fleet by the agent-view setting, a memory decision; the nudge is
  one function so it can be swapped.
- **Hooks fail fast** — under a second, silently — because they run on every prompt on the
  fleet and the hub being down must never stall them.
- **Skills move to claude-sessions**; infra's base symlinks `~/.claude/skills/<name>` at the
  volume's copy instead of copying, so wording lands without restarts. Infra keeps the policy.
- **Owner mail is deferred** (the owner has a remote-use detail to add); when it comes it is
  high priority and outside the agent-mail policy, so the server leaves room for a From only
  it can produce.
- **The mail-token sits beside the GitHub token, in the same per-container directory and
  mount** (settled by mail with claude-sessions' agent, 2026-10-29): `HUB_MAIL_TOKENS` is set
  to `HUB_GITHUB_TOKENS`'s value, so one read-only subpath mount at `/run/github` carries both
  and the two cannot drift; `github-tokens dirs` makes and removes the directory, the server
  mints into it. 0644, because the mount is the separation, not the mode. The mount's name
  stops fitting and is renamed at a later base bump, not this one.
- **hub-health probes the server, not a beat**: `GET /who` on `127.0.0.1` without a token,
  any HTTP answer meaning alive (401 the expected one), in python because the hub image is
  python's and carries no curl.

## The lesson worth keeping


**A check that can pass for the wrong reason is worse than no check**, because it stops
you looking. The port-forward check originally asked only "did the port change" and
passed on qBittorrent's own default within seconds. See
[port-forwarding.md](port-forwarding.md#3-the-port-changed-does-not-mean-it-worked).
