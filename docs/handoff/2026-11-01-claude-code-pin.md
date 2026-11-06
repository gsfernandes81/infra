# Handoff 2026-11-01: Claude Code pinned at 2.1.311, claude-sessions 0.18.0 (the remote view, agent messaging) — on main, not yet on zero

**First orders for the next session: read this, say where things stand, and stop.** Items 1 to
3 change zero and are the owner's to start. Item 4 is the remote view, on zero and then on each client. Item 5 is
agent messaging, which replaces agent mail; its first step comes before the deploy.

## Where it stands

On `main`: the hub pins claude-sessions 0.18.0, and base `2026.11.06` installs Claude Code
2.1.311 with updates off and a version ceiling (dev-base and dev-smoke green on `f08d6b1`, and
again on `ec1fd7e` with 0.11.0 and on `e1af926` with 0.13.1, where the smoke test ran `relay` through the hub's sshd, and on `a4ead3e` with 0.13.2), both in `dev/claude-managed-settings.json`. The reasons are the pin row in
[`decisions.md`](../decisions.md). How it is read is in [`dev/README.md`](../../dev/README.md)
§ *Claude Code in here*. The version was chosen by claude-sessions' agent (mail, 2026-11-01).

## Open

1. **The deploy**, from the phone: the recreate play, as in the pi-harness handoff's item 2.
   Do item 5's first step before it. It rebuilds the hub with 0.18.0 and recreates every
   container on `2026.11.06`, and every
   session ends. That also closes that handoff's items 2, 3, 7 and 10 once their checks read
   right.
2. **`make verify` on zero** (`ssh -t zero 'cd ~/infra/dev && make verify'`). Expected:
   `claudepin : 2.1.311, the pin`, `autoupdate: off by DISABLE_UPDATES — …`, and
   claude-sessions `0.18.0` at the hub and in each container, and `peers: claude 2.1.311 speaks
   peer protocol 1, and its inbox answers`.
3. **The ceiling, proved once.** `requiredMaximumVersion` was read from the binary and never
   seen to refuse a start (writing the managed file needs root). The test that touches
   nothing on PATH, untested as written: in one rebuilt container, `npm pack
   @anthropic-ai/claude-code-linux-arm64@2.1.316` into a temp directory, unpack it, and run
   the `claude` binary inside it with a prompt (`-p hi`). Expected: it exits at start with a
   message naming the organization's requiredMaximumVersion. `claude install` is the other
   route, but it may refuse under DISABLE_UPDATES, and it would put a binary first on PATH
   that then has to be removed. Once seen, drop "not yet seen on a box" from the pin row,
   the README, Dockerfile.base and status.sh.
4. **The remote view (claude-sessions 0.18.0).** Pinned in the hub on `main`, with a `relay`
   line in `make verify` and a smoke check through the hub's sshd. After the deploy:
   `make verify` should read `relay: claude-sessions 0.18.0`. Then, on the phone (and in WSL),
   `cd ~/infra/ansible; ansible-playbook playbooks/client-home-claude-remote.yml`, then
   `claude-remote dev`. It has never run on Termux, so the first run proves a static musl
   binary starts on Android: the play asserts `claude-remote --version` reads the pin. Run the
   play only after the deploy. The play checks the client against the checkout's pin, not
   against zero's relay. So a client installed first is a 0.18.0 client on an older relay, and
   `/tasks` and the agent views then show nothing or refuse, with no error that names the version. In a
   new session there, `/rc` should show a claude.ai/code link with no consent prompt, and
   `/rc` again turns it off (the Remote Control row in `decisions.md`). That is also the first
   real Remote Control session on the shared login, open in the dev-hub handoff's item 1; the
   container should appear in the Claude app as a machine named for its hostname. Still
   open upstream: claude-sessions is to measure cloudflared's idle timeout from Termux, which
   may move the client's `ServerAliveInterval` from 30 to 60, and that is the owner's call.

5. **Agent messaging (claude-sessions 0.18.0) replaces agent mail.** Mail stops working at this
   deploy, and messages cross through Claude Code's own `SendMessage` from then on. The why is
   [`decisions.md`](../decisions.md) § *Agent messaging*.
   - **Before the deploy**, remove the exited `policy` one-shot, which this compose file no
     longer has. The deploy play's all-up check reads `docker compose ps -a`, which lists an
     orphaned container too, so a leftover `dev-policy` would read as a container not up and
     fail a deploy that worked. `ssh zero`, then:
     ```fish
     # item 5, before the deploy: the policy one-shot leaves the project
     sudo docker rm dev-policy
     ```
   - **After the deploy**, the first fleet run is the real test, since CI has no live
     session: in a slot in one container, `ListAgents` should list another container's slots
     as `repo/slot`, and a `SendMessage` there should arrive and its reply come back.
     `~/.hub/router.log` in the hub has one line per frame.
   - **Then the leftovers**, once messaging works. Each container's tokens directory still
     holds the `mail-token` the mail server wrote, and the `dev_mail` and `dev_policy` volumes
     outlive the compose file. `dev_mail` is every mail message since 2026-10-29, the only
     copy, so deleting it is the owner's call. `ssh zero`, then:
     ```fish
     # item 5, after the deploy: the mail tokens and the two volumes mail left
     sudo docker exec dev-hub sh -c 'rm -f /home/dev/tokens/*/mail-token'
     sudo docker volume rm dev_policy dev_mail
     ```

This note is deleted when all five are closed. Its reasoning is already in the pin row and
the *Agent messaging* section.
