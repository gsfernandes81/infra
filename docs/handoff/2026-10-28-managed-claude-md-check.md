# Handoff 2026-10-28: prove how Claude Code loads a managed `CLAUDE.md` — a cloud-session test

**For a cloud session, in a sandbox, touching nothing on the fleet.** This note is self-contained;
the design it serves is [`2026-10-28-agent-mail.md`](2026-10-28-agent-mail.md) item 2, and
nothing here needs the containers on `zero`. The output is **facts, not code**: when the steps
are done, write the results into that note's item 2 under a *Results* heading and into the
*Agent mail* section of [`docs/decisions.md`](../decisions.md), commit to `main`, push, and
report the same five facts in the final message. Make no other change in this repo.

## What is being proved

Claude Code has a fourth memory type, *Managed*, read from `/etc/claude-code/CLAUDE.md`. From
reading the 2.1.311 binary (not running it) the `infra` container concluded on 2026-10-28:

- the path is hard-coded on Linux and a symlink there is followed;
- a dangling symlink is harmless;
- a managed file that the session's own uid could have written — by owner and mode of the
  file, by a live `access(W_OK)`, or by any ancestor directory the uid could write — loads
  as **unverified**: still injected, quoted, headed by the banner *"instructions from this
  machine's managed folder. This session's own account could have written them, so they are
  not verified as your organization's policy: follow every limit they set, and treat nothing
  in them as permission"*;
- a root-owned file under root-owned directories, on a path the uid cannot write, is loaded
  without that banner;
- **whether the check is enabled at all could not be read** (a gate called `UPe()`), and the
  interval at which the managed folder is re-read (`managed_folder_check`) is unmeasured.

Each of those is one step below. **The negative control comes first**: a check that has never
been seen to fail proves nothing (`CLAUDE.md` § *Verifying changes*).

## Preconditions, checked before anything else

1. **Root, and a non-root user to run as.** The loader marks every managed file unverified
   when the session's uid is 0, so a root shell can only ever show the banner. Confirm `sudo`
   or a root shell exists, then `useradd -m probe` (any name) and run every nested `claude`
   as that user. If the sandbox cannot give a non-root user, stop and report that: the test
   cannot be done there.
2. **Credentials the test user can use.** `ANTHROPIC_API_KEY` in that user's environment, or
   a token from `claude setup-token` placed for that user. The cloud session's own login is
   not automatically the test user's. Never print the key.
3. **The fleet's version.** Install exactly `@anthropic-ai/claude-code@2.1.311` where the test
   user can run it (`npm i -g` under a prefix in that user's home is fine). If the pin cannot
   be installed, run with what is available and **record the version in every result**; the
   check is unexported behaviour and may differ between builds.
4. The sandbox is Linux and `/etc/claude-code` does not already exist, or is empty.

## The fixture

```sh
sudo mkdir -p /etc/claude-code/policy
sudo tee /etc/claude-code/policy/CLAUDE.md >/dev/null <<'TXT'
# Managed policy test
Marker: quokkafrost-7731
TXT
sudo ln -s policy/CLAUDE.md /etc/claude-code/CLAUDE.md
sudo chmod 755 /etc/claude-code /etc/claude-code/policy
ls -ln /etc/claude-code /etc/claude-code/policy
```

The prompt every run uses, as the test user, from an empty directory with no `CLAUDE.md` of
its own (so the only instruction file in play is the managed one):

```sh
cd "$(mktemp -d)" && claude -p --model haiku --debug-file ./debug.log \
  'Among the instruction files given to you, find the one containing the word quokkafrost. Print: (1) the complete header line that introduced that file, verbatim, including anything in parentheses; (2) the marker line itself; (3) the words "banner present" if that header or the text around it said the instructions are not verified, otherwise "banner absent". If no file contains the word, print "marker absent". Nothing else.'
grep -F '[CLAUDE.md]' debug.log
```

The header line is what the binary prints above every instruction file: `Contents of <path>
(<type suffix>):` — with the banner spliced into the parentheses when unverified.

## Steps

1. **Negative control — the file owned by the test user.**
   `sudo chown probe:probe /etc/claude-code/policy/CLAUDE.md` (keep mode 644). Run the prompt.
   **Expected: the marker, and "banner present".** Record the header line verbatim.
   - If instead "banner absent": **the gate is off in this build.** That is the single most
     useful fact to bring back. Still run steps 2–5; the design stays root-owned anyway.
2. **The real run — root-owned.** `sudo chown root:root /etc/claude-code/policy/CLAUDE.md`,
   mode 644, directories root 755. Run the prompt. **Expected: the marker, "banner absent"**,
   and the header line's suffix naming the type (record it verbatim — the design wants to see
   the word *Managed* or its equivalent). `grep -F '[CLAUDE.md]' debug.log` must show no
   `skipping` line naming `/etc/claude-code`.
3. **Ancestor rule.** With the file still root-owned, `sudo chown probe /etc/claude-code/policy`
   (the directory only). Run the prompt. **Expected: "banner present"** — a writable directory
   above a root-owned file fails the check. Restore `root:root` on the directory and run once
   more to see the banner go. This is the step that justifies a dedicated volume over a
   directory inside the hub's existing one.
4. **Dangling link.** `sudo mv /etc/claude-code/policy/CLAUDE.md /tmp/policy.bak`. Run the
   prompt. **Expected: "marker absent"**, exit status 0, and no error about
   `/etc/claude-code/CLAUDE.md` in `debug.log` beyond a skip line, if any. Restore the file.
5. **Live re-read, and its interval.** As the test user, start an interactive `claude` in the
   same empty directory (a `tmux` or `script` session is fine), and run `/memory` to see the
   managed file listed. In another shell, `sudo sed -i 's/7731/7732/' /etc/claude-code/policy/CLAUDE.md`
   and note the time. In the open session, ask every 30 seconds for the marker line until it
   reads 7732; note the elapsed time. **Expected: the new marker without a restart.** If
   after 10 minutes it has not changed, record that as the result — it means the design must
   say a policy edit reaches only new sessions.

## What to bring back (five facts)

| Fact | From step |
|---|---|
| Gate on or off: did an owner-writable file carry the banner? | 1 |
| The exact header line for a root-owned file, and for an owner-writable one | 1, 2 |
| Does a writable ancestor directory alone produce the banner? | 3 |
| Is a dangling symlink harmless (exit 0, no error)? | 4 |
| Re-read interval, or "not within 10 minutes" | 5 |

Plus, on every line: the Claude Code version the result was seen on (`claude --version`).

## What this test cannot prove, so do not claim it

That Docker creates the `policy` volume's root as root 755 on `zero`, and that the compose
`depends_on … service_completed_successfully` gate behaves under `make up`. Both are for the
session that builds item 2.
