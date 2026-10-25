# Plan: claude-sessions in the dev containers, what is left

**Built and live; this file holds only what is still open.** `claude-sessions` is the
session menu, registry and offloader in every dev container, from its own repo
([gsfernandes81/claude-sessions](https://github.com/gsfernandes81/claude-sessions)), pinned
in `dev/Dockerfile.base`. Its design, the menu's decisions and why it is more than
`claude --resume` are that repo's `docs/design.md`. Infra's side is in
[`docs/decisions.md`](../docs/decisions.md), the rows from *Claude Code's agent view is off*
to *The offloader acts on measured activity alone*, and in `dev/README.md`
§ *claude-sessions*. The full plan, with its Phase 0 findings and the approved mockups, is
in git history before 2026-10-25.

## Open, on the boxes (the owner's)

1. **Stage A's dry-run log.** `~/.local/share/claude-sessions-dry-run.log` in each dev
   container is the evidence Stage B was read against (`dev/entrypoint.sh` keeps it on
   purpose). Nothing writes it since Stage B; delete it by hand once read.
2. **The child repos' base tags.** `or3-dev`, `dd-dev` and `ds-dev` reach the door and the
   offloader only from a base at `2026.10.04.2` or later, which each repo takes by bumping
   its own `BASE_TAG`. Check each repo's tag; `infra-dev`'s, in `dev/Makefile`, is
   `2026.10.16`.

## Unverified on a box, and claude-sessions' to settle

Phase 0 could not observe these from an agent session (auto mode refused nested `claude`
runs and reads under `~/.claude`). The tool has worked since without them, so each is worth
an issue on the claude-sessions repo only if it starts to matter:

- whether `SessionEnd` fires on SIGTERM, without which `reconcile` alone clears an
  offloaded slot;
- whether a fired wake-up passes through `UserPromptSubmit`;
- that `--resume` keeps the session id;
- one session's RAM, re-measured with a real login (the figures in the old plan were taken
  on a container still on a pre-2026-09-21 base).

## Deferred, maybe not needed

**A long-interval wake tool.** ScheduleWakeup clamps at an hour, and a keep-alive holds a
slot's RAM for the whole of a longer wait. A tool Claude could call in place of
ScheduleWakeup ("wake me in six hours with this prompt") would let `claude-sessions offload`
stop the slot and resume it when due, replaying the prompt. Worth building only if long
waits turn out to be common, and it needs a resumed session shown to accept a replayed
prompt.

## Done when

Items 1 and 2 are done; then the unverified list either becomes claude-sessions issues or
is dropped, the long-wake idea goes to that repo as an issue if it is still wanted, and this
file is deleted.
