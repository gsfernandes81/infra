# Handoff 2026-11-01: Claude Code pinned at 2.1.311, claude-sessions 0.11.0 (the remote view) — on main, not yet on zero

**First orders for the next session: read this, say where things stand, and stop.** Items 1 to
3 change zero and are the owner's to start. Item 4 is the remote view, on zero and then on each client.

## Where it stands

On `main`: the hub pins claude-sessions 0.11.0, and base `2026.11.01` installs Claude Code
2.1.311 with updates off and a version ceiling (dev-base and dev-smoke green on `f08d6b1`; the
0.11.0 pin has its own smoke run), both in `dev/claude-managed-settings.json`. The reasons are the pin row in
[`decisions.md`](../decisions.md). How it is read is in [`dev/README.md`](../../dev/README.md)
§ *Claude Code in here*. The version was chosen by claude-sessions' agent (mail, 2026-11-01).

## Open

1. **The deploy**, from the phone: the recreate play, as in the pi-harness handoff's item 2.
   It rebuilds the hub with 0.11.0 and recreates every container on `2026.11.01`, and every
   session ends. That also closes that handoff's items 2, 3, 7 and 10 once their checks read
   right.
2. **`make verify` on zero** (`ssh -t zero 'cd ~/infra/dev && make verify'`). Expected:
   `claudepin : 2.1.311, the pin`, `autoupdate: off by DISABLE_UPDATES — …`, and
   claude-sessions `0.11.0` at the hub and in each container.
3. **The ceiling, proved once.** `requiredMaximumVersion` was read from the binary and never
   seen to refuse a start (writing the managed file needs root). The test that touches
   nothing on PATH, untested as written: in one rebuilt container, `npm pack
   @anthropic-ai/claude-code-linux-arm64@2.1.316` into a temp directory, unpack it, and run
   the `claude` binary inside it with a prompt (`-p hi`). Expected: it exits at start with a
   message naming the organization's requiredMaximumVersion. `claude install` is the other
   route, but it may refuse under DISABLE_UPDATES, and it would put a binary first on PATH
   that then has to be removed. Once seen, drop "not yet seen on a box" from the pin row,
   the README, Dockerfile.base and status.sh.
4. **The remote view (claude-sessions 0.11.0).** Pinned in the hub on `main`, with a `relay`
   line in `make verify` and a smoke check through the hub's sshd. After the deploy:
   `make verify` should read `relay: claude-sessions 0.11.0`. Then, on the phone (and in WSL),
   `cd ~/infra/ansible; ansible-playbook playbooks/client-home-claude-remote.yml`, then
   `claude-remote dev`. It has never run on Termux, so the first run proves a static musl
   binary starts on Android: the play asserts `claude-remote --version` reads the pin. Still
   open upstream: claude-sessions is to measure cloudflared's idle timeout from Termux, which
   may move the client's `ServerAliveInterval` from 30 to 60, and that is the owner's call.

This note is deleted when all four are closed. Its reasoning is already in the pin row.
