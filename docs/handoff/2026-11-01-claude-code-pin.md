# Handoff 2026-11-01: Claude Code pinned at 2.1.311, claude-sessions 0.18.1 (the remote view, agent messaging) — on zero since 2026-11-07

**First orders for the next session: read this, say where things stand, and stop.** Items 2
and 3 run on zero and are the owner's to start. Item 4 is the remote view, on each client.

## Where it stands

On `main`: the hub pins claude-sessions 0.18.1, and base `2026.11.06` installs Claude Code
2.1.311 with updates off and a version ceiling (dev-base and dev-smoke green on `f08d6b1`, and
again on `ec1fd7e` with 0.11.0 and on `e1af926` with 0.13.1, where the smoke test ran `relay` through the hub's sshd, and on `a4ead3e` with 0.13.2), both in `dev/claude-managed-settings.json`. The reasons are the pin row in
[`decisions.md`](../decisions.md). How it is read is in [`dev/README.md`](../../dev/README.md)
§ *Claude Code in here*. The version was chosen by claude-sessions' agent (mail, 2026-11-01).

## Open

1. **The deploy. Closed 2026-11-07:** 0.18.1 on base `2026.11.06`, by the recreate play. This
   also closes the pi-harness handoff's items 2, 3, 7 and 10 once their checks read right.
2. **`make verify` on zero. Skipped 2026-11-07, the owner's call:** the deploy came up and
   messaging worked, and CI's smoke run reads the same lines.
3. **The ceiling. Closed 2026-11-07:** 2.1.316, run with no login in `infra`, refused to start
   naming the organization's maximum (2.1.311); the pin row, the README and status.sh say so.
   `dev/Dockerfile.base` still calls it "not yet seen on a box" in a comment, left for the
   next base bump, since editing the base alone would force one.
4. **The remote view (claude-sessions 0.18.1).** The phone's client is on the pin: the owner ran
   `client-home-claude-remote.yml` there after the deploy, on 2026-11-07. Left: the same play
   in WSL (`cd ~/infra/ansible; ansible-playbook playbooks/client-home-claude-remote.yml`),
   and nothing else here: `/rc` in a remote-view session worked on an earlier build (owner,
   2026-11-07). Still open upstream: claude-sessions is to measure cloudflared's idle
   timeout from Termux, which may move the client's `ServerAliveInterval` from 30 to 60, and
   that is the owner's call.

5. **Agent messaging. Closed 2026-11-07:** the first fleet run listed the other containers'
   slots in `ListAgents`, and a message from claude-sessions crossed to infra and the reply went
   back. The owner removed the `dev-policy` container, the `mail-token` files and the
   `dev_mail` and `dev_policy` volumes.

This note is deleted when all five are closed. Its reasoning is already in the pin row and
the *Agent messaging* section.
