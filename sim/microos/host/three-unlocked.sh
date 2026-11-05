#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated three as root once its array is unlocked with the command in
# hosts/three/leap/README.md (run-host.sh, through host/three.sh), and prints PASS or FAIL
# per check. `first` also runs the snapshot script's three paths (a snapshot, a turn skipped
# while the backup user has a process, the pruning to 90) and a scrub; `again`, after the
# reboot, checks only that the unlock brought everything back.
set -u

check() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then
		echo "PASS $name"
	else
		echo "FAIL $name"
		printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
	fi
}
mode=${1:-first}

echo "-- the array, unlocked"
check "the array is LUKS2 with Adiantum" sh -c '
	s=$(cryptsetup status mirror); echo "$s"
	echo "$s" | grep -qE "type: +LUKS2" && echo "$s" | grep -qE "cipher: +xchacha12,aes-adiantum-plain64"'
check "it is mounted at /media/mirror with the container context" sh -c '
	findmnt -no SOURCE,OPTIONS /media/mirror | tee /dev/stderr | grep -q "context=.*container_file_t"'
check "incoming is the backup user's, syncthing gavin's, snapshots root's" sh -c '
	s=$(stat -c "%U %a %n" /media/mirror/incoming /media/mirror/syncthing /media/mirror/snapshots); echo "$s"
	[ "$s" = "$(printf "%s\n" "backup 700 /media/mirror/incoming" "gavin 755 /media/mirror/syncthing" "root 700 /media/mirror/snapshots")" ]'
check "the mount started Docker and both timers" sh -c '
	for u in docker mirror-snapshot.timer mirror-scrub.timer; do
		for i in $(seq 1 30); do systemctl is-active --quiet "$u" && break; sleep 2; done
		systemctl is-active "$u" || exit 1
	done'
check "a container runs from a fresh pull" docker run --rm docker.io/library/alpine:3.22 true
check "a container reads and writes the array through the context= mount" sh -c '
	echo marker > /media/mirror/syncthing/marker; rm -f /media/mirror/syncthing/written
	docker run --rm -v /media/mirror/syncthing:/d docker.io/library/alpine:3.22 sh -c "cat /d/marker && touch /d/written" &&
	test -e /media/mirror/syncthing/written'
check "Compose is upstream's, from /usr/local" sh -c "
	docker info --format '{{range .ClientInfo.Plugins}}{{.Name}} {{.Version}} {{.Path}}{{println}}{{end}}' |
	tee /dev/stderr | grep -q '^compose .* /usr/local/lib/docker/cli-plugins/docker-compose$'"
[ "$mode" = first ] || exit 0

echo "-- snapshots and the scrub"
check "a snapshot run makes today's, read-only" sh -c '
	echo data > /media/mirror/incoming/file
	systemctl start mirror-snapshot.service
	d=/media/mirror/snapshots/$(date -u +%F)
	btrfs property get -ts "$d" ro | tee /dev/stderr | grep -qx ro=true && cat "$d/file"'
check "a second run the same day keeps the one it made" sh -c '
	systemctl start mirror-snapshot.service
	journalctl -b --no-pager -u mirror-snapshot.service | tail -n 5 | tee /dev/stderr | grep -q " exists"'
check "a turn while the backup user has a process is skipped" sh -c '
	runuser -u backup -- sleep 60 &
	sleep 1
	out=$(/usr/local/sbin/mirror-snapshot); echo "$out"
	pkill -u backup
	echo "$out" | grep -q "skipping this turn"'
check "only the newest 90 snapshots are kept, oldest deleted first" sh -c '
	for i in $(seq 1 91); do
		btrfs subvolume snapshot -r /media/mirror/incoming "/media/mirror/snapshots/$(date -u -d "2001-01-01 +$i day" +%F)" >/dev/null
	done
	/usr/local/sbin/mirror-snapshot >/dev/null
	n=$(ls /media/mirror/snapshots | wc -l); echo "$n kept; oldest $(ls /media/mirror/snapshots | head -n 1)"
	ok=0; [ "$n" = 90 ] && [ ! -e /media/mirror/snapshots/2001-01-03 ] && [ -e /media/mirror/snapshots/2001-01-04 ] &&
		[ -e "/media/mirror/snapshots/$(date -u +%F)" ] && ok=1
	for s in /media/mirror/snapshots/2001-*; do btrfs subvolume delete "$s" >/dev/null; done
	[ "$ok" = 1 ]'
check "a scrub runs, and finds no errors" sh -c '
	systemctl start mirror-scrub.service && btrfs scrub status /media/mirror | tee /dev/stderr | grep -qE "Error summary: +no errors found"'
