# Handoff 2026-11-01: Claude Code pinned at 2.1.311, claude-sessions 0.10.1 — on main, not yet on zero

**First orders for the next session: read this, say where things stand, and stop.** Items 1 to
3 change zero and are the owner's to start. Item 4 waits on claude-sessions.

## Where it stands

On `main` and green in CI (dev-base and dev-smoke on `f08d6b1`): the hub pins claude-sessions
0.10.1, and base `2026.11.01` installs Claude Code 2.1.311 with updates off and a version
ceiling, both in `dev/claude-managed-settings.json`. The reasons are the pin row in
[`decisions.md`](../decisions.md). How it is read is in [`dev/README.md`](../../dev/README.md)
§ *Claude Code in here*. The version was chosen by claude-sessions' agent (mail, 2026-11-01).

## Open

1. **The deploy**, from the phone: the recreate play, as in the pi-harness handoff's item 2.
   It rebuilds the hub with 0.10.1 and recreates every container on `2026.11.01`, and every
   session ends. That also closes that handoff's items 2, 3, 7 and 10 once their checks read
   right.
2. **`make verify` on zero** (`ssh -t zero 'cd ~/infra/dev && make verify'`). Expected:
   `claudepin : 2.1.311, the pin`, `autoupdate: off by DISABLE_UPDATES — …`, and
   claude-sessions `0.10.1` at the hub and in each container.
3. **The ceiling, proved once.** `requiredMaximumVersion` was read from the binary and never
   seen to refuse a start (writing the managed file needs root). The test that touches
   nothing on PATH, untested as written: in one rebuilt container, `npm pack
   @anthropic-ai/claude-code-linux-arm64@2.1.316` into a temp directory, unpack it, and run
   the `claude` binary inside it with a prompt (`-p hi`). Expected: it exits at start with a
   message naming the organization's requiredMaximumVersion. `claude install` is the other
   route, but it may refuse under DISABLE_UPDATES, and it would put a binary first on PATH
   that then has to be removed. Once seen, drop "not yet seen on a box" from the pin row,
   the README, Dockerfile.base and status.sh.
4. **The client-side TUI is claude-sessions' project.** Infra's queue for its relay/view
   release: the hub pin bump; a `make verify` line running `ssh -T dev claude-sessions relay
   --version` through the door; and the static client binary, checked against SHA256SUMS, in
   the client-home plays for Termux and WSL. The door already passes a command through,
   compression is on at both ends, and the client's `Host dev` block needs nothing, except
   possibly `ServerAliveInterval` 30 → 60. That is the owner's call once claude-sessions has
   measured the cloudflared hop's idle timeout from Termux.

This note is deleted when all four are closed. Its reasoning is already in the pin row.
