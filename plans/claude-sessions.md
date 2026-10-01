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

**Unregistered sessions:** until every client has re-run `configure-client.yml` (phone,
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
  (CLAUDE.md, *Verifying changes*): it ships logging what it *would* kill for a week, the
  owner reads that log, and only then is it enabled.

### 4. The launcher, `claude-sessions` — a Rust TUI

Reached through a door script, not directly: `claude-sessions-door` (in the image, beside
`in-workspace`) runs `claude-sessions`, and if it exits non-zero prints why and `exec "$SHELL" -l` —
`$SHELL`, because dd and dossier set the login shell to bash. Every lock `claude-sessions` takes has a
timeout, so a stuck lock cannot hold the door shut. `<c>-sh` remains the break-glass.

- **Lists open slots** — live and offloaded, never closed, plus unregistered abduco
  sessions. Order: needs you, then unread, then most recent activity. Each row: mark,
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
- **Shell:** `q` drops to a login shell in the workspace.
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
a real one, so the menu knows when to fall back to the first prompt.

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

## Mockups

**Not approved yet — Phase 2 is a gate, and this is what it is waiting on.** Rename this
heading to `## Mockups — approved by the owner on <date>` with the approval quoted, and
only then may a commit add ratatui, crossterm or any rendering code.

These are drawn at **40 columns**, the phone in portrait, and every line was generated to
that width rather than typed to look right. The 80-column versions are in
[`claude-sessions-mockups-80.md`](claude-sessions-mockups-80.md), separately, because at 40
they would wrap and stop being mockups.

**The glyphs are the ones Claude Code already draws** (owner, 2026-10-01): box drawing for
the rules and the dialog frames, `·` in the header, `↵` for the open key. They are East
Asian *Ambiguous* in the Unicode tables — one column in some terminals, two in others —
and the reason to use them anyway is evidence rather than taste: Claude Code renders this
exact set in every terminal this fleet is driven from. **Its mode indicators stay out**
(`⏵⏵` and the rest), which is the one part of that vocabulary the owner has seen fail.

**The marks column stays single-byte ASCII**, and that is not timidity about the rule above.
It is the one field whose width is load-bearing: the age is right-aligned against it, so a
mark that renders two columns wide pushes every age off the screen, while a rule that
renders wide is merely long. Mockup 8's narrowing demo keeps plain `=` rulers for the same
reason — the measured edge should be the one thing on the page that cannot itself be a
width question.

**One row is one slot**, and the repo is not in it: each container holds one workspace, so
the repo is a property of the header, not of the row. The row is slot number, marks, title,
age. Ages tick at most once a minute; nothing else redraws on its own.

**Marks** — `!` wants you (a permission prompt or an elicitation is waiting) · `*` unread
(it finished something while you were away) · `t` a timer is pending, so it is never
offloaded · `@` attached somewhere else as well · `z` offloaded, and Enter resumes it ·
`u` not started by `claude-sessions`, so it is one of today's `abduco -A claude` sessions.
The marks field holds three, which is the most that can be true at once and still be worth
reading.

**Open questions I would put to you with the drawings**, because they are the places I
guessed:

1. **Is `u` worth a column?** It matters only until every client has re-run
   `configure-client.yml`, and then it is permanently blank.
2. **Should `Enter` on an offloaded row resume immediately, or confirm first?** Drawn as
   immediate — RAM is only spent on what you open, which was the rule — but it is the one
   key that can cost 250 MB without asking.
3. **Is the title the right thing in the row?** Claude's own session title when there is
   one, else the first prompt truncated. Screen 1 shows both kinds mixed: row 1 is a
   permission prompt's subject, row 6 is an unregistered session with nothing to show but
   the command.

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
↵ open   n new   c close   ? keys
q shell
```

### Mockup 2 — Nothing open
```
infra-dev · nothing open · 812M of 1.0G
────────────────────────────────────────

  No claude session in this container.

  n   start one in /workspace
  q   a shell instead

────────────────────────────────────────
n new   ? keys   q shell
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
│ It is running. This stops it.        │
│ The conversation stays on disk, and  │
│ in claude --resume.                  │
│                                      │
│ y close    n keep                    │
╰──────────────────────────────────────╯
```

### Mockup 4 — No room to open another
```
╭──────────────────────────────────────╮
│ Not enough room for another claude   │
│                                      │
│ 892M of 1.0G used in this container. │
│ A new session wants about 250M.      │
│                                      │
│ Offload slot 5, idle 2d?             │
│   mount guards on one                │
│                                      │
│ Its conversation is kept. It comes   │
│ back with claude --resume, and the   │
│ menu will say so.                    │
│                                      │
│ y offload, then open    n cancel     │
╰──────────────────────────────────────╯
```

### Mockup 5 — A resume that fails
```
╭──────────────────────────────────────╮
│ Slot 5 did not resume                │
│                                      │
│ claude --resume 0f9c4a1e exited 1    │
│   No conversation found with that    │
│   session id                         │
│                                      │
│ The slot is left offloaded and       │
│ nothing was deleted. Its transcript  │
│ may have been cleaned up by Claude.  │
│                                      │
│ r retry   c close it   ↵ back        │
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
↵ open   n new   c close   ? keys
q shell
```

### Mockup 7 — The keys, on ?
```
infra-dev · keys and marks
────────────────────────────────────────
↵      open the row (resume if z)
n      new session in /workspace
c      close the row
q      drop to a shell
?      this

!  wants you: a prompt is waiting
*  unread: it finished while away
t  a timer is pending; never
   offloaded while one is
@  attached somewhere else too
z  offloaded: ↵ resumes it
u  not started by claude-sessions
────────────────────────────────────────
↵ open   n new   c close   ? keys
q shell
```

### Mockup 8 — The hint line as the terminal narrows
```
at 40 columns, the right edge marked:
========================================
↵ open   n new   c close   ? keys
q shell
at 34 columns, the right edge marked:
==================================
↵ open   n new   c close   ? keys
q shell
at 26 columns, the right edge marked:
==========================
↵ open   n new   c close
? keys   q shell
at 18 columns, the right edge marked:
==================
↵ open   n new
c close   ? keys
q shell
at 12 columns, the right edge marked:
============
↵ open
n new
c close
? keys
q shell
at 9 columns, the right edge marked:
=========
↵ open
n new
c close
? keys
q shell
at 7 columns, the right edge marked:
=======
↵ open
n new
c close
? keys
q shell
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
2. **Mockups — OWNER APPROVAL GATE. Drafted 2026-10-01; waiting on your word.** They are
   inline under [`## Mockups`](#mockups), with three questions I guessed at.
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
3. **Registry, `claude-sessions hook`, `claude-sessions reconcile`** — the state machine, unit-tested over the
   event table above, including `/clear`, resume, offload-then-`SessionEnd`, a nested
   claude, an idle-prompt notification, container restart, and two writers at once; plus
   the always-exit-0 test.
4. **The TUI**, to the approved mockups. Rendering tested at 40×24 and 80×24 against a test
   backend; the zero-idle-bytes property tested under a pty; ordering and the guards
   unit-tested.
5. **`claude-sessions offload`** replaces `offload-idle-claude.sh` (deleted in the same commit). The
   orphan sweep ships dry-run, logging, and is armed only after the owner has read a
   week of its log.
6. **Switch the door** — `ansible/templates/ssh-dev-block.j2`'s RemoteCommand becomes
   `in-workspace claude-sessions-door`; the owner runs the client play from each client. Then
   **delete this plan.**

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

- The source lives in its own repo; the base pulls a pinned release.
- Offload threshold: 10 minutes after `Stop`, once timers are visible.
- No learning-material commenting requirement; ordinary comment density.
- The tool is called `claude-sessions`.
- Menu ages tick at most once a minute; otherwise the menu is silent.
- A slot with a pending timer is **never offloaded**, whoever set the timer; the menu marks
  it, so a forgotten `/loop` is visible and closable.

## Deferred — maybe not needed

**A long-interval wake tool.** ScheduleWakeup clamps at an hour, and with timers pinning a
slot, a loop that wants to wait longer holds its RAM the whole time. A tool Claude could
call in place of ScheduleWakeup — "wake me in six hours with this prompt" — would let
`claude-sessions offload` stop the slot and resume it when due, replaying the prompt. Only worth
building if long waits turn out to be common; it needs Phase 0 to show a resumed session
accepts a replayed prompt.
