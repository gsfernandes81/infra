# `zero`'s backup to `three`: what is left

The pull is live. `zero` takes an hourly read-only snapper snapshot of its Immich, `three`
pulls the newest finished one daily at 01:00 UTC as an unprivileged user and snapshots its
copy, and the first pull ran on 2026-11-20: 97 GB in 55 minutes over the LAN. `three`'s
array was renamed from "mirror" to "backup" the same day. How each side runs is in
[`hosts/zero/system/README.md`](../hosts/zero/system/README.md) § The backup and
[`hosts/three/leap/README.md`](../hosts/three/leap/README.md) § The backup and § The
pull's setup. Why it is built this way is in [`docs/decisions.md`](../docs/decisions.md)
§ *`zero`'s backup is pulled by rsync from snapshots*, § *The pull, as built* and § *The
backup's names and layout on `three`*.

This file keeps what is still open, and is deleted when the restore test has passed and
PR #22 has merged or been closed.

## The restore test

[`visit-runbook.md`](visit-runbook.md) § Slice 4: the whole tree compared with `zero`'s
snapshot through the restore module, and Immich's database started from `three`'s copy.
Until it passes, the backup is copied but not proven, and `zero`'s old `media-immich-data`
and `media-immich-db` subvolumes stay.

## PR #22, the array as a play

Its change list, for the layout of 2026-11-20: `lb_layout` accepts only top-level names
(`^[A-Za-z0-9._-]+$`), and the layout needs nested entries (`immich`, `immich/current`,
`immich/current/.snapshots`, `immich/state`), so the play must make parents first and
refuse `..`; its labels become `backup-luks` and `backup`. `make-backup` is deleted when
PR #22 merges.

## The alert

Deferred by the owner to a fleet-wide dead man's switch, designed separately
(`docs/decisions.md` § *`zero`'s backup is pulled by rsync from snapshots*; the phase
table of `docs/management-plane.md`). Until then nothing alerts when the pull stops.
`backup-age-check` and `server-store-backup-ntfy-url.yml` stay in the tree, marked not
used, for that design.

## A second subvolume

Not planned. What it would change, template units `backup-pull@<subvolume>`, is in
`docs/decisions.md` § *The backup's names and layout on `three`*.
