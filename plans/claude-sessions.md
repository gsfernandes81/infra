# Claude sessions in the dev containers: cheap when idle, findable after a disconnect

**Status: proposal, not taken.** Nothing here is decided until the owner says so; each
decision moves to [`docs/decisions.md`](../docs/decisions.md) in the commit that makes it.
**Phase 2 is a hard gate:** no TUI code is written until the owner has approved mockups.

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

**Not in scope:** merging the per-repo containers (this works for either layout — the
"new session" flow asks for a repo when there is more than one); cloud sessions
(claude.ai/code); anything on the phone side beyond the ssh config the client play
already writes.

## Design

### 1. The agent view is off fleet-wide

`disableAgentView: true` in **managed settings** baked into the base
(`/etc/claude-code/managed-settings.json`, or a file in `managed-settings.d/` — check
which the installed version reads), so neither a repo's `.claude/settings.json` nor a
user setting can turn it back on. `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` in the image's ENV as
well is optional belt-and-braces; the entrypoint already publishes ENV to ssh sessions
via `~/.ssh/environment`. Cost: `claude --bg`/`claude agents` are unavailable in these
containers, which is the point.

### 2. Slots, sessions and the registry

A **slot** is one abduco session (name `cc-<n>`), i.e. one running claude process. A slot
holds a sequence of **conversations** (Claude session ids): `/clear` starts a new one in the
same process, `--resume` re-enters an old one. The registry is keyed by slot and records,
per slot:

`slot` · `pid` (+ start time, so a reused pid is never mistaken) · `session_id` (current) ·
`cwd` / repo · `title` · `state` · `last_activity` · `needs_you` · `pending_wake`

States: **attached** / **detached** (from abduco's listing, never stored) · **offloaded** ·
**closed**. Stored where it survives a container restart: a directory beside the Claude
config in the persisted `.claude` volume (not inside `projects/`, which this tooling never
writes). After a restart every slot whose pid is gone reads as **offloaded** — nothing is
lost, it just needs resuming.

**Hooks write it,** configured in the same managed settings so every repo gets them without
touching its `.claude/`. One fast binary (`cs hook`, below) reads the hook's JSON on stdin:

| event | registry effect |
|---|---|
| `SessionStart` (source startup / resume / clear / compact) | bind `session_id` and `cwd` to this slot; state live |
| `UserPromptSubmit` | `last_activity = now`, busy, clear `needs_you` |
| `Stop` | `last_activity = now`, idle-since now |
| `Notification` | `needs_you` (permission prompt or idle prompt) — never offloaded while set |
| `PostToolUse` on ScheduleWakeup / CronCreate / CronDelete | record or clear `pending_wake` |
| `SessionEnd` | `closed` — **unless** the slot is marked `offloading`, in which case `offloaded` |

The hook finds its slot by walking up from its own parent to the first `claude` process and
from there to its abduco server. This also fixes the current offloader's admitted
weakness: it cannot tie a transcript to a process and judges by "newest file in the cwd".

**Title:** Claude's own session title if the transcript carries one (summary / `/rename`),
else the first user prompt, truncated. Phase 0 confirms where that lives.

### 3. The offloader, rewritten as `cs offload`

Same contract as today — never an attached slot, never one with work running under it,
never without evidence — with the hook state replacing the transcript clock:

- Offloadable when: detached, `Stop` is the latest event, no `needs_you`, no
  `pending_wake`, no non-claude descendants, idle past the threshold.
- The threshold drops from 90 min to **10 min** (owner to confirm). The hour floor existed
  only because self-scheduled wake-ups were invisible; `pending_wake` makes them visible.
- Marks the slot `offloading` **before** signalling, then `offloaded` after; keeps the
  TERM → grace → KILL → abduco teardown and the pid-plus-start-time checks of the current
  script.
- Also sweeps orphaned `daemon run` / `bg-spare` / `bg-pty-host` trees whose spawning
  session is gone (defence in depth now that the agent view is off).

### 4. The launcher, `cs` — a Rust TUI

Replaces `abduco -A claude claude` as the RemoteCommand, so every `ssh <c>` lands in it.

- **Lists open slots** — live and offloaded, never closed. Order: needs you, then most
  recent activity. Each row: mark, repo, title, age. Marks: needs you · attached elsewhere ·
  offloaded (glyphs settled in the mockups).
- **Opening a row:** live → `abduco -a` it; offloaded → start a new slot running
  `claude --resume <session_id>` in its cwd. **Nothing is ever resumed automatically:**
  RAM is spent on what the owner opens, in the order they open it.
- **Guards:** never resume a session id that is already running in another slot (two
  processes on one conversation fork it). When `MemAvailable` is low, offer to offload the
  longest-idle detached slot before starting another.
- **New session:** `n`; asks for a repo only when the container holds more than one.
- **Close:** `c` on a row marks it closed (and stops it if live, after a confirm). The
  conversation stays on disk and in `claude --resume`.
- **Shell:** `q` drops to a login shell in the workspace.
- **Data discipline:** the screen redraws on keypress or a registry change, never on a
  timer; ages are refreshed at most once a minute, or only on keypress. **An idle menu
  emits zero bytes** — the property `ytq`'s marquee was built to, and tested the same way.
- **Width:** usable at 40 columns (Termux portrait) up; no ambiguous-width glyphs.
- **Startup:** fast enough to be invisible on every ssh (target < 100 ms on `zero`).
- **If `cs` itself fails,** the RemoteCommand falls through to a login shell rather than
  closing the connection; `<c>-sh` remains the documented break-glass.

### 5. Ending a session

- **`/exit`** ends it: the process exits, abduco goes with it, `SessionEnd` marks the slot
  closed.
- **`/clear` does not.** It starts a new conversation in the same process — right for "same
  session, new task", wrong for "done". The registry follows it via `SessionStart`.
- **`c` in the launcher** closes without opening (for something offloaded last week).
- Stale slots are never closed automatically; they sort to the bottom.

### 6. One binary, built outside this repo

`cs` (menu, default), `cs hook`, `cs offload`, `cs close`: one Rust binary, so the hook
path, the offloader and the menu share one registry implementation and one set of tests.

**Where the source lives is an owner decision** (see Open questions). This repo is
"config only — no source", so the recommendation is a **separate repo** that publishes
static (musl) arm64 + amd64 binaries as releases, and `Dockerfile.base` downloads a
**pinned** release with its checksum — the same shape as dd's pinned Railway CLI. Build by
cross-compiling on the runner, not under QEMU, which is how the base's arm64 layer is
built today and would be very slow for Rust.

## Phases

0. **Verify on `zero` before building** (read-only, owner runs anything needing the host):
   - re-measure an idle session and one after **←**, with the real login;
   - capture each hook event's real stdin payload once (a logging hook in a scratch
     container), including `SessionEnd`'s reason values and whether it fires on SIGTERM;
   - confirm `--resume` keeps the session id, and whether abduco allows two clients on one
     session and what each sees;
   - find where the session title lives in a transcript.
   Findings go into this plan before Phase 3.
