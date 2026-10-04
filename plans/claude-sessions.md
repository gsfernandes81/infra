# Claude sessions in the dev containers: cheap when idle, findable after a disconnect

**Status: proposal, partly decided** (see *Taken by the owner*). Each decision moves to
[`docs/decisions.md`](../docs/decisions.md) in the commit that implements it.
**Phase 2 is a hard gate:** no rendering code is written until the owner has approved
mockups — see Phase 2 for exactly what that means.

Reviewed 2026-10-01 by a Fable advisor; its blocking findings are folded in below.

## Why

The phone reaches the fleet over a metered satellite link. ssh into a dev container costs
almost nothing; the Claude Android and web apps cost a great deal. So the dev containers
on `zero` are where Claude is driven from, and two things make that worse than it should
be:

1. **RAM.** One idle session's tree was measured at 1,146 MB on 2026-08-25
   (`offload-idle-claude.sh`'s header), 819 MB of it in `bg-pty-host`/`bg-spare` helpers.
   Measured again on 2026-10-01 against Claude Code 2.1.286, in a pty with a throwaway
   config:

   | state | RSS |
   |---|---|
   | plain interactive session, idle 60 s | ~250 MB — `claude` alone, no daemon |
   | after pressing **←** once at an empty prompt (the footer reads "← for agents") | ~1,260 MB — a transient `daemon run`, a warm `bg-spare` with its `bg-pty-host`, and two further full sessions with pty hosts |
   | back at the prompt, 60 s later | ~1,250 MB — nothing released |
   | after the session itself exited | ~690 MB still running (daemon, spare, one background session) until `claude daemon stop --any` |

   With `"disableAgentView": true` in settings **or** `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`,
   **←** does nothing, `claude agents` refuses ("disabled by the 'disableAgentView'
   setting") and no daemon starts; RSS stays ~250 MB. On `zero`, or3-dev was holding
   ~700 MB of daemon and spares on 2026-10-01 (owner's `ps`). The leftovers that outlive
   their session are invisible to today's offloader, which walks down from abduco.
   Caveat: the measurement used a dummy API key, not a claude.ai login, and the binary
   skips warm spares when free memory is under ~1 GB (`tengu_bg_low_mem_mb`) — re-measure
   on `zero` in Phase 0.

2. **Finding your way back.** `ssh <c>` is `abduco -A claude claude`: one session per
   container, and after the offloader stops it, the next `ssh <c>` starts a *fresh*
   claude while the resume command sits in a log. There is no way to hold several
   sessions, see which of them wants you, or end one deliberately.

## Goals

- Idle sessions cost ~250 MB, not ~1.2 GB; a session nobody is using costs nothing.
- Several concurrent claude sessions per container, each reachable from any ssh login.
- After a disconnect or a night away, one screen lists the open sessions in a useful
  order and opens the chosen one — reattached if live, resumed if offloaded.
- Ending a session is a deliberate act with one obvious spelling.

**Not in scope:** merging the per-repo containers. It is not decided, and cheap idle
sessions may remove the reason for it; nothing here should assume either layout. Cloud
sessions (claude.ai/code); anything on the phone
beyond the ssh config the client play already writes.

## Design

### 1. The agent view is off fleet-wide

`disableAgentView: true` in **managed settings** baked into the base at
`/etc/claude-code/managed-settings.json` — the path checked against the binary, not
assumed; a `managed-settings.d/` drop-in directory sits beside it — so neither a repo's
`.claude/settings.json` nor a user setting can turn it back on.
`CLAUDE_CODE_DISABLE_AGENT_VIEW=1` in the image's ENV is the second switch, and it is
checked *before* settings load, so it holds where the file does not; the entrypoint
already publishes ENV to ssh sessions via `~/.ssh/environment`. Cost: `claude --bg`/`claude agents` are unavailable in these
containers, which is the point.

### 2. Slots, conversations and the registry

A **slot** is one abduco session (name `claude-<n>`), i.e. one running claude process. A
slot holds a sequence of **conversations** (Claude session ids): `/clear` starts a new one
in the same process, `--resume` re-enters an old one. The registry is keyed by slot:

`slot` · `pid` + start time (recorded by the hook, so a reused pid is never mistaken) ·
`session_id` (current) · `cwd` / repo · `title` · `state` · `last_activity` ·
`last_attach` · `needs_you` · `timers` (each with its due time, and whether recurring)

States: **attached** / **detached** (from abduco's listing, never stored) · **offloaded** ·
**closed**. **Unread** is derived, not stored: a `Stop` later than `last_attach` — the
session finished something while you were away.

**Storage:** `~/.local/share/claude-sessions/`, one JSON file per slot, written tmp-then-rename,
under a per-slot `flock` taken with a timeout. `~/.local/share` is already a persisted
volume in all four children, and it keeps Claude's config directory Claude's. **The same
per-slot lock is held by whoever acts on a slot** — the launcher attaching or resuming,
the offloader from decision through kill, `close` — which closes the decide→signal race
the current script only narrows, and makes "never resume a conversation that is already
running" atomic across two ssh logins.

**Which slot a hook belongs to:** the launcher starts each slot as
`abduco -c claude-<n> env CLAUDE_SESSIONS_SLOT=claude-<n> claude …`, so every hook inherits the name.
A hook binds to the slot **only when its claude is the direct child of that slot's abduco
server** (checked in `/proc`); a nested claude — a `claude -p` from a Bash tool call, a
subagent's — inherits the variable too, and must count as work running under the slot,
never rebind its `session_id`. Sessions started without the launcher (see *Unregistered
sessions*) are found by walking `/proc` from the hook up to the first claude whose parent
is an abduco server.

**Hooks write the registry,** configured in the same managed settings, so every repo gets
them without touching its `.claude/`. `claude-sessions hook` reads the event's JSON on stdin.
**It always exits 0**, logs its own failures to its log, and never blocks: a hook that
exits 2 on `UserPromptSubmit` blocks the prompt, and on `Stop` it makes Claude carry on —
a registry bug would wedge every session in the fleet. A test pins this.

| event | registry effect |
|---|---|
| `SessionStart` (source startup / resume / clear / compact) | bind `session_id`, `cwd`, pid + start time; state live |
| `UserPromptSubmit` | `last_activity = now`, busy, clear `needs_you` |
| `Stop` | `last_activity = now`, idle since now |
| `Notification`, type permission prompt / elicitation dialog | `needs_you` — never offloaded while set |
| `Notification`, type idle prompt | **nothing.** It fires about a minute after every `Stop` nobody answers; treating it as `needs_you` would make every detached session permanent |
| `PostToolUse` on the timer tools (names confirmed in Phase 0) | add or remove a timer, with its due time |
| `SessionEnd`, reason `clear` | nothing — `SessionStart` (source `clear`) follows in the same process |
| `SessionEnd`, any other reason | `closed`, unless the slot is marked `offloading`, in which case `offloaded` |

**Title:** Claude's own session title if the transcript carries one (summary / `/rename`),
else the first user prompt, truncated. Phase 0 confirms where that lives.

**Container restart:** `stop`/`start` keeps `~/.abduco` sockets on disk and reuses pids.
The entrypoint runs `claude-sessions reconcile` at start: every slot whose pid + start time is gone
becomes `offloaded`, and stale abduco sockets are removed.

**Unregistered sessions:** until every client has re-run `client-home-ssh-config.yml` (phone,
WSL and Windows), `ssh <c>` still runs `abduco -A claude claude`, and so does
`make claude` in all four repos and anything started by hand from `<c>-sh`. The menu lists
**abduco's sessions ∪ the registry**, marking the ones it did not start; `claude-sessions offload`
keeps today's transcript-clock rule (and the hour floor) for those.

### 3. The offloader, rewritten as `claude-sessions offload`

Same contract as today — never an attached slot, never one with work running under it,
never without evidence — with the hook state replacing the transcript clock:

- Offloadable when: detached, `Stop` is the latest event, no `needs_you`, no pending
  timer (owner, 2026-10-01: never, whoever set it), no non-claude descendants, idle past the threshold.
- The threshold drops from 90 min to **10 min** (owner, 2026-10-01). The hour floor existed
  only because self-scheduled wake-ups were invisible; the timer records make them visible.
- Holds the slot lock from decision through kill; marks the slot `offloading` before
  signalling and `offloaded` after; keeps the TERM → grace → KILL → abduco teardown and
  the pid-plus-start-time checks of the current script.
- **Low memory** is the container's, not the host's: `/proc/meminfo` inside a container
  shows all of `zero`, while the ceiling is the cgroup (`mem_limit` 1024m on infra-dev,
  2560m on or3-dev and dd-dev). Read `/sys/fs/cgroup/memory.max` and `memory.current`;
  fall back to `MemAvailable` only when the limit is `max`.
- **Orphan sweep:** `daemon run --origin transient` trees whose spawning pid + start time
  is gone, with their `bg-pty-host`/`bg-spare` children. **Calibrated before it is armed**
  (CLAUDE.md, *Verifying changes*): it shipped log-only, and was armed in claude-sessions
  v0.3.0 (2026-10-03) on the owner's word; here it stays dry until Stage B.

### 4. The launcher, `claude-sessions` — a Rust TUI

Reached through a door script, not directly: `claude-sessions-door` (in the image, beside
`in-workspace`) runs `claude-sessions`, and if it exits non-zero prints why and `exec "$SHELL" -l` —
`$SHELL`, because dd and dossier set the login shell to bash. Every lock `claude-sessions` takes has a
timeout, so a stuck lock cannot hold the door shut. `<c>-sh` remains the break-glass.

- *(Superseded for the list by v0.3.3 — rows grouped by state, no marks or numbers; see the
  note under Mockups and claude-sessions' `docs/design.md`. Kept as the original design.)*
- **Lists every slot** — live and offloaded, and since v0.3.0 closed ones at the bottom,
  marked `x` and resumable — plus unregistered abduco sessions. Order: needs you, then unread, then most recent activity. Each row: mark,
  repo, title, age. Marks: needs you · unread · attached elsewhere · offloaded ·
  timer pending · not started by claude-sessions (glyphs settled in the mockups).
- **Opening a row:** live → `abduco -a` it; offloaded → start a new slot running
  `claude --resume <session_id>` in its cwd. abduco runs as a **child**, and on detach the
  menu comes back — a fresh login costs an Access handshake on the metered link.
  **Nothing is ever resumed automatically:** RAM is spent on what the owner opens, in the
  order they open it.
- **Guards:** never resume a conversation already running in another slot (two processes
  on one conversation fork it) — checked under the slot lock. When the cgroup is near its
  limit, offer to offload the longest-idle detached slot before starting another.
- **New session:** `n`, in the workspace. (No repo picker: each container holds one
  workspace. If containers are ever merged, a picker is a small addition then.)
- **Close:** `c` on a row marks it closed (and stops it if live, after a confirm). The
  conversation stays on disk and in `claude --resume`.
- **Shell and quit, which used to be one key and are now two:** `s` drops to a login shell
  in the workspace; **`Esc` is the advertised quit**, and it ends the ssh session, because
  the door only falls through to a shell on a NON-ZERO exit. Inside a dialog or the keys
  screen `Esc` means *back* — only `Esc` on the list itself quits.
- **`q` quits too, and is deliberately listed nowhere in the UI** (owner, 2026-10-01).
  Not for habit — nothing has been deployed, so there is no habit to spare — but because it
  is the first key anybody tries, it costs nothing to accept, and it would spend a column in
  a 40-column hint line that `Esc` already covers. Recorded here because a key that works
  and is written down nowhere is folklore, and the plan is the one place that is not the UI.
- **Data discipline:** the screen redraws on a keypress or a registry change, and ages
  tick **at most once a minute** (owner, 2026-10-01). Between those, **an idle menu emits
  zero bytes** — the property `ytq`'s marquee was built to, and tested the same way.
- **Width:** usable at 40 columns (Termux portrait) up; no ambiguous-width glyphs.
- **Startup:** fast enough to be invisible on every ssh (target < 100 ms on `zero`).

### 5. Ending a session

- **`/exit`** ends it: the process exits, abduco goes with it, `SessionEnd` marks the slot
  closed.
- **`/clear` does not.** It starts a new conversation in the same process — right for "same
  session, new task", wrong for "done". The registry follows it via `SessionStart`.
- **`c` in the launcher** closes without opening (for something offloaded last week).
- Stale slots are never closed automatically; they sort to the bottom.

### 6. One binary, built outside this repo

`claude-sessions` (menu, default), `claude-sessions hook`, `claude-sessions offload`, `claude-sessions reconcile`, `claude-sessions close`,
`claude-sessions doctor`: one Rust binary, so the hook path, the offloader and the menu share one
registry implementation and one set of tests.

**The source lives in its own repo, `claude-sessions`** (owner, 2026-10-01) — this one is "config
only — no source". That repo must be **public**: the base is built on a public GitHub
runner with no token. It publishes static (musl) arm64 + amd64 binaries as releases,
**cross-compiled** on the runner (the base itself builds its arm64 layer under QEMU, which
would be very slow for Rust). `Dockerfile.base` downloads a **pinned** release and checks
a per-arch SHA-256, in the shape of `CLOUDFLARED_SHA256_*` there, and runs
`claude-sessions --version` as a **fatal** check — a static binary has no excuse not to run.

**`claude-sessions` is pinned; Claude floats** (it updates itself in place). A change in a hook
payload degrades to "no evidence", which is safe, but RAM would creep back silently.
`claude-sessions doctor` prints, per slot, when each event type was last seen, and `make verify`
shows it.

## Phase 0 findings, 2026-10-01 — PARTIAL, and what is left needs the owner

Established from inside `infra-dev` (Claude Code 2.1.241, Debian bookworm image — see the
last item: this container predates the current base). Everything here was run, not read.

**1. `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` exists, and it is nearly the whole
registry.** One file per live claude, named by pid. Fields seen: `pid`, `sessionId`,
`cwd`, `startedAt` (ms epoch), **`procStart`** (the `/proc` start-time ticks), `version`,
`kind` (`interactive` | `bg`), `entrypoint`, `messagingSocketPath`, `name` +
`nameSource` (`derived` gives `workspace-07`) + `nameSince`, `status` (`busy` | `idle`),
`updatedAt`, `statusUpdatedAt`, and on background ones `jobId`, `agent`,
`bridgeSessionId`, `parkedJobId`. A sibling `<pid>.<sha>.key` holds a `peerToken`.

This answers three Phase 0 questions at once: **binding is nearly free** (pid → session
id, with `procStart` as the reused-pid guard the plan wanted the hook to record);
**`kind: "bg"` names the nested sessions** the design has to keep out of the binding; and
**`name` is where the title lives** — with `nameSource` distinguishing a derived name from
a real one, so the menu knows when to fall back to the first prompt. *(Superseded in
v0.3.1: `name` showed long replies of claude's on the boxes, and titles now come from the
transcript's `custom-title` and `ai-title` entries, as Claude Code's own `/resume` picker
reads them.)*

It does **not** replace the hooks. It is undocumented internal state that floats with the
binary; it is pid-keyed, so dead files accumulate (this container holds files from
August); and nothing in it is a record of *when you last looked*, which is what `unread`
is. Treat it as the fast path and the corroboration, with the hooks as the contract.

**2. Attached vs detached is a file mode, not a listing to parse.** abduco 0.6 keeps
`~/.abduco/<name>@<hostname>` and sets the owner-execute bit while a client is attached:
`srwx------` attached, `srw-------` detached. Verified both ways round on a probe session.
So the menu can `stat` one path per slot — no subprocess, nothing to parse. Note the
socket name carries the **hostname**, which this fleet derives from the container alias:
renaming a container orphans every session in it.

**3. Two clients can attach to one abduco session at once.** Two `abduco -a` clients on
one probe session, both live. So *attached elsewhere* is not an exclusive lock and
opening a row must not assume it is alone at the terminal.

**4. A killed abduco server leaves its socket behind, with the attached bit still set.**
`kill -9` on the server: `abduco`'s own listing dropped the session immediately, and
`~/.abduco/probe-a@infra-dev` stayed on disk reading `srwx------`. **This is the
calibration catch for finding 2** — a menu built on the mode alone shows a dead session
as attached and refuses to offer it. The liveness test is the pid (plus `procStart`); the
mode only ever answers *attached?* for a slot already known to be alive. `reconcile`'s
stale-socket sweep is therefore not just a container-restart concern.

**5. The ceiling is the cgroup, as the plan corrected.** `/sys/fs/cgroup/memory.max` =
`1073741824` and `memory.current` = `864112640`, both readable unprivileged, on a v2
cgroup. `MemAvailable` in here still describes all of `zero`.

**6. The timer tools are `ScheduleWakeup`, `CronCreate`, `CronDelete`, `CronList`** —
read off a live session's own tool registry rather than guessed. `TaskStop`/`TaskOutput`
are not timers and must not pin a slot.

**7. Hook payloads, from the vendor docs** (code.claude.com/docs/en/hooks, read
2026-10-01). This is the contract, not yet an observation — item 8 still owes a captured
payload. Three corrections the event table needs:

- **`SessionStart.source` has a fifth value, `fork`** (`startup|resume|clear|compact|fork`).
  It also carries `session_title` when one is set, and `seconds_since_last_response` on
  resume — which is a better idle clock than anything we would compute.
- **`SessionEnd.reason` has a sixth, `resume`** (`clear|resume|logout|prompt_input_exit|other`).
  The plan's "reason `clear` → nothing" rule **must cover `resume` too**, or resuming a
  conversation marks its slot closed.
- `Notification` carries `notification_type` and `message`, and the full type list is
  matchable: `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`,
  `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`,
  `agent_needs_input`, `agent_completed`, `quota_auto_resume_fired|stale|disabled`. Both
  plan rows survive; `agent_needs_input` is a third *needs you*, and `auth_success` and
  `agent_completed` are not.

Also: common fields include `agent_id`/`agent_type` **on subagents only** — a cheaper
nested-subagent test than the `/proc` walk, though a `claude -p` from a Bash call still
needs the walk. `Stop` carries `last_assistant_message` and `stop_hook_active`.
`UserPromptSubmit` and `Stop` are the two **blocking** events among the ones we use —
`SessionStart`, `SessionEnd`, `Notification` and `PostToolUse` are observational and
ignore the exit code entirely, so the always-exit-0 test should pin those two by name.
And **`SessionEnd` hooks share a 1.5-second budget**: a lock timeout on that path must be
well under it, or the write that marks a slot closed is cut off mid-way. Hooks in managed
policy settings are confirmed supported, which is what Phase 1's file is for.

**8. What is still open, and why this session could not close it.** Auto mode's classifier
refused every nested `claude` invocation, every read under `~/.claude`, and `strings` on
the binary, so none of the following was reachable from an agent session here:

- the RAM re-measure with a real login, and what **←** does now;
- a **captured** payload per event — item 7 is the documentation, and the documentation is
  not the observation this repo's rules ask for;
- whether `SessionEnd` fires on **SIGTERM** at all. The offloader's `offloading` →
  `offloaded` transition depends on it, and if it does not fire, `reconcile` is the only
  thing that ever clears an offloaded slot;
- whether a fired wake-up passes through `UserPromptSubmit`;
- that `--resume` keeps the session id;
- abduco across a container `stop`/`start` (findings 2–4 are all within one container).

**9. ⚠︎ SETTLED SINCE — this was written on the OLD container.** It was recreated on
`2026.09.21.2` the same day; `claude` is now `/opt/npm-global/...`, dev-owned, at 2.1.286,
and the self-updater works. Every RAM number in *Why* was measured before that, which is
the part still worth re-checking. The finding as written:

**This container is not built on the current base, which is why its Claude Code is
stuck.** `claude` here is `/usr/lib/node_modules/@anthropic-ai/claude-code`, root-owned,
with no `/opt/npm-global` at all — the pre-2026-09-21 layout. So the self-updater cannot
write and the version sat at 2.1.241 while npm's latest was 2.1.286. Recreating on
`2026.09.21.2` (published; `ghcr.io/gsfernandes81/gsrpi-dev-base` lists
`2026.08.24`…`2026.09.21.2`) is what fixes it. Worth recording because every RAM number
in *Why* was measured on a container in this state.

**10. A HAZARD FOR PHASE 3, found while closing item 8: managed settings can make
Claude Code stop and ask.** The binary carries a consent dialog — *"Managed settings
require approval"*, with *"these can change where Claude Code runs or what it can connect
to"*, a *"unchanged since your last approval"* memory, and an error string
`Managed-settings consent dialog exited without an answer`. The counts it elides are
`elidedCommandCount`, `elidedSandboxCount` and `elidedIsolationCount`, so those three
categories are certainly in scope. `disableAgentView` is in none of them, which is why
Phase 1's file is inert at launch — verified by grep, not by running it.

**What is NOT established is whether `hooks` in a managed settings file triggers it**, and
Phase 3 puts hooks exactly there. If it does, every launch after a hook change blocks on a
dialog: one keypress inside abduco, but a non-interactive path (a `claude -p`, a wake-up,
anything the launcher starts without a tty) dies with that error string. **Establish this
before Phase 3 designs where its hooks live** — the alternatives are the user settings file
on the `infra-claude` volume, or a `.claude/settings.json` in each repo, both of which lose
the "cannot be turned off" property that managed settings buy. Test by adding a hook to
`/etc/claude-code/managed-settings.json` in a scratch container and starting `claude -p`.

## Mockups — approved by the owner on 2026-10-01

> "Designs approved for use."

**Superseded for the list screen by v0.3.3** (owner, 2026-10-03): rows grouped by state under
headings, no marks and no numbers. claude-sessions' own `docs/design.md` is the current
description; the mockups below are kept as the record of what was first approved.

Also, in the same review: *"Font widths or box alignment is still off but CSS works
otherwise"* and *"Use colour similarly to how Claude code does."* Both are answered below,
the first by measurement rather than by another guess.

**Phase 4 may now begin**, and its first commit — the one that adds ratatui, crossterm or
any rendering code — opens with a `decisions.md` row citing this heading. These screens are
copied into the `claude-sessions` repo's docs when it starts.

These are drawn at **40 columns**, the phone in portrait, and every line was generated to
that width rather than typed to look right. The 80-column versions are in
[`claude-sessions-mockups-80.md`](claude-sessions-mockups-80.md), separately, because at 40
they would wrap and stop being mockups.

**The glyphs are the ones Claude Code already draws** (owner, 2026-10-01): box drawing for
the rules and the dialog frames, `·` in the header. They are East Asian *Ambiguous* in the
Unicode tables — one column in some terminals, two in others — and the reason to use them
anyway is evidence rather than taste: Claude Code renders this set in every terminal this
fleet is driven from. Its mode indicators stay out (`⏵⏵` and the rest), which is the one
part of that vocabulary the owner has seen fail.

**Except `↵`, which is not in the fonts, and that is what the misalignment was.** The owner
reported box alignment still off after the glyph redraw, twice. It was not CSS: U+21B5 is
**absent from every monospace face on Google Fonts** — checked by downloading the subset and
reading its cmap for JetBrains Mono, Noto Sans Mono, Source Code Pro, IBM Plex Mono, Fira
Mono and Space Mono on 2026-10-01. Every other glyph here is present in all of them at a
uniform 600-unit advance; `↵` is in none, so it fell back to another face with a different
advance and dragged the line it sat on out of true. **That is a fact about the terminal too,
not just the browser** — a glyph the common monospace fonts do not carry is a glyph that
will fall back wherever it is drawn. So the key is spelled `Enter`, in letters, and it costs
nothing: `Enter open   n new   c close   ? keys` is 37 columns and still fits 40.

**The marks column stays single-byte ASCII**, and that is not timidity about the rule above.
It is the one field whose width is load-bearing: the age is right-aligned against it, so a
mark that renders two columns wide pushes every age off the screen, while a rule that
renders wide is merely long. Mockup 8's narrowing demo keeps plain `=` rulers for the same
reason — the measured edge should be the one thing on the page that cannot itself be a
width question.

### Colour, in Claude Code's vocabulary rather than a new one

Owner, 2026-10-01: *"Use colour similarly to how Claude code does."* — then, on the first
attempt: *"Too much yellow / orange. Use a less worrying colour at base."* The first version
put amber on every key in the hint line and on every dialog title, which broke the rule
written beside it: amber is the colour that reads as a *problem*, and a screen covered in it
reads as a screen full of problems. **The base accent is blue; amber is left to one mark.**

| where | colour | because |
|---|---|---|
| `!` wants you | amber | the only mark that is a *request*, and the only amber anywhere |
| a key you can press — the hint line, the keys screen | blue | actionable, not alarming |
| `t` timer pending | blue | a fact about time, and the reason the slot cannot be offloaded |
| `*` unread | foreground, bold | news, not a problem |
| a dialog's first line | foreground, bold | it is the question, and a question is not a warning |
| `@` `z` `u` | dim | state, not news |
| slot number, age, rules, frames, the header after the container name | dim | structure |
| title | foreground | the content |

Keys and `t` share the one blue deliberately: they never appear in the same column, and two
blues would be a distinction nobody could name. **In a full list of six slots there are two
amber characters on the screen, and both mean the same thing** — which is the test for
whether amber is still worth having.

Two rules come with it. **Nothing is colour-only** — every mark is a glyph first, so a
monochrome terminal, a pipe or a screen reader loses nothing. And **amber is spent once**: if
`!` and anything else were both amber, neither would mean *this one*. The plain-text mockups
below cannot show colour, which is the honest reason this table exists; the published page
renders it.

### Mockup 1 — The list, every mark mixed
```
infra-dev · 6 open · 812M of 1.0G
────────────────────────────────────────
1 !   permission: write hosts/one     2m
2 *   retire the old tunnel          14m
3 *t  loop: watch the base build     31m
4 @   immich upgrade                 now
5 z   mount guards on one             2d
6 u   claude                          5h
────────────────────────────────────────
Enter open   n new   c close   ? keys
s shell
```

### Mockup 2 — Nothing open
```
infra-dev · nothing open · 812M of 1.0G
────────────────────────────────────────

  No claude session in this container.

  n   start one in /workspace
  q   a shell instead

────────────────────────────────────────
n new   ? keys   s shell
```

### Mockup 3 — Closing a live slot
```
infra-dev · 6 open · 812M of 1.0G
────────────────────────────────────────
1 !   permission: write hosts/one     2m
2 *   retire the old tunnel          14m
╭──────────────────────────────────────╮
│ Close slot 2?                        │
│   retire the old tunnel              │
│                                      │
│ Running. Stops the process, not the  │
│ conversation — resumable from disk.  │
│                                      │
│ y close    n keep                    │
╰──────────────────────────────────────╯
```

### Mockup 4 — No room to open another
```
infra-dev · 6 open · 892M of 1.0G
────────────────────────────────────────
5 z   mount guards on one             2d
6 u   claude                          5h
╭──────────────────────────────────────╮
│ No room for another claude           │
│                                      │
│ 892M of 1.0G used. A new one wants   │
│ about 250M.                          │
│                                      │
│ Offload slot 5, idle 2d?             │
│   mount guards on one                │
│   resumable from disk                │
│                                      │
│ y offload, then open    n cancel     │
╰──────────────────────────────────────╯
```

### Mockup 5 — A resume that fails
```
infra-dev · 6 open · 812M of 1.0G
────────────────────────────────────────
5 z   mount guards on one             2d
6 u   claude                          5h
╭──────────────────────────────────────╮
│ Slot 5 did not resume                │
│                                      │
│ claude --resume 0f9c4a1e exited 1    │
│   No conversation found with that    │
│   session id                         │
│                                      │
│ Left offloaded. Nothing was deleted; │
│ the transcript may be gone.          │
│                                      │
│ r retry   c close it   Esc back      │
╰──────────────────────────────────────╯
```

### Mockup 6 — Back from a slot, after detaching
```
infra-dev · 6 open · 1.0G of 1.0G
────────────────────────────────────────
1 !   permission: write hosts/one     2m
2     retire the old tunnel          now
3 *t  loop: watch the base build     31m
4 @   immich upgrade                 12m
5 z   mount guards on one             2d
6 u   claude                          5h
────────────────────────────────────────
detached from 2 · it is still running
Enter open   n new   c close   ? keys
s shell
```

### Mockup 7 — The keys, on ?
```
infra-dev · keys and marks
────────────────────────────────────────
Enter  open the row (resume if z)
n      new session in /workspace
c      close the row
s      a shell in /workspace
Esc    quit the launcher
?      this

!  wants you: a prompt is waiting
*  unread: it finished while away
t  a timer is pending; not
   offloaded until it fires
@  attached somewhere else too
z  offloaded: Enter resumes it
u  not started by claude-sessions
────────────────────────────────────────
Enter open   n new   c close   ? keys
s shell
```

### Mockup 8 — The hint line as the terminal narrows
```
at 40 columns, the right edge marked:
========================================
Enter open   n new   c close   ? keys
s shell
at 34 columns, the right edge marked:
==================================
Enter open   n new   c close
? keys   s shell
at 26 columns, the right edge marked:
==========================
Enter open   n new
c close   ? keys   s shell
at 18 columns, the right edge marked:
==================
Enter open   n new
c close   ? keys
s shell
at 12 columns, the right edge marked:
============
Enter open
n new
c close
? keys
s shell
at 9 columns, the right edge marked:
=========
n new
c close
? keys
s shell
at 7 columns, the right edge marked:
=======
n new
c close
? keys
s shell
at 6 columns, the right edge marked:
======
  (the menu refuses to draw; the
   door execs a login shell and
   says why)
```

## Phases

0. **Verify on `zero` before building** (read-only; the owner runs anything needing the
   host):
   - re-measure an idle session and one after **←**, with the real login;
   - capture each hook event's real stdin payload once (a logging hook in a scratch
     container): `SessionEnd`'s reason strings, whether it fires on SIGTERM, the
     `Notification` types, and the timer tools' exact names (ScheduleWakeup, CronCreate,
     CronDelete, CronList?) and inputs;
   - whether a fired wake-up passes through `UserPromptSubmit`;
   - that `--resume` keeps the session id; whether `$CLAUDE_CONFIG_DIR/sessions/<pid>.json`
     exists and maps pid → session id (if so, binding is nearly free);
   - abduco: two clients on one session, and stale sockets after `stop`/`start`;
   - which managed-settings path the installed Claude Code reads;
   - where the session title lives in a transcript.
   Findings are written into this plan before Phase 3 starts.
1. ✔ **DONE 2026-10-01 — Agent view off.** `dev/claude-managed-settings.json` baked to
   `/etc/claude-code/managed-settings.json` plus `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` in the
   image ENV, `BASE_TAG` → `2026.10.01` (Makefile, `dev/Dockerfile`, `dev/compose.yaml`'s
   fallback), an `agentview` line in `make verify` that prints **both** switches, the
   `dev/README.md` section and the `decisions.md` row. **Not yet in effect anywhere:**
   nothing changes until each container is recreated on the new base, which is the
   owner's to run — and that recreation is also what clears any daemon and spares still
   running. The other dev repos pick it up when they bump `BASE_TAG`.
2. ✔ **DONE 2026-10-01 — Mockups approved.** Eight screens inline under
   `## Mockups — approved by the owner on 2026-10-01`, with the approval quoted there. The
   gate is open: Phase 4's first commit cites that heading in a `decisions.md` row.
   - Before any rendering code, give the owner plain-text mockups **at 40 columns**,
     drawn exactly as they would render, **inline in this plan** under a heading
     `## Mockups`. They must cover: the list with every mark mixed; the empty list; the
     close confirmation; the low-memory offer; a resume that
     fails; the screen after detaching from a slot; and the narrowest width at which the
     hint line still shows a way out. 80-column versions go in a separate file — the owner
     reads on a 40-column phone, where they would wrap.
   - Iterate until the owner approves. Then rename the heading to
     `## Mockups — approved by the owner on <date>` and quote the approval.
   - **Phase 4 begins with the first commit that adds ratatui, crossterm or any rendering
     code, and that commit cannot be made until the approved heading exists.** Its first
     act is a `decisions.md` row citing that heading. The approved mockups are copied into
     the `claude-sessions` repo's docs when Phase 4 starts.
3. ✔ **MOSTLY DONE 2026-10-01 — the repo exists and the registry, hook, reconcile, doctor,
   list and close are written and tested.**
   **[`gsfernandes81/claude-sessions`](https://github.com/gsfernandes81/claude-sessions)** —
   public, AGPL-3.0-or-later, created on the owner's word. 37 tests green, clippy clean at
   `-D warnings`, covering every row of the event table (`/clear`, resume,
   offload-then-`SessionEnd`, a nested claude, the idle-prompt notification that must do
   nothing, every timer tool and the two that only look like one), the always-exit-0 promise
   against the real binary, and several writers at once against a reader.
   **Still open in that repo:** the managed-settings consent question (step 1 of its handoff;
   it needs root on a container, which an agent session there does not have), CI — written but
   parked at `ci/github-actions-ci.yml` because the token had no `workflow` scope — and the
   first release. `claude-sessions offload` is Phase 5 and unwritten; `last_attach_ms` has no
   writer until the menu exists, so `unread` is permanently true for now.
   **Update 2026-10-02: v0.1.0 is released** (hook, reconcile, offload, list, doctor, close,
   hooks-config; no menu) **and pinned in `Dockerfile.base`** with its two SHA-256s, the
   hooks generated into `/etc/claude-code/managed-settings.d/claude-sessions.json` at build,
   and `reconcile` run by the entrypoint — `BASE_TAG` `2026.10.02`. The consent question is
   now a bring-up check, below. **Superseded the same day by v0.2.0 at `2026.10.02.1`** (step 4).
4. ✔ **DONE 2026-10-02 — released in claude-sessions v0.2.0, pinned in the base at
   `BASE_TAG` `2026.10.02.1`; v0.3.1 at `2026.10.03`, then v0.3.2 at `2026.10.03.1` (infra#2), then v0.3.3 at `2026.10.03.2` (infra#3), then v0.3.4 at `2026.10.03.3` (infra#4), all 2026-10-03; v0.3.6 at `2026.10.04` (infra#5), then v0.3.7 at `2026.10.04.1` (infra#6), then v0.3.8 at `2026.10.04.3` (infra#8, with the forced door from `2026.10.04.2`), all 2026-10-04.** The TUI, to the approved mockups. Rendering tested at 40×24 and 80×24 against a test
   backend; the zero-idle-bytes property tested under a pty; ordering and the guards
   unit-tested.
5. **`claude-sessions offload`** replaces `offload-idle-claude.sh` (deleted in the same commit). The
   orphan sweep shipped dry-run, logging, and was armed in v0.3.0 on 2026-10-03 on the
   owner's word (`decisions.md`, the sweep row) — live only once Stage B drops `--dry-run`.
   **Written, in v0.1.0. Two stages** (`decisions.md` row, 2026-10-02):
   - ✔ **Stage A, landed 2026-10-02 — dry run beside the old script.** The entrypoint runs
     `claude-sessions offload --dry-run` every 3 minutes into
     `~/.local/share/claude-sessions-dry-run.log`; `offload-idle-claude.sh` still acts.
     `make idle` and `make offload-log` show both; `make sessions` is `doctor`.
   - **Bring-up (owner's), in order:**
     ✔ **`2026.10.03.1` (v0.3.2) was brought up on infra-dev on 2026-10-03** and passed steps
     2–4b: no approval dialog, the menu, titles and `/clear` checked by the owner, the rest from
     inside the container. Its one finding became claude-sessions#5, fixed in v0.3.3–v0.3.4.
     `2026.10.03.2` (v0.3.3) was never rolled out. `2026.10.03.3` (v0.3.4) has run on
     infra-dev since 2026-10-03 17:56; its 4b checks were not reported. `2026.10.04` (v0.3.6) was
     never rolled out. Nor were `2026.10.04.1` (v0.3.7) or `2026.10.04.2` (the forced door). For
     `2026.10.04.3`, repeat steps 1, 2 and 4b — 4a and 3 are unchanged — and step 6's
     forced-door bring-up, which the same recreate delivers. **`2026.10.04.4` supersedes
     `.3` before it was rolled out** (2026-10-04: no claude-sessions change, only the
     entrypoint, login and sshd_config text that followed the published port out); read
     `.4` wherever this step says `.3`.
     1. Wait for `dev-base.yml` to publish `2026.10.04.3` (v0.3.8 and the forced door; it
        supersedes `2026.10.03.3` and every tag since), then
        recreate infra-dev:
        `ssh -t zero 'cd ~/infra/dev && make up'`.
     2. `make verify` reads `sessions  : claude-sessions 0.3.8` and `scrollvars: 3 of 3`, a `hooks` line naming six
        events and a `door` line naming `/usr/local/bin/claude-sessions-door`; `make boot-log` has the `claude-sessions reconcile:` and `DRY RUN` lines.
     3. **Start `claude` in the container and confirm no approval dialog appears** — the
        managed-settings consent question, so far settled from the docs only.
     4. Prompt it once, then `make sessions`: the slot shows events. "events: none seen"
        means the hooks are not firing.
     4a. **The menu, by hand, before any client points at it.** From `make shell` (or `ssh -t infra-dev in-workspace`),
        run `claude-sessions-door`. Press `n`, then detach (abduco's key): the menu comes back
        with `detached · it is still running` (v0.3.3 names no session there), and `make sessions` shows that slot
        with a pid and recent `SessionStart`/`UserPromptSubmit`. That proves a slot binds;
        it depends on claude's process name being `claude`, so **a slot with no pid is
        reported before anything else.** The slot's stderr is captured to
        `~/.local/share/claude-sessions/claude-<n>.stderr` for its whole life (it is how a
        failed resume shows its error) — on that first start, check nothing interactive
        went missing into it. And an idle menu sends **zero bytes**: worth a glance at the
        phone's link meter, ages ticking at most once a minute.
     4b. **What v0.3.0–v0.3.8 changed, by hand** (from claude-sessions' handoff, adjusted
        for Stage A):
        - *Titles:* send one prompt in a slot and let it finish — the row shows a short title,
          the one Claude Code's `/resume` picker shows, never a reply. Then `/rename something`,
          prompt again, and the row reads `something`. The recreate ends every slot; each
          takes its new title when it is resumed.
        - *The footer* sits on the bottom line, at your usual size and on the phone in portrait.
        - *The grouped list* (v0.3.3): rows under `Needs you`, `Working`, `Idle`, `Offloaded`,
          `Closed`, no marks or numbers, an unread title bold. Ages at full width keep their last
          character (`now`, not `no`).
        - *Closing:* `c`, `y` — the conversation moves to the `Closed` group, and `Enter` on it
          resumes it in a slot. A slot closed before its first prompt leaves no row (v0.3.3).
        - *The `Closed` group is the transcript store* (v0.3.4): it shows, by title, the
          conversations under `/home/dev/.claude/projects/-workspace*/` that are not running —
          `claude` and `claude-2`'s earlier conversations included — and never a running slot's,
          nor a `/clear`-only transcript (`claude-3`'s `8c084a28…`, if still on disk). **Expect
          one row whose `Enter` is refused, `which is gone`:** `deploy ds-dev ansible`, filed
          under a worktree (`/workspace/.claude/worktrees/dev-hostname-derived`) since deleted.
          Not a bug.
        - *`Enter` on a conversation that never ran in a slot* (one from before the hooks, or
          from `abduco -A claude claude`): a new `claude-N` starts running `claude --resume
          <id>`, and `make sessions` shows its `SessionStart` binding it.
        - *`/clear` takes no lock* (v0.3.2): `/clear` in a slot, then `grep dropped
          ~/.local/share/claude-sessions/hook.log` stays empty while `make sessions` shows the
          slot's new `SessionStart`. **Then leave that cleared slot idle** (v0.3.4): a `/clear`-only
          transcript is no conversation, so expect `would close`, and closing it leaves no row.
          And `make sessions` shows that slot with only its new `SessionStart` — v0.3.4 starts a
          new conversation's event times afresh, where v0.3.2 kept the prompt and `Stop` from
          before the `/clear` (what misled infra's first §3 check, infra#3).
        - *Idle from the prompt:* open a slot, detach without prompting, leave it. Within about
          13 minutes (10 idle plus the 3-minute loop) the **dry-run log** says
          `would close, idle Nm — no conversation on disk to resume` (a new slot never prompted
          has no transcript); `/resume` an old conversation into a slot and leave it,
          and it says `would offload` instead — `make offload-log`'s *WOULD have stopped* half. **Not `offload.log`, and nothing
          is stopped**: that is the handoff's check as Stage B will read it.
        - *Headings* (v0.3.5): labelled rules with a count; rows indented at 80 columns, not
          at 40.
        - *The archive* (v0.3.5): `c` on a `Closed` row moves it under `Archived · N` and
          `~/.local/share/claude-sessions/archive/<id>` appears; `c` on it there brings it back.
          Conversations in `/workspace` older than 30 days sit behind `Archived` at start, and
          `claude --resume <id>` still finds an archived one — the archive is the menu's only.
        - *The spinner* (v0.3.6): closing a running session shows it on that row and `closing
          session` on the status line until done (5 s for TERM, up to about 10 s if it needs
          KILL and abduco's teardown), and it draws as braille dots on
          the phone (Termux) and in Windows Terminal, not as boxes.
        - *A dropped link* (v0.3.7, claude-sessions#6): open the menu over ssh from the phone and
          kill the connection (airplane mode, or kill the ssh client). **Wait two minutes**, or
          until the old `claude-sessions` pid is gone: killing the client hangs the pty up at
          once, but a link that just vanishes is noticed only after sshd's `ClientAliveInterval
          30` × `ClientAliveCountMax 3`, about 90 s — reading sooner passes on v0.3.6 too. Then
          no `core` is in `/workspace`, and `~/.local/share/claude-sessions/` shows nothing new
          beyond normal hook lines.
        - *A closed pipe* (v0.3.7): `bash -c 'claude-sessions --help | true; echo
          ${PIPESTATUS[0]}'` prints `0`. **Not `| head -1`**, which passes on v0.3.6 too: the
          help fits the pipe buffer, so the reader only closes after the write. With `| true`
          the reader is gone first, and v0.3.6 exits 134 every time (calibrated 2026-10-04,
          five runs each).
        - *Slots scroll locally* (v0.3.8, claude-sessions#8): start a session with `n`, then run
          this from a shell in the container (`bash -c`, because the menu's `s` shell is fish
          here, which rejects the loop):
          ```
          bash -c 'for p in $(pgrep -x claude); do echo "== $p"; tr "\0" "\n" < /proc/$p/environ | grep CLAUDE_CODE_DISABLE_ | sort; done'
          ```
          Each slot's claude shows all three `=1`. **Calibrate first:** a `claude` started by
          hand in a shell (`s`, then `claude`) shows only `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`,
          the image's own, and none of the three. Then on the phone, in a slot after a long
          reply, a swipe scrolls Termux's buffer at once with no repaint, and long-press selects.
        - *The sweep:* `grep 'sweep:' ~/.local/share/claude-sessions/offload.log | tail`. With
          the agent view off, expect nothing, or `WOULD KILL` / `would keep, too young` lines
          only (v0.3.4 applies the live age check to the dry run). A `killed` line in
          Stage A means the loop is not running `--dry-run` — report it before anything else.
     5. Read `make offload-log` over a few days. A day after rollout, `make sessions` again.
     6. The other dev repos pick this up when they bump `BASE_TAG`.
   - **Stage B gate — found in review of Stage A, 2026-10-02. All three are FIXED in v0.2.0**
     (issues closed upstream; #4 checked here against the very state that showed it — pid
     161 drops out of `doctor` while `/proc/161` still opens). **The checks below stay the
     gate**: they read what the deployed binary does, and a closed issue does not.
     - **A hook can lose its event to the offloader's lock** ([claude-sessions#1](https://github.com/gsfernandes81/claude-sessions/issues/1)). `offload` (dry run included)
       takes each slot's lock and reads all of `/proc` while holding it; `hook` waits only
       `SESSION_END_WAIT` (400 ms) for every event, then logs and drops it. A dropped
       `UserPromptSubmit` leaves a mid-turn claude reading as idle — in Stage B, killed ten
       minutes later unless a tool happens to be running. Fix upstream: snapshot `/proc`
       before locking, and have `--dry-run` not lock (it writes nothing). **Until then, any
       `hook.log` line saying a non-`SessionEnd` event lost the lock blocks Stage B.**
       *v0.2.0:* `/proc` is read before any lock, only a slot about to be stopped is
       locked, `--dry-run` locks nothing, and hook events other than `SessionEnd` wait 2 s.
       A `SessionEnd` losing the lock during an offload is still expected and not a fault.
       *v0.3.2:* the criterion is now read directly — `grep dropped
       ~/.local/share/claude-sessions/hook.log`, where each line names its event and a
       `SessionEnd`'s reason. **Any event other than `SessionEnd` dropped blocks Stage B.**
       **In Stage A the only expected `SessionEnd` drop is one at a menu `c` close the owner
       did** — `--dry-run` takes no lock, so nothing else holds a slot across a kill. Any other
       `SessionEnd (logout|prompt_input_exit|other) dropped` during the day is reported before
       Stage B: it would mean the eight v0.2.0 lines were not all `/clear`/`/resume` races, and
       whatever held the lock against a `SessionEnd` can hold it against a `Stop` or a prompt.
       `SessionEnd (clear)` or `(resume)` takes no lock in v0.3.2, so one appearing
       means the box is not running it. **First reading, 2026-10-04** on v0.3.4, 2026-10-03 17:56
       → 2026-10-04 12:50 (380 passes, none missed): **not enough data** — no slot was alive
       at any pass, so nothing was judged. The night, as the files explain it (2026-10-04):
       - **A 13 s Claude Code** (pid 1506, `claude-1`, 01:40:32–01:40:46, never prompted)
         whose `SessionEnd (other)` lost the slot's lock: what `n` then `c` looks like (v0.3.4
         reused the free name; a close holds the lock across the stop). The owner thinks
         that likely and cannot confirm it — **expected, not a blocker**.
       - **Its auto-update outlived it**: `npm install --global @anthropic-ai/claude-code@2.1.289`
         from 01:40:42 until **SIGHUP at 01:41:08** (`~/.npm/_logs/2026-10-04T01_40_42_627Z-debug-0.log`),
         after it had moved the installed package aside. npm rolled back — no `.claude-code-*`
         left, and later updates installed cleanly — but **a `c` close can interrupt Claude
         Code's self-update mid-install**, and a half-installed global package is every
         slot's `claude`. Recorded, not acted on.
       - **The "650 MB" was page cache, not a process**: `memory:` read 950 → 297 MB free from
         the 01:41:55 pass until 02:02:55, with nothing running — `hook.log` has no `not ours`
         line (every claude fires the managed hooks, so none ran outside a slot) and nothing
         else was written. The line is `memory.max − memory.current`, which counts cache (now
         892 MB "used", 515 MB of it `file`). Filed upstream as
         [claude-sessions#7](https://github.com/gsfernandes81/claude-sessions/issues/7),
         because `room_for` uses the same figure and Stage B would act on it.
       - **The menu dumped core into `/workspace` at 01:56:44** when its terminal went away
         ([claude-sessions#6](https://github.com/gsfernandes81/claude-sessions/issues/6), fixed
         in v0.3.7). Memory did not move then (301 MB free at 01:56:55 and 01:59:55). **Needs a day with slots in
       use, then a second reading** (that day also makes up for the 33 hours on v0.2.0).
     - **`claude.exe` counts as foreign work** ([#2](https://github.com/gsfernandes81/claude-sessions/issues/2)). `foreign_descendant` exempts only `claude`;
       the old script measured `claude.exe` helpers in live trees. If they reappear, every
       slot is held forever and nothing is offloaded. Check the dry-run log for persistent
       `claude.exe … is running under it` holds; the fix is one allow-list entry upstream.
       *v0.2.0:* `claude.exe` no longer holds a slot; `node` still does.
     - **A dead Claude Code sessions file reads as live** ([#4](https://github.com/gsfernandes81/claude-sessions/issues/4)). Claude Code writes
       `procStart` as a string, so `live.rs` never compares it and falls back to "the pid
       exists" — which a thread id satisfies (`/proc/<tid>` opens but is not listed). Seen in
       `make sessions`: a September bg session at pid 161, now a cloudflared thread. The
       offloader is unaffected (registry records only), but the menu Stage B makes the
       entrypoint lists dead sessions and `running_elsewhere` refuses to resume them. **Until
       fixed, a `doctor` line naming a pid that `ps` does not show blocks Stage B.**
     - **The sweep, armed upstream in v0.3.0 and dry here** (2026-10-03). Stage B arms it in
       the same step as the offloader, so every `sweep: WOULD KILL` line in `offload.log` gets
       read first: each names a daemon whose parent is not a `claude`, and **one the owner
       cannot account for blocks Stage B**. Since v0.3.4 the dry run applies the live sweep's
       ten-minute age check — a younger tree reads `would keep, too young` — so each `WOULD
       KILL` is one the live sweep would kill. (Lines from before v0.3.4 skipped the check;
       there only a daemon in about four or more consecutive passes counted.) `make verify`'s `agentview` line must read off
       on every container Stage B reaches.
     - **A slot never prompted is "resumable" with no conversation on disk** ([claude-sessions#5](https://github.com/gsfernandes81/claude-sessions/issues/5),
       found at the v0.3.2 bring-up, 2026-10-03). Claude Code writes a new session's
       transcript at its first prompt, but `offload` counts a slot resumable once `session_id`
       and `cwd` are *recorded*. Seen on infra-dev: `claude-2`, closed on 2026-10-02 before
       any prompt, was offered for `Enter`, and the resume exited in about a second with
       empty stderr and no `SessionStart`. In Stage B, v0.3.0's rule offloads a new slot left
       unprompted after 10 minutes, onto exactly that kind of row. Nothing is lost, but the
       menu offers a resume that cannot work. *v0.3.3:* such a slot is closed rather than
       offloaded, and a stopped slot with no transcript is not listed. *v0.3.4:* a conversation is a
       transcript with a reply or a typed prompt, so a `/clear`ed slot left idle is closed too.
       **The check:** a `would close` line is right only for a slot whose transcript is missing
       or holds no real exchange — a new slot never prompted, or a bare `/clear`; **a `would
       close` on a slot whose transcript holds a real exchange blocks Stage B** — it would mean
       the transcript path, or the exchange test, is wrong on that box. **One known
       exception, not a blocker:** the test counts a typed prompt only as a plain string not
       starting with `<`, so a prompt that is only a paste (`<pasted_content …>`) or an image,
       with no reply yet, is not a conversation — such a slot left idle reads `would close`
       and is still `claude --resume`-able (filed upstream). A record from before v0.3.3 has no
       `transcript_path`, so its path is derived from `$CLAUDE_CONFIG_DIR`: confirmed
       2026-10-03 (infra#3) to be `/home/dev/.claude` in the loop and in every slot on
       infra-dev, from the image `ENV`, with or3's `dev/` setting no override; of infra-dev's
       four records, the two that resolve are a prompted conversation (`claude-1`) and a
       `/clear`ed one written at the clear (`claude-3`), and the two that do not are new
       conversations never prompted.
     - Not a gate, and **fixed in v0.2.0**: `reconcile` could sweep a live socket started
       with combined abduco flags (`-fA`) ([#3](https://github.com/gsfernandes81/claude-sessions/issues/3)). It now reads flags
       getopt-style and sweeps nothing while any live abduco's session cannot be named; the
       entrypoint's "safe at any time" caveat is gone.
   - **Stage B — the swap, one commit:** the entrypoint loop drops `--dry-run` and its log
     (the binary keeps `offload.log` itself; delete `~/.local/share/claude-sessions-dry-run.log`,
     which grows unbounded until then), `offload-idle-claude.sh` is deleted with its
     `COPY`, its `make idle`/`offload-log` halves, `DEV_IDLE_OFFLOAD_SECONDS`/
     `DEV_IDLE_POLL_SECONDS` (entrypoint header, `compose.yaml`), `status.sh`'s exclusion and
     `procps` comment, the README's offloader section; the 90-minute `decisions.md` row is
     marked ⚠︎SUPERSEDED. Expect idle sessions to stop after 10 minutes, ssh ones included.
     If the live loop still pipes the command through anything (a timestamping `sed`), it
     reads the command's exit status from `${PIPESTATUS[0]}` on the next line and says when
     it failed. The Stage A loop reads no status at all — its `2>&1` keeps error text, but a
     `timeout` kill (124) or a silent non-zero exit leaves nothing — and `$?` after the pipe
     would be `sed`'s anyway.
   - ✔ **The orphan sweep was armed in claude-sessions v0.3.0** on 2026-10-03, earlier than
     the week of `offload.log` it was waiting on; here it stays dry until Stage B (gate
     above). The owner's 2026-10-08 reminder is now for reading those `WOULD KILL` lines.
6. **Switch the door** — `ansible/templates/ssh-dev-block.j2`'s RemoteCommand becomes
   `in-workspace claude-sessions-door`; the owner runs the client play from each client. Then
   **delete this plan.**
   - **The door itself landed 2026-10-02 at `2026.10.02.1`** — `dev/claude-sessions-door`,
     in the image beside `in-workspace`, to the contract in claude-sessions' `docs/design.md`
     § *The door*. Every branch was run before it was committed: a forwarded command, no
     tty, a menu exiting non-zero (one line, then `$SHELL -l`), and the real v0.2.0 menu in
     a 40×24 pty quit with `q` (exit 0, no shell).
   - ✔ **The template switched the same day**, for every alias at once on the owner's word
     (`decisions.md`), with `make claude`, the banners and the docs. **Owner's, in order:**
     recreate infra-dev on `2026.10.02.1` first (Phase 5 bring-up above, step 4a included),
     then re-run `client-home-ssh-config.yml` on each client. or3-dev, dd-dev and ds-dev answer
     `exec: claude-sessions-door: not found` until each repo bumps `BASE_TAG`; `<c>-sh`
     gets in meanwhile. **This plan is deleted** when the clients are re-run, the children
     have bumped, and Stage B has landed.
   - **The door moved into the container's sshd on 2026-10-04** (infra#7, `decisions.md`):
     `ForceCommand` in `dev/sshd_config`, a transport-only client block, forwarded commands
     in `~`. Landed at `2026.10.04.2`; reaches infra-dev as `2026.10.04.4`, with v0.3.8. **Owner's,
     in order:** wait for `dev-base.yml` to publish `2026.10.04.4` and recreate infra-dev (`ssh -t zero 'cd ~/infra/dev && make
     up'`); `make verify`'s `door` line reads `/usr/local/bin/claude-sessions-door`, not
     `none`. Before re-running any client, `ssh infra-dev` from the phone must still reach the
     menu — the old block's `RemoteCommand` arrives at the forced door and is run, which the
     throwaway-sshd test proved but a real client has not. Then re-run `client-home-ssh-config.yml`
     on each client, and on each: `ssh infra-dev` is the menu, `ssh infra-dev 'pwd'` prints
     `/home/dev`, `scp` of a file round-trips, **Zed's remote open to the bare alias works**
     (the one check the throwaway sshd could not run), and `ssh -t infra-dev in-workspace`
     is a shell in `/workspace`. or3's phone tunnel (`ssh -N -R` over `or3-dev-sh`) is
     unaffected throughout: `-N` opens no session, and `-sh` is still a name.

Phases 1 and 2 can run in parallel. Each phase lands on `main` complete and non-breaking.
A push to `main` touching `dev/` publishes a new base tag automatically; no container
picks it up until its repo's `BASE_TAG` is bumped, and **bringing containers up on a new
base is the owner's to do** (CLAUDE.md, *Privileged commands*). The entrypoint and every
file the base copies are build inputs, so each of those changes is a `BASE_TAG` bump.

### What "complete" has to touch

So that each phase meets CLAUDE.md's *complete*, these describe today's door, offloader or
agent view and must change with them:

- **infra:** `dev/README.md` (how the container is used, the idle offloader, the
  load-bearing things), `docs/ssh-clients.md`, the `ssh-dev-block.j2` header,
  `Dockerfile.base`'s header and the offloader `COPY`, `entrypoint.sh` (the offloader
  block, the daemon block, the closing `say` lines), `dev/compose.yaml`'s comment on the
  3600 s floor, `dev/Makefile` (`claude`, `idle`, `offload-log`), `dev/status.sh`,
  `dev/login.sh`, `dev/config.fish`.
- **children** (in their own repos, when they bump `BASE_TAG`): `or3/dev/Makefile` and
  README; destiny-director's `Makefile`, `CLAUDE.md`, `docker-compose.dev.yml`,
  `docs/pi_dev_setup.md`; dossier's `Makefile` and `CLAUDE.md`.
- **`docs/decisions.md` rows:** agent view off; `claude-sessions` is the door; source in its own
  repo with a pinned, checksummed release; the 10-minute threshold; the registry's
  location and locking; one binary.

## Taken by the owner, 2026-10-01

*(The marks named below — `u` among them — went in v0.3.3, which groups rows by state; an
unregistered session is now a row in `Idle`. The decisions themselves stand.)*

- The source lives in its own repo; the base pulls a pinned release.
- Offload threshold: 10 minutes after `Stop`, once timers are visible.
- No learning-material commenting requirement; ordinary comment density.
- The tool is called `claude-sessions`.
- Menu ages tick at most once a minute; otherwise the menu is silent.
- A slot with a pending timer is **never offloaded**, whoever set the timer; the menu marks
  it, so a forgotten `/loop` is visible and closable.

From the mockup review, same day — the three questions under `## Mockups`, each answered
*yes*, plus the glyphs:

- **The glyph set is Claude Code's own** — box drawing, `·` — **and its mode
  indicators are not**, which is the one part of that vocabulary the owner has seen fail.
  The marks column stays single-byte because the age is right-aligned against it. **`↵` is
  out too, for a measured reason rather than a judged one:** it is in no monospace face on
  Google Fonts, so it falls back and drags its line out of true wherever it is drawn. The
  key is spelled `Enter`. See the glyph paragraph under `## Mockups`.
- **`u` stays**: a session the launcher did not start is marked as such. It goes
  permanently blank once every client has re-run `client-home-ssh-config.yml`, and that is the
  right failure mode for a mark — the one time it is not blank is the time you want it.
- **`Enter` on an offloaded row resumes immediately, with no confirmation.** RAM is spent on
  what you open, in the order you open it. The honest consequence, accepted rather than
  designed around: near the cgroup limit, `Enter` can answer with the no-room offer for a
  *different* slot instead of the session you asked for.
- **The row's title is Claude Code's own session title** where the transcript carries one,
  else the first user prompt truncated; a row with a prompt waiting shows what the prompt
  is about instead, because that is the more useful thing to read at that moment. Titles
  are free text, so truncation is on display width, not bytes.
- **An unregistered row cannot be named, and will not be guessed at.** There is no session
  id to map to a transcript, so all there is to show is the abduco session name. Matching
  cwd and start time against `~/.claude` transcripts would work and is guesswork; it is
  worth building only if `u` rows turn out to persist, which the client re-run is meant to
  prevent.

## Answered 2026-10-01 — "is this not rebuilding what `claude --resume` gives us?"

The owner's question, and the right one to ask before any of this is built. The answer is in
the new repo's `docs/design.md` § *Why not just `claude --resume`*, and in short: three things,
each of which is a way to lose work rather than a convenience.

1. **`--resume` does not know what is running.** It lists conversations *on disk*; open one that
   is already live in another process and it **forks** — two transcripts, diverging, no warning.
   Knowing a row is live and **attaching** instead is the first thing a menu here must do, and
   nothing Claude Code keeps will tell you.
2. **What records a live session vanishes exactly when it matters.**
   `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` is pid-keyed and exists only while the process does;
   offload a slot and it is gone, which is precisely when you need to know which conversation
   belonged to it and in which directory.
3. **Nothing records attention or absence** — a waiting permission prompt, a pending timer, and
   **when you last looked**, which is the whole of `unread` and is a fact about the owner rather
   than about the session.

What the tool does *not* do is keep its own copy of what is cheap to read while a process is
alive: a live slot's busy flag comes from Claude Code's own file, and our stored copy is the
last-known value for when it is gone. (Its title did too, until v0.3.1 moved titles to the
transcript, read by the hook.)

## Deferred — maybe not needed

**A long-interval wake tool.** ScheduleWakeup clamps at an hour, and with timers pinning a
slot, a loop that wants to wait longer holds its RAM the whole time. A tool Claude could
call in place of ScheduleWakeup — "wake me in six hours with this prompt" — would let
`claude-sessions offload` stop the slot and resume it when due, replaying the prompt. Only worth
building if long waits turn out to be common; it needs Phase 0 to show a resumed session
accepts a replayed prompt.
