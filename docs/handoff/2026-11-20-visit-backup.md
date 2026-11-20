# Handoff, 2026-11-20: the visit's last day, and zero's backup to three

**First orders for the incoming agent:**

1. **Don't trust this note completely.** It was written at the end of a very long session,
   partly from memory. Before acting on any line, check it against the repo (`git log`, the
   files it names) or against what the owner pastes from a box. Where this note and the repo
   disagree, the repo wins; where the repo and a box disagree, the box wins (CLAUDE.md §
   Docs, plans and handoffs).
2. Read this note, then check the state of `origin/backup-pull` (its commits, its CI runs,
   and the "Work in progress, 2026-11-20" section at the end of its
   `plans/three-backup-pull.md`). Then tell the owner where things stand, in the priority
   order below, and **wait for the owner's go** before writing a handover block or merging
   anything.
3. The owner flies to Singapore on **2026-11-21** with `three`, and is beside the fleet
   until then. Anything that needs `three` on the home network, or a hand on a box, has to
   happen before that.

**How the owner works**, all of it from this session:
- They answer in short numbered replies.
- They run handover blocks for fish on a TTY, and paste the output back.
- They want a running list of what is left at the end of each reply: the top items by
  priority, and the last item a short list of low-priority, blocked or later things.
- They review designs before builds.
- They chose: Opus for reviews, a sub-agent for each build, and a review before every
  merge. Sub-agents poll CI at most every 5 minutes.

## Where things stand

**Done this visit, verify before relying on it:**
- **`one`** runs Leap on the 8 GB Pi, and all four apps are deployed.
- **`three`:**
  - it runs Leap in the Argon EON, behind its tunnel (`ssh three`), on the tailnet at
    100.101.45.78;
  - its array is LUKS2 with Adiantum, made by `make-mirror`, and today it is still named
    `mirror` (`/media/mirror`, label `mirror-luks`);
  - `syncthing-three` is deployed behind an Access login;
  - the fan service (`argon-fan`, seven levels) is installed;
  - the first-boot stick is erased.
- **`zero`'s disk swap is finished:**
  - the failing WD10SPZX was replaced by a 4 TB WD Red Plus (serial WD-WXB2D76H9RCN), now
    `bcache1` on `sdb`, encrypted as LUKS2 with Adiantum, label `data-luks-4`, mapping
    `data-4`;
  - the key file `/etc/keys/data.key` on the SD card opens it at boot ("protection off"), and
    the owner's passphrase is keyslot 1;
  - the unattended reboot on 2026-11-20 proved the unlock, and both bcache devices are back on
    writethrough;
  - the record is `plans/visit-runbook.md` § Slice 2 and `docs/decisions.md` § *`zero`'s
    encrypted member*;
  - the old disk is being zeroed on `one`; see the memory reminder for about 2026-12-09.
- **On `main`:** the Access change, which writes only on a difference; Leap hosts read
  `leap/system/` (the `MOVED` marker); three's fan; the DNS comment fix; and the rest in
  `git log`.

**zero has no off-site backup.** The old rsync push was removed from `zero` on 2026-11-18.
The replacement is designed and approved, and it is mostly built, on the branch
`backup-pull`. It is not merged and not installed anywhere.

## The backup: what is decided

The design is in `plans/three-backup-pull.md` on `origin/backup-pull`; its owner's-answers
sections are decisions. In short:
- **Not btrfs send/receive.** Two security reviews found that a root `btrfs receive` trusts a
  stream a compromised `zero` could craft (`docs/decisions.md` § *`zero`'s backup is pulled
  by rsync from snapshots*). The `send-receive` branch is abandoned; delete it once nothing
  more is needed from it.