1. **Agent view off** — managed settings in `Dockerfile.base`, `BASE_TAG` bump, a
   `decisions.md` row, `dev/README.md` updated. One-time cleanup in each container: check
   `claude agents --json` for real background sessions, then `claude daemon stop --any`.
   Independent of everything below; can ship first.
2. **Mockups — OWNER APPROVAL GATE.** Before any TUI code, give the owner plain-text
   mockups at **40 columns** (and 80), drawn as they would actually render, covering:
   the list with every state mixed (needs you, attached elsewhere, detached, offloaded);
   the empty list; the new-session repo picker; the close confirmation; the low-memory
   offer; a resume that fails; the narrowest width at which the hint line still shows a
   way out. Iterate until the owner approves; record the approved mockups in the new
   repo's docs. **Do not start Phase 4 without that approval.**
3. **Registry + `cs hook`** — the state machine, unit-tested over the event table above
   (including `/clear`, resume, offload-then-`SessionEnd`, container restart).
4. **The TUI**, to the approved mockups. Rendering tested at 40×24 and 80×24 against a
   test backend; the zero-idle-bytes property tested under a pty; ordering and the guards
   unit-tested.
5. **`cs offload`** replaces `offload-idle-claude.sh` (deleted in the same commit), with the
   orphan sweep. Dry-run mode kept.
6. **Switch the door** — `ansible/templates/ssh-dev-block.j2`'s RemoteCommand becomes
   `in-workspace cs`; `docs/ssh-clients.md`, `dev/README.md` and the base header updated;
   `decisions.md` rows for each decision taken. The owner runs the client play from the
   phone. Then **delete this plan.**

Phases 1 and 2 can run in parallel. Each phase lands on `main` complete and non-breaking.
A push to `main` touching `dev/` publishes a new base tag automatically; no container
picks it up until its repo's `BASE_TAG` is bumped, and **bringing containers up on a new
base is the owner's to do** (CLAUDE.md, *Privileged commands*).

## Open questions for the owner

1. Where the Rust source lives (recommended: its own repo, binaries pulled into the base
   by pinned release).
2. The offload threshold once wake-ups are visible (proposed: 10 min).
3. Whether a slot with a pending wake-up may ever be offloaded (proposed: never).
4. Whether the code should double as Rust learning material, with commenting to match, as
   dossier's rewrite does (`REWRITE.md` D2).
5. Whether ages on the menu tick (≤ 1 redraw a minute) or update only on keypress.
