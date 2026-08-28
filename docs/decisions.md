# Decisions

Settled. The reasoning is here so it doesn't get re-derived — argue with the reason,
not from scratch.

Rows marked ⚠︎SUPERSEDED describe the `dd-ctl` / `root-setup.sh` era on `two`. See the
boxed note in "`two` also runs a test bot" below for what replaced them and why.

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
| Target OS is **openSUSE MicroOS** | Immutable root with btrfs snapshots and auto-rollback on a failed boot — the right shape for a box you can't reach for months. Official Pi 5 support. |
| `two` leaves the fleet, but is **kept as the lifeboat** | Its armv6 was the *only* thing forcing a Debian fleet, so it doesn't migrate. It stays powered on for serial console, power-cycling, and watchdog duty — the things that help when a critical box won't boot. Stays on Alpine. *Diskless was written here as settled and is not:* `two` is a `sys` install today, and now has a Postgres data directory arguing against the switch — see "`two` also runs a test bot" below. |
| `chattr +i` on bare mountpoints, not a guard service | Makes the bad write **impossible** rather than detected, with no boot-path code. The guard service that was drafted instead added a new way for the box to come up with no containers, and had a false-failure mode: renaming a Syncthing share would have silently stopped Docker on the next reboot. |
| Claude dev containers stay in their own app repos | They are developer tooling, not host services. Pulling them into `deployments/` would break `make dev` from a fresh app clone, invert the dependency, and — decisively — still leave both `Dockerfile.dev` files duplicated. It relocates the duplication instead of removing it. |
| `containerd` service removed, package kept | `dockerd` spawns its own containerd; every moby shim uses `/var/run/docker/containerd/containerd.sock`, so the standalone service owned zero shims. But `docker-engine` **hard-depends on the package** — `apk del containerd` would kill every container at the next start. Service-level removal only. **On `one` and `zero`.** On `two` the package goes too, in one transaction with every dependent — see below; the rule was always "never *alone*", not "never". |
| OpenCloud and k3s deleted, not migrated | Both confirmed unused. k3s was still *running* a live cluster (traefik, coredns, metrics-server) and holding ~880 MB of swap; removing it plus the dead `nextcloud` subvolume returned ~344 GiB to the array. |
| **Docker and containerd removed from `two`; rootless podman instead** | Two daemons and their shims cost roughly 34 MB RSS on a board with ~475 MB total, and `two` ran no docker containers worth the price. Rootless podman is daemonless — nothing is resident when nothing is running — and it needs no `docker` group, which this repo already refuses to grant. It is also where `one` and `zero` are headed under MicroOS, so `two` is the cheap place to learn it. |
| **No new user, no boot autostart on `two`** ⚠︎SUPERSEDED | Rootless podman's isolation comes from the user namespace, not from which unprivileged uid owns it, so a second service account buys nothing over `gavin`. **That reasoning was incomplete and the entry is re-stated below** — a dedicated account also buys a `/bin/sh` login shell and an empty home, which is the only thing that takes the ambient login shell out of the deploy key's TCB. Still not done; see "The forced command runs inside `gavin`'s login shell". And a test bot that resurrects itself at 03:00 and takes 200 MB of a 475 MB lifeboat is the wrong default: `restart: always` covers a crashed container, and a reboot deliberately leaves the box running nothing until someone deploys. |
| **`bin/compose` stays docker-only and refuses `destiny-director` by name** ⚠︎SUPERSEDED | Making it runtime-aware would not have helped: that stack cannot be driven from `bin/compose` on *any* host, because its compose file interpolates two variables only `dd-ctl` supplies. And `docker compose` and `podman-compose` are not interchangeable — different project-directory semantics that agree here by coincidence. A wrapper hiding that will eventually hide a difference that matters. The conversion belongs to the MicroOS move, where there are stacks to test it against. |
| **`dd-ctl` has exactly one copy, and it is not in `bin/`** ⚠︎SUPERSEDED | It drives one stack, so it lives beside that stack; `bin/` is for fleet-wide tools, and the README points at it from there. No symlink to it anywhere: a script reachable two ways is a script whose behaviour can depend on which way you came. It carries no `infra-` header either, because `_infra.py` only reads those under `hosts/<host>/system/` — a header no parser reads is decoration dressed as a checked invariant. |
| **`dd-ctl`'s verbs take no arguments** ⚠︎SUPERSEDED | Deleting the arguments deletes every line of validation that existed to make them safe, and the bugs that could hide in it. It also means the keyholder cannot name the image. It does **not** mean the image is safe from everyone — see below. |
| **The deployed image is a literal in `compose.yaml`, not a variable** | It is the one knob, and it is tracked. `SOURCE` already withholds the commit deliberately; putting the *branch* in a gitignored `.env` too would leave this repo unable to say anything at all about what `two` runs. It also removes a `${…:?}` failure path and any chance of `.env` and `compose.yaml` disagreeing. Editing it to test a branch shows up as local drift, which is the desired signal. |
| **`root-setup.sh` generates the dispatch key itself; the private half goes in the Claude Code environment block** ⚠︎SUPERSEDED | The operator had to arrive with a keypair and paste its public half in. Now the box makes one, installs the public half, and prints the private half once as base64 for `DD_CTL_KEY_B64`; a `SessionStart` hook in the app repo materialises it per session, so ephemeral containers keep working with nothing to re-authorise. The private half never touches the SD card — generated on tmpfs, shredded on exit. **That environment block is not masked**, and that is the constraint the whole arrangement is built around: only a key whose entire reach is dd-ctl's six argument-less verbs may go in it. Never a key that gets a shell. The one exposure is the print itself, in terminal scrollback; the script says so rather than letting it pass. |
| **Exactly one dispatch line, and rotation is opt-in** ⚠︎SUPERSEDED | A second `command=…,restrict` line is not an error anyone can see: both keys authenticate, sshd reports nothing, and neither the box nor the operator can say which one the environment block holds — so revoking the wrong one reads as a broken deploy. A plain re-run therefore reports the installed key's fingerprint and generates nothing, and `DD_CTL_ROTATE=1` **replaces**. That is the single deliberate exception to append-never-rewrite for `authorized_keys` (which is right, because a botched rewrite on a tunnel-only box is unrecoverable): backup first, build beside and rename atomically, and require every non-dispatch line to come back byte-for-byte — so a rotation cannot cost `gavin` his own key. |
| **The live `dd-ctl` is root-owned, and that is the whole mechanism** ⚠︎SUPERSEDED | `/usr/local/bin/dd-ctl`, a real file, 0755, in a root-only-writable directory — never a symlink into `~gavin/infra` and never the checkout's copy run in place. `gavin` owns the checkout, so a forced command resolving through anything `gavin` can rewrite is not a restriction: replace the target, get an unrestricted shell. It was never a boundary *against* `gavin`, who has sudo; it stops the holder of the **restricted key** rewriting the thing that restricts them. **It is not sufficient on its own** — the login shell runs first; see below. |
| **On `two`, 2g, 2e and the Cloudflare dashboard sweep are one job** | They close each other, so tracking them apart invites a half-done state. A tunnel created with `config_src: local` arrives with credentials in a 0600 file, so 2e is satisfied by *construction*; deleting the old tunnel then **voids** the credential that was inline in `two`'s 755 init script until 2026-08-23 — which beats rotating it. ⚠︎ Moving it into `/etc/cloudflared/two.json` stopped the *exposure*, not the *disclosure*: the tunnel secret is unchanged, so anyone who read that world-readable file still holds a working credential for tunnel `bdb4a988`. Only the delete voids it, which is why this is still 2e's last host. The orphaned Access tokens and applications from the failed runs of 2026-08-22 are objects on the same tunnel and the same dashboard visit. The sweep half stays a human step: it needs judgement about which token the phone holds. |
| **Every informational `debug` in a playbook carries `changed_when: true`** | `display_ok_hosts = False` in `ansible.cfg` buys a quiet run on a phone screen, and a `debug` task reports **ok** — so the setting silences every message the playbooks exist to print. It cost the one that matters most: `cloudflare-dev-tunnel.yml` mints an Access service token, whose secret Cloudflare returns at creation and never again, and printed it into a suppressed `ok`. Marking those tasks changed is a display decision, not a claim about state. The price is that `changed` in the recap stops meaning "the fleet moved"; the alternative — turning the setting back off — costs the quiet run everywhere to fix output in one place. |
| **A lost service-token secret is recovered by rotation, never by delete-and-recreate** | Cloudflare will not delete a service token an Access policy references (`400` / `12139` `service_token_in_use`), and every token here is named by the policy that admits it — so the delete-and-recreate path `cloudflare-dev-tunnel.yml` shipped with could only ever have worked on a half-provisioned container. Rotation is also simply better: one call instead of three, the token id and the policy untouched, no window in which the application has nothing to admit, and the old pair dead the instant the new one is printed. The flag is `-e rotate_service_token=true`; the old `replace_service_token` is refused by name rather than redefined, because it described an operation that does not exist. |
| The base image is parameterised by **environment and baked files**, not by forks | A child that needs different behaviour sets `DEV_*` in its compose, or bakes `ssh_config` / `known_hosts.extra` / a `sshd_config.d/*.conf` / a `child-init.sh` (an `rc-supervisor.sh` was one of these until 2026-08-25, when remote control left the fleet — see the superseded rows below). or3-dev was the test: it needed a different secrets directory, different key names, an extra pinned host key, TCP forwarding on, and a remote-control daemon — and every one fits a seam. Had any needed a second `entrypoint.sh`, the base would have bought nothing, because the entrypoint is most of the ~700 shared lines. |
| The base copies **every `id_*`** out of the secrets mount, not a list of names | The names are the one thing that differs per container. A list in the base is a list the base has to know about its children, which is the dependency the registry was built to remove. Which keys a container *should* hold is stated in its own `ssh_config`, where an absent `IdentityFile` fails naming itself. The test is the file's first line, not its name, so a stale `.bak` is not copied. |
| ⚠︎SUPERSEDED 2026-08-25 — The base carries the remote-control **hook**, never the daemon | Only an RC-enabled child uses it, dd-dev's is a different design, and `--permission-mode auto` is a decision about the container that makes it. In the base that default is one environment variable away in every child. **Replaced by: no remote control on this fleet at all.** Every dev container is reached by ssh with the work in an abduco session; dd-dev, ds-dev and or3-dev deleted their supervisors, `DEV_REMOTE_CONTROL` is gone from the base, and the hook went with the daemons it started. |
| ⚠︎SUPERSEDED 2026-08-25 — `remoteDialogSeen` is seeded **only** under `DEV_REMOTE_CONTROL=1` | It suppresses the one-time Remote Control consent prompt, which a headless container cannot answer. Seeding it where nothing ever starts remote-control is pre-consenting to a thing that container deliberately does not do. **Replaced by: it is not seeded at all**, since no container starts remote-control — the reasoning survives its subject. |
| A drop-in cannot brick a dev container: `sshd -t` runs before the `exec` | The `sshd_config.d` seam lets a child inject text into the config that decides whether sshd — which is PID 1 — starts at all, on containers that are `restart: no`. The preflight starts without the drop-ins and says so, rather than not starting. Falling back is safe by structure, not by care: the `Include` is first and sshd is first-match-wins, so a drop-in can only override, and the base it falls back to is key-only with no forwarding and no passwords. **The `Match`-leaks-into-the-main-file hazard this seam was documented with turned out to be false** — measured on OpenSSH 9.2, a drop-in's `Match` is confined to that file. Three readings repeated it because each was checking whether the rule was followed, not whether it was true. |
| The base runs a child's **`child-init.sh`** at start — the fifth seam | The other four seams place a *file*; dd-dev and ds-dev needed something *done*: `uv sync --frozen` against the lockfile in the bind mount, which cannot happen at build time because `/workspace` is not mounted then. Two of the four children need it, which is this base's own test for what belongs in it. Placed after the pull, so a lockfile that just moved is what gets installed, and before sshd, so no session arrives to a half-installed venv — a child wrapping the `CMD` instead would get neither. Non-fatal, like the pull: the door is the one thing that must come up, and a container you can ssh in and fix beats one that refused to start over its own dependencies — **and time-bounded for that same reason**, because non-fatal only covers the half of it that exits, and a hook that hangs ahead of sshd costs the door exactly as a crash would. |
| A start-up warning that names the wrong thing is worse than no warning | Two in the base were infra-dev's own written as if they were everyone's. *zero, one and two are unreachable* means nothing in or3-dev, dd-dev or ds-dev, so it now prints only for a container that did not name its own `DEV_SECRETS_DIR` — which is infra-dev, by definition. *NOTHING can ssh in* is false when a drop-in names its own `AuthorizedKeysFile`, which is exactly dd-dev and ds-dev serving the host account's keys; the base tests the drop-in's own text rather than a flag — and only `*.conf`, which is what the `Include` globs, so a `.bak` beside a drop-in cannot silence the warning that the door is shut. Both would otherwise have been inherited by two more containers on the day they converted. The same first-match-wins cuts the other way: a secrets `authorized_keys` copied out *while* a drop-in overrides the path is a copy nothing reads, so that case says so too. |
| **One way into every dev container: ssh, and abduco holding the work** | Four containers had three arrangements — infra-dev refusing remote control by design, or3-dev shipping a daemon it defaulted to off, dd-dev and ds-dev running one as PID 1's payload. Three arrangements means three things to remember at 2am and three failure modes to tell apart, for a capability that duplicates the door: `ssh -t <name> abduco -A claude claude` already survives the dropped link, and it does not put a permission classifier in charge of a container holding deploy keys. The supervisors are deleted rather than defaulted off, because a daemon that ships disabled is one env var from running and nobody reviews an env var. |
| **An idle claude is offloaded after 90 minutes, and the conversation is not** | Measured on infra-dev: one detached session's process tree held 1,146 MB RSS, on a 4 GB Pi that runs four of them plus Immich. The conversation is already on disk — `claude --resume` — so memory is the only thing an idle process holds that anyone wants back. 90 minutes because a claude can schedule its own wake-up and the runtime clamps that to an hour: past that, nothing inside the process is coming back for it. The script refuses a limit under 3600s rather than clamping one, and refuses to touch an attached session, a session with any non-claude process running under it, or one with no transcript to time. |
| **The laptop is two ssh clients, and Ansible runs on one of them to configure both** | Windows cannot be an Ansible target without sshd on it, which is a lot of machinery for three files. Under WSL it does not have to be: `C:\Users\gavin` is mounted at `/mnt/c/Users/gavin`, so one run of `dev-client.yml` *in WSL* writes the Linux config and token **and** the Windows config, token and wrapper. `ssh-client.yml` already did this for the fleet block; the dev-container blocks were simply never given the same half, which is why a WSL run appeared to do nothing on either side of the laptop. Run from Termux, `/mnt/c` is absent, the Windows half is skipped, and the block and wrapper are rendered to a paste file — **but never the token**, because a secret in a file the owner opens and copies out of is a secret in scrollback. |
| **Windows gets a `.cmd` ProxyCommand wrapper, not a longer ProxyCommand** | Every POSIX client loads the service token in one line — `ProxyCommand sh -c '. token; exec cloudflared …'`. Win32-OpenSSH has no `sh`, and the two shortcuts that close the gap are both refused: `--service-token-secret` on the command line puts a live credential in the process list, and a `setx` puts it in the environment of every process the account starts. So the load-then-exec becomes `cf-access-<alias>.cmd`, which `setlocal`s, reads the two values off `findstr`'s **stdout** (not its argv), and runs cloudflared as its final command — the same guarantee the `sh -c` gives, spelled for the shell that is actually there. Not the same *shape*: batch has no `exec`, so cloudflared is a child of the wrapper rather than a replacement for it, and the wrapper's closing comment says what that costs. It runs the *Windows* cloudflared, consistent with the fleet block's existing choice; the WSL half needs its own Linux binary, and `command -v cloudflared` will not find `cloudflared.exe` for it. |
| **The Windows token's permissions are printed, not asserted** | `/mnt/c` is drvfs and carries no Unix mode, so `mode: "0600"` there either fails or silently does nothing — and a task that pretends to have set a mode is worse than one that does not try. What protects that file is the NTFS ACL `C:\Users\gavin` hands down. The play runs `icacls.exe` through WSL interop and prints the result with `changed_when: true`; it does **not** assert on it, because this repo's own rule is that a check is calibrated against known-good state before its verdict is trusted, and nothing in the control plane can see that laptop to calibrate against. Localised account names would have made a name-matching assertion wrong on a machine nobody here can test. |
| **A playbook run with no inventory fails instead of exiting 0** | `ansible.cfg` is read from the cwd and is the only thing pointing at `./inventory`, so running a play from anywhere else makes `hosts: control` match nothing: Ansible prints `skipping: no hosts matched`, an empty recap, and **exits 0**. With `display_ok_hosts = False` a real run also collapses to banners, so the two read alike on a phone and the conclusion drawn is "it ran, nothing to do". No task inside the play can catch it — the play is skipped whole — so the guard is its own play in `playbooks/_inventory-guard.yml`, imported above the real one and matching `localhost`, which Ansible provides even with no inventory at all. That is exactly the case being caught. |
| **One command writes every ssh block, and the composition is four static imports rather than a loop** | `this-client.yml` imports `ssh-client.yml` once and `dev-client.yml` once per dev container, with the alias, hostname and port as import vars. A loop over a list is the obvious spelling and is wrong here: `dev-client.yml` prompts for a credential and writes it at 0600, and a loop puts those prompts and writes inside `loop:` results, where `no_log` hides which iteration is which — so a mistake becomes a mistake about a secret you cannot see. Static imports keep the reviewed single-alias play byte-for-byte as it was, each stanza reads as the fact it asserts, and `-e alias=…` still works for a single container, which is the rotation path. Verified: import vars reach the imported play, do not leak between imports, and `meta: end_play` inside one import does not stop the next. |
| **The dev-container port registry moves into the playbook that consumes it** | It was a comment in or3's `dev/compose.yaml` — the worked example that opens `management-plane.md`'s drift table, a fact about `zero` recorded in the newest claimant's app repo where nothing in this repo could contradict it. It is now the header table of `this-client.yml`, and every `<alias>-lan` block on every client is built from those numbers. That is the difference that matters: a wrong number is now found by somebody using a rescue path, not by somebody re-reading a comment. The evidence it was needed is in the same commit — `management-plane.md`'s own port paragraph had been missing `2225 infra-dev` since the day `infra-dev` was built. |
| **A missing service token skips its container by name; it does not stop the run** | `-e prompt_for_token=false` makes `dev-client.yml` print what it is skipping and `meta: end_play` out of that import. Without it, one command against a fleet where half the tunnels are still Phase 5 stops on a prompt for a credential nobody can produce, and the containers that *are* provisioned never get written. Default is still to prompt, because that is right for a client being set up against a fully provisioned fleet, and because a flag that quietly tolerates a missing credential is one that hides a real failure. The skip writes **nothing** for that container rather than a partial block: a `ProxyCommand` sourcing a token file that is not there fails as `Connection closed`, which reads like the container being down. |
| **The `ssh-zero-dev-*` aliases leave the fleet block, and that is only the client half** | Every dev container now runs its own connector behind its own hostname and Access token, so the rules on **zero's** host tunnel are a second door to each — the argument 2i was filed on. `zero-dev-or3` was already dead when it went: its ingress came off in `7bb2075` and the alias named a hostname with no route, which fails exactly like the container being down. Dropping the other two stops this fleet *using* that door; it does not close it. Closing it edits `hosts/zero/system/cloudflared-config.yml` and cycles zero's connector, which is a box change the owner drives from a mesh route — filed, not done. |
| **The generated ssh blocks keep rescue notes; the reasoning moves to a doc** | A client's `~/.ssh/config` was 484 lines to express 130 lines of configuration, because the dev-container explanation was inline in the template and therefore written once **per container** — four identical copies of the same seventy lines, in a file that is read on a phone. [`ssh-clients.md`](ssh-clients.md) now holds the why; each block keeps only what is useful with a wedged connection in front of you: which alias does what, the `RemoteCommand` gotcha, what `-lan` is and is not independent of, and the `nc`-not-`ProxyJump` reason. 275 lines, and the same 130 directives — proved by rendering both template versions across every permutation and diffing the non-comment lines, then by `ssh -G` over 25 aliases before and after. This does not soften the repo's comment habit: a comment that says *why* still belongs next to the thing, and the test applied was whether you would need it during an outage, not whether it was interesting. |
| **No dev container gets an alias for zero's host tunnel** | The `ssh-zero-dev-*` rules are a door **zero** opens on a container's behalf; every dev container now comes up with its own connector, hostname and Access token, and `dev-client.yml` writes three aliases for each. `dd-dev` and `ds-dev` are not running until they are deployed that way, so an alias for the old door would name a hostname with nothing behind it — the failure that reads as the container being down. This was briefly reversed on 2026-08-28 out of a worry about removing a working fallback; the fallback was not working, and the owner knew the fleet's state where the repo did not. **Dropping an alias closes nothing** either way: the rules live in `hosts/zero/system/cloudflared-config.yml`, and removing them is a boot-path edit plus a connector cycle — phase 2i, and the owner's to run. |
| **Whitespace and line-ending tests go in awk, not in grep or `case`** | `bin/one-shot-ssh-defaults-note` refused a config whose last stanza demonstrably *was* `Host *`, and printed `Host *` as the thing that was not `Host *`. Three inputs produce that and all three are invisible in a terminal: CRLF endings (`Host *<CR>`), a trailing tab, and two spaces between the keyword and the `*`. The check was `case` against `grep -n '^[Hh]ost[ \t]'`, and `[ \t]` inside a grep BRE is not a tab — it is a bracket expression matching a space, a **backslash**, or the letter `t`, so `Host<TAB>*` was never even found. awk's regex engine understands `\t`, and one `sub(/\r$/, "")` on read removes the whole class. The file's own line-ending convention is then preserved on write rather than normalised, because changing every line of a config to fix a comment is not what the script was asked to do. This is the same failure the repo already records twice — a check that can pass, or fail, for the wrong reason, and a pattern counting characters across multi-byte or invisible input. |
| **A prompt for a credential names the credential** | `this-client.yml` imports `dev-client.yml` once per dev container, so the run showed four identical play banners and four identical `Client Secret (not echoed)` cursors with nothing distinguishing them — reported from the laptop, and the honest answer to "which one is it asking for?" was that you could not tell. The play name, both prompt task names, and the prompt strings themselves now carry `{{ dev_alias }}`, and the announcement above them names the container, its hostname and where to read the token off a client that already has it. Play names and task names template against the play's own `vars:`, which was worth verifying rather than assuming. The general form: composing a play by importing it N times makes every message in it ambiguous by default, and the ones that ask for something are where that costs. |
| **The Windows ProxyCommand wrapper is written with `newline_sequence: "\r\n"`** | cmd.exe seeks by byte offset between commands in a batch file and miscounts on an LF-only one, resuming mid-line and executing fragments of the file's own comments — `'ible' is not recognized as an internal or external command`, from the middle of the word "ansible". The wrapper's header had asserted the opposite ("LF line endings are fine here"), which was never checkable from a control plane that cannot run cmd.exe and should not have been written as fact. Two other spellings were tried and are recorded in the task so nobody repeats them: a `replace('\n', '\r\n')` filter on a `lookup('template')` silently does nothing, and CRLF in the template file survives only while that file has no Jinja in it — the lexer normalises newlines once it does. The wrapper is also ASCII-only now, for the same class of reason: it runs under the console codepage, not UTF-8. |
| **`IdentityFile`/`IdentitiesOnly` are written only when the client has that key** | `IdentitiesOnly yes` is worth having — it stops ssh walking every key an agent holds and hitting `MaxAuthTries` before it reaches the right one. But it also means an **agent** key is offered only when its public half matches a named `IdentityFile`, so on a client whose private key lives in an agent and never on disk — Windows' OpenSSH agent reached from WSL is the case that found it — the pair we wrote left ssh nothing to offer and the container answered `Permission denied (publickey)`. The play now stats the key and its `.pub` on each side (they are different files: `~` in WSL is not `C:\Users\gavin`) and omits both lines where neither exists, saying so. An `-e identity=…` that does not resolve is still a hard failure, because that is a typo rather than an agent. |
| **A task var must not share a name with a `set_fact`** | Ansible's precedence puts `set_fact` at 19 and task `vars:` at 15, so a task var named after an existing fact is silently ignored — no warning, no error. Passing per-render values into `ssh-dev-block.j2` as `identity_usable` therefore rendered **both** the POSIX and the Windows block with the POSIX client's answer, on a laptop where the two sides genuinely differ. Renamed to a name the play never sets as a fact. The general rule: a variable that exists to be overridden per task must never also be a fact, and `| bool` belongs on it, because `set_fact` coerces `"True"`/`"False"` to real booleans while a task var stays a string and any non-empty string is truthy. |
| **A public key is passed as JSON or a file path, never as `-e k=v`** | Ansible's `k=v` extra-var form splits on **whitespace** into several pairs, so `-e client_pubkey='ssh-ed25519 AAAA... you@host'` arrives as the single word `ssh-ed25519` — the rest is silently discarded. It is a truncation that still passes a prefix check, and `ansible.posix.authorized_key` then fails with `list index out of range`, which names nothing. `authorize-dev-client.yml` counts the whitespace-separated fields rather than trusting the prefix, and its failure message says which of the two working forms to use. Same class as the `-e st_client_secret` hole in `dev-client.yml`: an extra-var that looks like it worked is worse than one that errors. |
| **A lookup inside a `fail_msg` cannot report its own failure** | `authorize-dev-client.yml` read the key file with `lookup('file', …)` in a play var that its assert's `fail_msg` interpolated. A missing file therefore blew up while Ansible was *rendering the error message*, producing forty lines ending in `Finalization of task args for 'ansible.builtin.assert' failed` — for a wrong relative path, which the message was written to explain. The existence check is now its own task, before anything reads the file, and it is `delegate_to: localhost` because the play targets `zero` while every lookup runs on the control node: an undelegated `stat` would look for the key on the wrong machine. The general form: anything a failure message needs must be known to be safe *before* the failure can occur. |
| **`~/.ssh/cp` and `~/.ssh/cm` are two directories, and both are the client play's job** | `ansible.cfg` multiplexes through `~/.ssh/cp/%C`; the infra-fleet block multiplexes through `~/.ssh/cm/%n-%r`. `ssh-client.yml` created only the second, so a fully configured control node still died the first time it ran a play against a fleet **host**: `unix_listener: cannot bind to path …: No such file or directory`, reported as **UNREACHABLE** — which reads like the box being down and is a missing `mkdir`. It hid for months because every play run from the laptop until then was `hosts: control`, which connects locally and never multiplexes; the phone had the directory because `ansible.cfg` says to make it by hand and someone once did. A prerequisite that only one node happens to satisfy is not a prerequisite, it is an accident. |
| **A rollback restores every file it replaced, and then proves the service came back** | The cutover's rescue restored `<host>.json` and cycled — but `install-system-file` had already replaced `/etc/cloudflared/config.yml` with one naming the **new** tunnel, so a rolled-back host was left with the old credentials and a config pointing somewhere else. cloudflared will not start on that pair. The play then reported *"every hostname still points where it did"*, which was true about DNS and silent about the connector, and the rescue never asked `/ready` — so a failed cycle-back read exactly like a successful one. Found on `two`, 2026-08-28, on the box whose tunnel is its only door and which logs nowhere until 2f reaches it. Both halves are now backed up as `.pre-2g` and both are restored; the rescue then polls `/ready` and says out loud when the answer is zero. |
| **A guard that reads `lookup('file', …)` has checked the control node, not the host** | The cutover asserted that the new credentials and "the reviewed config" named the same tunnel — but `lookup` always runs on the control node, so it compared phase 1's output against the machine that produced it and proved nothing about the box. On `two`, 2026-08-28, the host's clone (`~gavin/infra` — **not** the `/srv/infra` three docs claimed, which does not exist there) did not carry the reviewed config: `install-system-file` installed the OLD config as a no-op, the credentials were then swapped to the NEW tunnel, and cloudflared could not authenticate a tunnel its config did not name. It surfaced as `/ready` returning 503 with zero connections — which reads like a slow box or a network fault, and sent the first diagnosis after a timing hypothesis that was wrong. Two guards now: the host's own clone is slurped and compared before anything is written, and the **installed** `/etc/cloudflared/config.yml` is re-read after the install and before the credential swap, so a mismatch aborts with the host still on its old tunnel instead of after an outage. |
| **`no_log` on a READ hides the refusal too, not just the secret** | `CLAUDE.md` already records this for a `no_log` *write* that can be refused — carry `failed_when: false`, print the body's error list, then assert. The cutover's DNS lookups were bare `no_log` reads, so a 403 arrived as `Status code was 403 and not [200]` with the response censored, and the response body is the only place Cloudflare names the missing permission. Cost a run on `two`, 2026-08-28. The rule is about direction of travel, not about writes: any call whose *failure* carries information needs its body printed, and the thing that must never be printed is the invocation, where the Authorization header is. |
| **The cutover needs three Cloudflare permissions, not two** | Every prompt and the *Safe to delete* list said `Tunnel:Edit` and `Zone:DNS:Edit`. The cutover opens with `GET /zones?name=gsrpi.uk` to find the zone id, which needs **`Zone -> Zone -> Read`** — a token minted for phase 1 (tunnel-only, which is genuinely all phase 1 needs) gets 403 there. Fixed in the prompts of both plays that touch DNS and in `cloudflare.md`, and the assert now says which of the three is likely missing rather than leaving a bare status code. |
| **A relative `-e …_file=` is anchored to `$PWD`, not to the playbook** | `lookup('file', 'x.pub')` resolves against the **playbook's** directory, so a key sitting in `ansible/` is searched for in `ansible/playbooks/` and reported missing while `ls` in the same shell plainly shows it. That is a correct reading of Ansible's rules and a wrong reading of what the person typing it meant. The play expands `~` and anchors anything else to `$PWD`, so the argument means what it looks like it means, and the failure message says which directory it resolved to. |
| **Authorising a key refreshes the container's copy; it does not restart anything** | `dev/entrypoint.sh` copies `$DEV_SECRETS_DIR/authorized_keys` to `~/.ssh/authorized_keys` at start-up and `sshd_config` names the copy, so a key added on the host reaches a running container only when that copy is refreshed. The obvious move — restart sshd — is the wrong one twice over: **sshd is exec'd as PID 1**, so restarting it restarts the container and takes every detached abduco session with it; and it is unnecessary, because sshd reads `AuthorizedKeysFile` on each authentication attempt rather than at start-up. `authorize-dev-client.yml` therefore copies the file inside each container over that container's own `-sh` alias — the same command a person would type, so a failure is fixed by the command that failed — and treats it as best-effort: the host-side write is the durable half, so a container that is down is reported, not fatal. |
| **`command:` needs `expand_argument_vars: false` when the argument is for another machine** | The refresh task passes a small shell script to `ssh`, and `command` expands environment variables in its arguments **by default** — so `$HOME` was resolved against the CONTROL NODE before ssh was invoked, and the copy was aimed at a path that exists on the phone and not in the container. Caught by logging the argv the task actually built rather than reading the task; `$c` and `$d` survived only because they happen not to exist in the controller's environment. Anything destined for a remote shell must be marked as not ours to expand. |

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
and `send2ereader` the original reason holds in full: they are built from checkouts, on
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
zram on both hosts, and `one`'s file modes, are the current examples.

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
(`playbooks/cloudflared-update.yml`). With per-architecture builds, `two` would be the
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

## The lesson worth keeping

**A check that can pass for the wrong reason is worse than no check**, because it stops
you looking. The port-forward check originally asked only "did the port change" and
passed on qBittorrent's own default within seconds. See
[port-forwarding.md](port-forwarding.md#3-the-port-changed-does-not-mean-it-worked).
