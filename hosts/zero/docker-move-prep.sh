#!/bin/sh
# ONE-SHOT. Delete this file once zero's /var/lib/docker move is done (docs/decisions.md,
# "zero's /var/lib/docker moves to sda2"). It is the half of that move that needs no
# downtime, and it stops no container. In `ssh zero`:
#
#     cd ~/infra; git pull --ff-only
#     sudo -b sh hosts/zero/docker-move-prep.sh          # starts in 20 minutes
#     sudo -b sh hosts/zero/docker-move-prep.sh 0        # starts now
#     sudo tail -f /var/log/docker-move-prep.log         # watch it; ends with PREP DONE or PREP STOPPED
#
# sudo -b asks for the password, then runs this in the background as root; hangups are
# ignored, so closing the ssh session does not stop it. Safe to run again: each step
# notices what an earlier run already did.
#
# WHAT IT DOES, in order, after the wait:
#   1. Trims Docker: all build cache and dangling images. It deletes no image that a
#      container uses, running or stopped, and no container or volume. Images no container
#      uses are LISTED, not deleted: that is the owner's call.
#   2. Takes an Immich database dump to /var/backups/immich, as docs/recovery.md's by-hand
#      block does. A failed dump is reported and the run goes on: the dump is for the window.
#   3. Formats sda2 as btrfs with the UUID the tracked fstab already names, but only if
#      it proves the partition is the one the owner said holds nothing of value: the old
#      Ubuntu install's ext4 UUID, ext4, 64 GiB, not mounted, not swap. Any doubt stops the run.
#   4. Makes the var-lib-docker subvolume and copies /var/lib/docker into it, live.
#      Containers keep running, so the copy is not consistent; the window's second pass,
#      with Docker stopped, makes it so and moves only what changed. -x keeps rsync out of
#      the running containers' rootfs mounts, which would otherwise be copied whole.
#
# WHAT IT DOES NOT DO: stop anything, touch /etc/fstab, or mount anything over
# /var/lib/docker. The new filesystem is left mounted at /tmp/docker-new for the window.

trap '' HUP
LOG=/var/log/docker-move-prep.log
exec </dev/null >>"$LOG" 2>&1
set -u

OLD_UUID=77c7bae7-da0b-471a-9b8c-d18081f3402e    # sda2's old ext4, seen 2026-10-26
NEW_UUID=7bebb62b-62b1-444c-a602-38d11022781a    # what hosts/zero/system/fstab mounts
SDA2_SECTORS=134217728                           # 64 GiB, from /proc/partitions
NEW=/tmp/docker-new

say() { echo "$(date -u +%H:%M:%SZ)  $*"; }
stop() { say "PREP STOPPED: $*"; exit 1; }

say "started; waiting ${1:-1200}s"
sleep "${1:-1200}"

[ "$(id -u)" -eq 0 ] || stop "not root: run it with sudo -b"
docker info >/dev/null 2>&1 || stop "docker is not answering"
case "$(df /var/lib/docker | awk 'NR==2 {print $1}')" in
	/dev/mmcblk*) ;;
	*) stop "/var/lib/docker is not on the SD card: has the move already happened?" ;;
esac

# ── 1. trim ──────────────────────────────────────────────────────────────────
say "docker system df, before:"
docker system df
say "pruning all build cache"
docker builder prune -af
say "pruning dangling images"
docker image prune -f
say "images no container uses (NOT deleted; docker image rm <id> for any you want gone):"
docker images --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Size}}' | while read -r id ref size; do
	[ -z "$(docker ps -aq --filter ancestor="$id")" ] && echo "    $ref  $id  $size"
done
say "docker system df, after:"
docker system df

# ── 2. Immich dump ────────────────────────────────────────────────────────────
mkdir -p -m 700 /var/backups/immich
f=/var/backups/immich/immich-$(date -u +%Y%m%dT%H%M%SZ)-manual.sql.gz
say "dumping Immich's database to $f"
( umask 077; docker exec immich_postgres sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' | gzip > "$f.partial" )
if gzip -cd "$f.partial" | tail -n 3 | grep -q 'dump complete'; then
	mv "$f.partial" "$f"
	say "Immich dump ok: $(du -h "$f" | cut -f1)"
else
	say "IMMICH DUMP FAILED: $f.partial is not complete. Take one by hand before the window."
fi

# ── 3. sda2 ──────────────────────────────────────────────────────────────────
# A run that already formatted and mounted it left the filesystem in the kernel's btrfs
# registry, which answers without probing any disk (a bare blkid would probe them all,
# the bcache disks behind their USB bridges included).
if [ -d "/sys/fs/btrfs/$NEW_UUID/devices" ]; then
	dev=/dev/$(ls "/sys/fs/btrfs/$NEW_UUID/devices" | head -n 1)
	say "sda2 is already the new btrfs ($dev): not formatting again"
else
	dev=$(readlink -f "/dev/disk/by-uuid/$OLD_UUID" 2>/dev/null)
	[ -n "$dev" ] && [ -b "$dev" ] || stop "no device has the old ext4 UUID $OLD_UUID"
	blkid "$dev" | grep -q "UUID=\"$OLD_UUID\"" || stop "$dev does not carry UUID $OLD_UUID"
	blkid "$dev" | grep -q 'TYPE="ext4"' || stop "$dev is not ext4: $(blkid "$dev")"
	[ "$(cat "/sys/class/block/${dev#/dev/}/size")" = "$SDA2_SECTORS" ] || stop "$dev is not 64 GiB"
	grep -q "^$dev " /proc/mounts && stop "$dev is mounted"
	grep -q "^$dev " /proc/swaps && stop "$dev is swap"
	say "formatting $dev ($(blkid "$dev")) as btrfs $NEW_UUID"
	mkfs.btrfs -f -U "$NEW_UUID" -L docker "$dev" || stop "mkfs.btrfs failed"
	blkid "$dev" | grep -q "UUID=\"$NEW_UUID\"" || stop "after mkfs, $dev does not carry $NEW_UUID"
fi

# ── 4. subvolume and the live copy ───────────────────────────────────────────
mkdir -p "$NEW"
if ! grep -q " $NEW " /proc/mounts; then
	mount -t btrfs -o subvolid=5,compress=zstd:1,noatime,discard=async "$dev" "$NEW" || stop "mount failed"
fi
[ -d "$NEW/var-lib-docker" ] || btrfs subvolume create "$NEW/var-lib-docker" || stop "subvolume create failed"
command -v rsync >/dev/null || apk add --virtual .docker-move rsync || stop "could not install rsync"

say "copying /var/lib/docker live (first pass)"
nice -n 10 rsync -aHAXSx --numeric-ids --delete --stats /var/lib/docker/ "$NEW/var-lib-docker/"
rc=$?
# 24 is "some files vanished", which a live copy expects; 23 is "some files could not be
# transferred", also expected live. Both are put right by the window's pass. Anything else
# is worth reading before the window, ENOSPC above all.
case $rc in
	0|23|24) say "first pass done, rsync exit $rc" ;;
	*) stop "rsync exit $rc: read the lines above" ;;
esac
df -h "$NEW"
say "PREP DONE. $NEW stays mounted for the window; Docker was not stopped."
