# Handoff 2026-11-01: Claude Code pinned at 2.1.311, claude-sessions 0.19.2 (the remote view, agent messaging) — 0.18.1 on zero since 2026-11-07, 0.19.2 on main

**First orders for the next session: read this, say where things stand, and stop.** Items 2
and 3 run on zero and are the owner's to start. Item 4 is the remote view, on each client.

## Where it stands

On `main`: the hub pins claude-sessions 0.19.2 (waking with a check of zero's memory, the `peer-context` hook, swap beside RAM in the status lines, peers listed with their conversation's title, and messages within a container through the hub), which reaches zero at the owner's next deploy, and 0.18.4, 0.18.5 and 0.19.2 change the remote view's client too (item 4); and base `2026.11.06` installs Claude Code
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
4. **The remote view.** The phone's client is behind the pin (`claude-remote --version` says
   which): the owner ran
   `client-home-claude-remote.yml` there after the deploy, on 2026-11-07. 0.18.4 and
   0.18.5 change that client (`/mode` in place of `/auto`, Left twice on an empty prompt to
   go home, Right and Left into and out of the homes, a key redials a dropped link), and
   0.19.2 changes it again: a plan to approve shows the whole plan with Claude Code's own
   options, several questions get a tab row, an unsent prompt is kept on the client, a
   second paste expands the first, and `j` and `k` move the cursor on its homes (at the door
   too, after item 6).
   `git pull` and re-run the play on the phone and in WSL, before or after item 6
   (`cd ~/infra/ansible; ansible-playbook playbooks/client-home-claude-remote.yml`). The
   0.19 client works against zero's 0.18.1 relay (claude-sessions' agent, 2026-11-08, of
   0.19.0; 0.19.1 changes the hub's memory figures, not the client): until
   item 6, `/model` marks the resolved model, `/effort` opens on its first stop with no effort
   in the bottom bar, and swap reads `?`. A 0.19.2 client's "Yes, and use auto mode" approves
   a plan for manual edits instead, and a kept draft for a resumed conversation not yet
   prompted returns only after its next prompt (claude-sessions' agent, from v0.18.1's source,
   2026-11-08; "Tell Claude what to change" works on it). Nothing
   else here: `/rc` in a remote-view session worked on an earlier build (owner,
   2026-11-07). Still open upstream: claude-sessions is to measure cloudflared's idle
   timeout from Termux, which may move the client's `ServerAliveInterval` from 30 to 60, and
   that is the owner's call.

5. **Agent messaging. Closed 2026-11-07:** the first fleet run listed the other containers'
   slots in `ListAgents`, and a message from claude-sessions crossed to infra and the reply went
   back. The owner removed the `dev-policy` container, the `mail-token` files and the
   `dev_mail` and `dev_policy` volumes.

6. **Deploy 0.19.2** (0.18.2 to 0.19.1 were never deployed). Only the hub needs rebuilding: the base is unchanged, and Compose does
   not restart the dev containers when the hub is recreated. Connections through the hub
   (`ssh dev`, the remote view) and every container's agent drop once, so a message in flight
   waits until the new router reconnects. Rebuild the hub alone, from zero:
   ```fish
   # item 6: rebuild and recreate the hub only; the dev containers keep their sessions
   ssh -t zero 'cd ~/infra && git pull --ff-only && cd dev && make up S=hub'
   ```
   The deploy play and a bare `make up` rebuild every image, each child from its repo's
   `main`, so any child whose image comes out different is recreated too and its sessions
   end. With the play, answer y only if its plan names `dev-hub` alone. Afterwards, a message
   to an offloaded slot should wake it, and the sender should get a `hub/router` notice. And,
   new in 0.19.0 and never yet run on zero: `ListAgents` in a slot lists the slots of its own
   container by `repo/slot` and title, and a message between two of them arrives with that
   name as `from-name`. New in 0.19.2: "Yes, and use auto mode" on a plan from a 0.19.2
   client switches the mode line to auto, which closes item 4's fallback.

This note is deleted when all six are closed. Its reasoning is already in the pin row and
the *Agent messaging* section.