- **`zero`:**
  - snapper takes the snapshots, from Alpine edge/testing, pinned, `--no-dbus`, run by an
    hourly periodic script under flock. It keeps 24 hourly and 7 daily snapshots of one
    subvolume, `immich`, which holds both the library (`data/`) and Postgres (`db/`), so one
    snapshot is consistent;
  - `thumbs` and `encoded-video` are nested subvolumes, so they are left out;
  - Syncthing is not backed up (owner);
  - `autodefrag` is dropped from the new line (issue #23 for a timed defrag).
- **`three`:**
  - it pulls daily at 01:00 UTC at 32 Mbit/s;
  - the pull runs as the unprivileged user `backup`, over ssh to `zero`'s user `backup`. That
    user's forced command runs `sudo setpriv` into a read-only rsync daemon that holds only
    `CAP_DAC_READ_SEARCH`;
  - `three` then snapshots its copy with its own snapper, keeping daily 14, weekly 8 and
    monthly 12.
- **Restores:** `zero` has read-only restore access to its own backup on `three`.
- **The alert is deferred** to a fleet-wide dead man's switch, so nothing alerts yet.

**Already done on the boxes for it:**
- **On `zero`:** `setpriv` (util-linux), `rsync`, `sudo` and `snapper 0.13.1` are installed,
  world-pinned, with the .apk kept in `/root`. The user `backup` exists (`backup:*`,
  /home/backup and its .ssh owned by root).
- **On `three`:** `/home/backup/.ssh/zero-pull` exists, fingerprint
  `SHA256:9rZpPX2SVlOOQfM1T81VzH6sOdk+0AvyLIaXm8B5juM`. Its public half is committed in
  zero's key line on the branch.

**Still to do on the branch,** and the last agent was cut off before any of it:
- **Fix the red CI first:** alpine-sim failed on `c6d0da8`, the merge of `main` into the
  branch.
- **The owner wants "mirror" gone wherever it means the backup, done now:**
  - `three`'s live array: `/media/mirror` becomes `/media/backup`, the label `mirror-luks`
    becomes `backup-luks`, the crypttab name `mirror` becomes `backup`, and the btrfs label,
    `media-*.mount`, `mirror-scrub.*`, `mirror-mount.conf`, `docker-mirror.conf` and
    `make-mirror` follow;
  - the layout becomes `/media/backup/immich/` (holding `current/` and its `.snapshots`), with
    no `received-backups` level;
  - the restore module serves only `/media/backup/immich`;
  - `zero`'s `/var/lib/mirror-backup` (it holds the ntfy-url secret) and
    `mirror-backup-age-check` get coherent new names.

  The facts gathered for this are in the branch plan's last section.
- **A live-migration procedure for `three`:** fish blocks covering the relabels, the reshape,
  the install, removing the old files, `/media/backup` made with transactional-update, the
  reboot and unlock, and the redeploy of `syncthing-three`, with a way back at each step.
- **Simulate, then an Opus review** focused on: `three` failing to boot or unlock, removal
  commands, data loss in the reshape, and the security of the pull and restore paths.
- **PR #22** (the array as a play) gets a change list for the new layout; it stays a draft.

## What is left before the owner flies, by the owner's priority

1. **`three`'s backup install** with the renames, then the reboot and unlock (the owner's
   morning). It waits on the branch being green and reviewed.
2. **The move on `zero`:** `immich-data` and `immich-db` are reflink-copied into one `immich`
   subvolume with Immich stopped, the new fstab line and the guard are added, and Immich's
   `.env` changes. Then snapper's config, the hourly script, the sudoers file and the
   read-only module are installed. The procedure is on the branch in `plans/visit-runbook.md`.
3. **The first pull,** about 93 GB, while `three` is still on the home network, with the
   32 Mbit/s limit lifted for that run.
4. **Last:** `three`'s wired profile is switched to DHCP. It will be on Ethernet in Singapore,
   so it needs no Wi-Fi (decided 2026-11-20). Then power off and pack.

**Low priority, or later:**
- the tailnet's access rules (only `three` → `zero` and `zero` → `three` on ssh);
- the slice 4 restore test, once after the first pull;
- **the dev containers stay down after a reboot.** That is by design (`restart: "no"`); the
  owner may want the infra container to restart by itself, which is their call;
- turning `zero`'s LUKS on, and LUKS on the WD Elements's replacement;
- issue #23 (defrag);
- an adversarial review of the fan service and the first-boot script;
- the `Restricted` and `or3-dev` Access apps;
- deleting the `send-receive` branch;
- `three`'s memory during the first pull;
- PR #22;
- the `immich`/`syncthing` recreate puzzle on `zero`;
- `--check` hiding diffs;
- `one`'s dirty FAT and leftover snapshots, and Cockpit in `one`'s firewall;
- regenerating `zero`'s `hardware.md` with `bin/hw-inventory`.

**Delete this note** once the backup is installed and the items above are closed or filed
in the phase table, after moving anything durable into `docs/decisions.md`.
