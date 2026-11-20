# `zero` moves to Leap 16.1 Immutable

A design in progress from 2026-11-20, for the owner to review before anything is built.
It moves `zero` from Alpine to openSUSE Leap 16.1 in its Immutable mode, as `one` and
`three` moved at the November visit. When it is done its reasoning moves to
[`docs/decisions.md`](../docs/decisions.md) and this file is deleted.

**Draft.** Sections marked *to write* are not written yet; nothing here is decided beyond
the owner's calls below.

**Next:** the inventory and the traps already known are in
[`docs/handoff/2026-11-20-zero-after-the-hub.md`](../docs/handoff/2026-11-20-zero-after-the-hub.md)
§ 2. It is phase 12 in `docs/management-plane.md`, ordered after 10 and 11.

## The owner's calls, 2026-11-20

1. **The day:** the owner is at `zero` with two things ready, a new SD card with Leap and
   a USB stick for Combustion. They boot `zero` from the new card, finish over ssh, and
   it is done.
2. **The way back** is the Alpine card, untouched. So the move writes nothing the Alpine
   system cannot read on its next boot.
3. **Go or no-go is decided when it is ready.** A no-go is acceptable, and nothing is
   rushed for a date.
4. **The gate is a Pi 4's proof, already given** by `one` and `three` (`decisions.md`).
5. **The dev hub moved to `one` first**, so the infra agent stays up through `zero`'s day
   and `zero`'s move covers Immich, Syncthing, pearl-wallet and the backup source only
   (`decisions.md` § *The dev hub runs on `one`*).
6. **Immich and Syncthing come back first;** the stack is otherwise the same as today,
   under Docker.

## What `zero` runs that `one` and `three` did not

*To write, from the inventory.*

## The carry-over

*To write.*

## The day

*To write.*

## Open questions for the owner

*To write.*
