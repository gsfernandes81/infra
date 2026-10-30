# Handoff 2026-10-30: pi as a claude-sessions slot — built and green in CI, not yet on zero

**First orders for the next session: read this, say where things stand, and stop.** Items 1 to
4 change zero and are the owner's to start. Items 5 to 8 are findings: none of them starts work
until the owner picks it.

## Where it stands

Built on 2026-10-30 and green in the smoke test, on GitHub's amd64 runner only. The base
`2026.10.30` carries pi 1.4.0 and its nine packages, and the entrypoint seeds pi's agent dir
and links the policy, the four skills and the claude-sessions extension. The hub pins
claude-sessions 0.10.0, which starts a pi slot with `p`, and copies `openrouter-key` from
`$HUB_SECRETS` into every container. The managed policy tells a pi session how to read its
mail. From base `2026.10.30.1` pi's gate runs in `yoloMode` with no judge and eight packages,
denying only force and mirror pushes by rule above `cc-safety-net`, and the footer's welcome
card is off. The
reasons are the pi row in [`decisions.md`](../decisions.md); how pi is used is
[`dev/README.md`](../../dev/README.md) § *pi*. The plan, `plans/pi-harness.md`, is deleted:
both repos built their side.

## Open

The owner's, in this order, each on zero:

1. **The key file.** Put the OpenRouter key in `$HUB_SECRETS` as `openrouter-key`. The
   default is `~/.dev-secrets`, and zero's `dev/.env` names it if it is elsewhere. The block
   goes inside `ssh zero` and reads the key without echoing it, so it never sits in
   scrollback:

   ```fish
   # zero: the OpenRouter key, typed at the prompt, into a file made 600 first
   rm -f ~/.dev-secrets/openrouter-key; touch ~/.dev-secrets/openrouter-key; chmod 600 ~/.dev-secrets/openrouter-key
   read -s -P 'OpenRouter key: ' k; and printf '%s\n' $k > ~/.dev-secrets/openrouter-key; set -e k
   ```

2. **The deploy**, once this is on `main` and `dev-base.yml` has published `2026.10.30.1`: the
   recreate play from the phone, as [`dev/README.md`](../../dev/README.md) § *Four copies of
   this, now one base* gives it (`make up` on zero is the break glass). It rebuilds the hub
   with claude-sessions 0.10.0 and the new policy, and recreates every container on the new
   base. Every session in every container ends. The hub copies the key at this start.
3. **`make verify` on zero** (`ssh -t zero 'cd ~/infra/dev && make verify'`). Expected: `pi`
   reads `1.4.0`, `pi-ext:` reads `linked`, `pi-tui:` reads `--tui-mode present`, and the
   claude-sessions line reads `0.10.0`. Then `p` in the menu, and one prompt in that slot,
   which proves the key.
4. **The old volume:** inside `ssh zero`, `sudo docker volume rm infra-dev_infra-jcode`, after
   item 2, when no container mounts it.

Findings, not started:

5. **The startup dialog was `pi-powerline-footer`'s welcome card, and it is off from base
   `2026.10.30.1`** (`"welcome": false` under `powerline` in `dev/pi-settings.json`, a key the
   entrypoint now re-seeds at every start). It drew a "Press any key to continue" card with a
   countdown at every start, and that prompt set `needs_you`, the amber `!`, on a fresh slot.
   Open until that base is on zero: then a fresh `p` slot should show no `!` before its first
   prompt. claude-sessions has the name (mail, 2026-10-30 11:07Z).
6. **Idle CPU on arm64 is unproven.** The offloader counts an idle slot as quiet only under
   3000 ms of CPU per three-minute window. On amd64, pi alone used about 1.2 s over 180 s
   idle, its `ty` child not counted. If an idle pi slot on zero goes over, it is never
   offloaded; that is a finding for claude-sessions, not a reason to change the rule. Infra
   owes claude-sessions a mail with what the first slot on zero shows.
7. **claude-sessions 0.10.1.** Its commit `0aba963` hands pi's events to the hook one at a
   time, so a prompt answered at once cannot leave the `!` set. It reaches the fleet only in
   a release, which is the owner's to cut; infra then bumps the pin and its two hashes.
8. **Termux's handling of pi's extended-key queries is untested.** Whether Termux answers
   them, and whether any key misbehaves when it does not, shows at the first attach from the
   phone. Not a blocker.
9. **Two pinned dependencies carry published advisories.** Pi 1.4.0 pins `undici` 8.10.2,
   which has advisories against it, one a TLS-validation bypass when custom TLS options are
   passed; `pi-permission-classifier` pinned `zod` 4.4.3, which has a high-severity one. The
   classifier left the image in base `2026.10.30.1`, so that pin went with it; other packages
   still use `zod` at whatever version the build resolves. Nothing to fix in infra: `undici` is
   pinned inside pi, so it moves when pi releases, and the next pi bump should check it and
   the resolved `zod`.

10. **`mail-read` and `mail-reply` do not load in pi.** Their `SKILL.md` frontmatter has an
    unquoted `description:` containing `: `, which Claude Code tolerates and pi's strict YAML
    parser rejects ("Nested mappings are not allowed in compact mappings"); pi drops both
    skills and prints the error at start, so a pi session has `keepalive` and `mail-send` and
    reads mail from the policy's sentence alone. The files are claude-sessions' (shipped by
    its `install`); its agent was asked on 2026-10-30 to quote the two descriptions for
    0.10.1. Nothing to change in infra; the pin bump of item 7 brings the fix.

This note is deleted when all ten are closed. Its reasoning is already in the pi row, so
nothing needs moving first.
