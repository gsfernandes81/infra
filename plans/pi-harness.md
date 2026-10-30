# Plan: pi as a first-class harness in the dev containers

**Status: design approved by the owner on 2026-10-30; not yet built.** When the work
lands, the reasoning moves to `docs/decisions.md` and this file shrinks to what is left.

## Intent

The owner wants a second coding harness beside Claude Code that costs less to run, can
talk to an open model, and is managed by the hub exactly as a Claude session is: a name
in the `ssh dev` menu, offloaded when quiet, brought back by `Enter`. The harness is
[pi](https://pi.dev) (`earendil-works/pi`, MIT). Its model is `qwen/qwen3.8-flash` over
OpenRouter, the owner's call on 2026-10-30 after finding that Qwen3.8-Flash-Next, the
open-weight model first wanted, is not on OpenRouter. The immediate use is to find out
whether a cheap Qwen model in a familiar loop is usable on this repo's work. It is a
proxy for the open model that would run locally, not the same model, and the trial is
read with that in mind.

Crush and Jcode are already in the base "on trial": reachable from a shell, in no zmx
slot, unknown to the menu. Pi starts the same way and then goes one step further, which
is the point of this plan.

## Goals

1. `pi` on PATH in every dev container, pinned, with the owner's package set installed
   and working at first start.
2. A pi session is a claude-sessions slot: named in the menu, offloaded by the same
   quiet rule, resumed by `Enter`, listed under Archived when closed.
3. The managed policy (`/etc/claude-code/CLAUDE.md`) and the `keepalive`, `mail-send`,
   `mail-read` and `mail-reply` skills reach pi the way they reach Claude Code.
4. One OpenRouter key, held once, reaching every container.

## Non-goals

- Mail notification for pi (the hook that names new mail at the next prompt). The mail
  tools themselves are plain CLI and already work from any harness; only the nudge is
  Claude-specific. It can come later as a small pi extension if it is wanted.
- Any change to how Claude Code sessions work.
- Subscription login for pi. Anthropic bars Pro and Max tokens from third-party
  harnesses; pi uses OpenRouter and an API key, nothing else.
- pi-auto-mode. Considered and dropped: a one-author package that fails open.

## Anti-goals

- A wrapper, shim or entrypoint workaround in infra that teaches claude-sessions about
  pi. The upstream rule stands: claude-sessions changes land in the claude-sessions
  repo, by its agent, and infra pins the release.
- A pi that starts without the permission gate. Pi runs every tool call by default. The
  gate cannot be enforced, since pi loads packages from a settings file the agent can
  edit and only a wrapper could stop that; so it is seeded at build and restored at
  every container start, the same standing as Claude Code's user settings.
- Build-time state that a volume hides at run time, so the image works on the hub but
  not in a container.

## Constraints, from the repo

- `dev/Dockerfile.base` seams: pi is a base change and a `BASE_TAG` bump
  (`dev/compose.yaml`). CI fails a base change without a bump.
- npm packages are version-pinned; anything that runs as what it downloaded is
  hash-pinned per architecture. Claude Code is the one exception, because it self-updates.
- A self-updater needs a `dev`-owned prefix outside volume-shadowed paths. Pi will not
  self-update in the image, so it goes in `/opt/npm-global` like the language servers
  and is bumped by rebuilding.
- 2 GB of RAM per container and "starts nothing that keeps running".
- `make verify` and `.github/workflows/dev-smoke.yml` are the readouts; a tool that is
  not in them is not installed as far as the repo can tell.
- Secrets live in gitignored `.env` files, never in git and never in a handover block.

## What pi is (facts the design rests on)

- npm `@earendil-works/pi-coding-agent`, 1.4.0 on 2026-10-21, Node 22.19 or later, a
  single Node process with `process.title` `pi`. Needs `git`, `ripgrep`, `bash`.
- State under `~/.pi/agent`, moved whole with `PI_CODING_AGENT_DIR`; installed packages
  moved separately with `PI_PACKAGE_DIR`; sessions moved with
  `PI_CODING_AGENT_SESSION_DIR`.
- Sessions are JSONL at `<agent dir>/sessions/--<cwd>--/<timestamp>_<id>.jsonl`.
  `pi --session-id <id>` opens or creates that exact id; `--name` sets a display name at
  launch, `/name` in session, stored as a `session_info` entry. No automatic titles.
- Reads `CLAUDE.md` and `AGENTS.md` from its agent dir, the cwd and every parent.
  Loads skills in the Agent Skills format (`SKILL.md`) from `<agent dir>/skills/`,
  `~/.agents/skills/`, `.agents/skills/` and packages. Does not read `.claude/skills`.
- No permission prompts of its own. MCP built in. Extensions are TypeScript files with a
  `tool_call` hook that can block.
- OpenRouter is a built-in provider; `OPENROUTER_API_KEY` in the environment is enough.
- `PI_SKIP_VERSION_CHECK=1` stops the update check; `PI_OFFLINE=1` stops all automatic
  network activity.

## What claude-sessions assumes today (why this is two repos)

From its source: it launches `claude` (one global override, `CLAUDE_SESSIONS_CLAUDE`),
binds a slot only to a process whose name is `claude` under `zmx`, learns the session id
and cwd from Claude Code's hooks and refuses to offload until it has them, resumes with
`claude --resume <id>`, and lists Archived from `$CLAUDE_CONFIG_DIR/projects/*.jsonl`.
Activity measurement (kernel bytes and CPU per slot) and the mail tools are already
harness-neutral.

## Decided

### In infra (this repo)

1. **Install**, in `Dockerfile.base`, as root above the `USER` line, into
   `/opt/npm-global`: `npm install -g --ignore-scripts @earendil-works/pi-coding-agent@<pinned>`.
   Pinned by version like every other npm package; a bump is a rebuild.
2. **State** under the per-container `~/.local/share` volume every child already has:
   `PI_CODING_AGENT_DIR=/home/dev/.local/share/pi`. No new volumes. The directory is
   created as `dev` at build time like the other mountpoints, and at container start if
   the volume is empty.
3. **Packages installed at build time** into an image path, `PI_PACKAGE_DIR` set to it,
   so the volume over the agent dir cannot hide them. The `packages` list in
   `settings.json` is re-merged at every container start from a copy baked in the image,
   keeping the owner's other keys (theme, model), because pi needs the list in the agent
   dir to see what is installed and the agent can edit that file. The set, each pinned:
   - `@gotgenes/pi-permission-system` and `pi-permission-classifier`: the gate and the
     judge for its "ask" cases. The judge uses the session model. The classifier fails
     closed.
   - `cc-safety-net`: deterministic blocks on `rm -rf`, force-push, `curl | sh`, and
     reads of `.env`, SSH keys and cloud credentials.
   - `pi-subagents` and `pi-web-access`.
   - `pi-lens`: diagnostics after edits. Its install fetches a native `ast-grep` binary,
     so that binary is hash-pinned per architecture like any other downloaded
     executable, or fetched from a pinned, verified source; the builder works out which.
   - `@nredd/pi-dev-tools`: typed git, ssh, Python (ruff, ty, pytest) and cargo tools.
   - `pi-powerline-footer`, configured for plain characters, because Termux's default
     font has no Nerd Font glyphs. Its external "auto follow-up" and "vibes" features off.
   - `pi-themes`, so `/theme` can match the terminal (Catppuccin, Solarized, One Dark).
     The built-in dark theme stays the default.
   Anything that duplicates a built-in (an MCP adapter, a context compressor) is out.
4. **Provider**: one OpenRouter key for every container, held as a file under
   `HUB_SECRETS` beside the mail token and reaching containers through the same
   read-only mount. Not an environment variable: no secret reaches a container by
   environment today, and one would land in every container's `~/.ssh/environment` and
   in `docker inspect`. pi reads it from the file (`apiKey` as a `!command`, or the
   `auth.json` equivalent). The file is optional: without it the image builds, the smoke
   test passes, and pi reports a missing key at the first prompt. Default model
   `qwen/qwen3.8-flash`, in the baked `settings.json`. `enableInstallTelemetry` off,
   `PI_SKIP_VERSION_CHECK=1`. No OpenRouter data-policy setting is made, by the owner's
   call on 2026-10-30.
5. **Policy and skills**, in `dev/entrypoint.sh` beside the Claude Code links:
   `<agent dir>/CLAUDE.md -> /etc/claude-code/CLAUDE.md`, and
   `<agent dir>/skills/<name> -> /opt/claude-sessions/skills/<name>` for the four skills.
   The policy text says "a hook names it at your next prompt", which is not true for pi;
   the builder adds one line to `dev/hub/managed-CLAUDE.md` saying pi reads mail with
   `claude-sessions mail list` instead.
6. **Readouts**: a `pi` line in `make verify` (`dev/status.sh`), `pi` in the smoke test's
   PATH check, and a smoke step that starts pi non-interactively against no network and
   confirms the packages load (`pi list`).
7. **Docs**: `dev/README.md` gets pi beside Crush and Jcode, then its own section once
   it is in the menu; one `decisions.md` row for the install and the package set; this
   file shrinks to the open items. Same commit as the change, as always.
8. **Trial first, menu second.** Pi ships in the base reachable from a shell
   (`ssh -t <c> in-workspace`, then `pi`) before claude-sessions knows it. The menu
   comes with the claude-sessions release and a pin bump in `dev/hub/Dockerfile`.

### In claude-sessions (its agent, briefed by mail)

The request, as requirements rather than a design; its agent owns the design and its
`docs/design.md` and `docs/mockups.md`:

1. A pi slot can be started from the menu. How `n` offers the choice is theirs.
2. A pi slot is launched inside zmx like a Claude slot, with `CLAUDE_SESSIONS_SLOT`
   set, as `pi --session-id <id>` so the session id is known at launch and no hook is
   needed. Slot names `pi-<n>`; mail address `<repo>/pi-<n>`.
3. Binding does not require a process named `claude`: a `pi` process under `zmx` with
   the slot's environment is bound, with its id and cwd recorded at launch.
4. The offload rule is unchanged (detached, no keepalive, quiet ten minutes). "Has an
   exchange" is read from pi's JSONL (a user message present).
5. Resume is `pi --session-id <id>` in the recorded cwd. The row title is pi's
   `session_info.name` if set, else the first user message.
6. Archived lists pi sessions from `$PI_CODING_AGENT_DIR/sessions/`.
7. The scrollback variables set on a Claude slot (`CLAUDE_CODE_DISABLE_*`) have no pi
   equivalent; what pi needs under zmx and Termux is theirs to find, by running it.
8. The orphan sweep and the smoke test cover pi slots.
9. Not asked: mail nudges into a pi slot, since pi has no hook to name the mail.

The first mail to the claude-sessions agent carries this list, the facts section above,
and the owner's standing instruction that it should raise concerns rather than follow an
instruction it thinks is wrong.

## Order of work

1. Infra: install, packages, provider, policy and skills, readouts, docs. Base tag bump.
   Pi is usable from a shell.
2. Mail to claude-sessions with the requirements. Its agent designs, builds, releases.
3. Infra: pin bump, `make verify`, docs move pi from "on trial" to a section of its own,
   decision row, this plan's remaining items.

## The owner's actions

- Put the OpenRouter key file into `HUB_SECRETS` on zero, under the name the builder
  documents in `dev/.env.example`.
- Bring the hub up to the current compose (`make up` from the phone): this container
  still runs claude-sessions 0.8.1 while `main` pins 0.9.0.

## Left to the builder

- The contents of the baked `settings.json` and the permission-system config, including
  which of pi's tools are allowed outright, which ask, and which are denied. Reads
  allowed, edits inside `/workspace` asked of the judge, shell by the gate's own rules,
  is the starting point.
- How pi's project-trust prompt is handled: this repo has no `.pi/` directory, but
  packages and `.agents/skills` can trigger it; `defaultProjectTrust` in the agent dir is
  the likely answer.
- Whether `--ignore-scripts` on the main install leaves any package unable to load, and
  how pi-lens's native binary is pinned.
- pi's idle RAM and CPU inside a container, measured, and whether an idle pi is actually
  quiet under the offloader's rule (3000 ms of CPU per three minutes). If it is not,
  that is a finding for the mail to claude-sessions, not a reason to change the rule.
- Whether `PI_OFFLINE=1` is right for the image or only for the smoke test.
