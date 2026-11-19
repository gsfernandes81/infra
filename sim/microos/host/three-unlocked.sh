#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated three as root once its array is unlocked with the command in
# hosts/three/leap/README.md (run-host.sh, through host/three.sh), and prints PASS or FAIL
# per check. `first` also runs a scrub; `again`, after the reboot, checks only that the
# unlock brought everything back. The backup's pull and snapshots are three-backup.sh's.
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
check "it is mounted at /media/mirror with the container context, nosuid and nodev" sh -c '
	o=$(findmnt -no SOURCE,OPTIONS /media/mirror); echo "$o"
	echo "$o" | grep -q "context=.*container_file_t" && echo "$o" | grep -qw nosuid && echo "$o" | grep -qw nodev'
check "received-backups is root's, current the backup user's, syncthing gavin's" sh -c '
	s=$(stat -c "%U %n" /media/mirror/received-backups /media/mirror/received-backups/immich/current /media/mirror/syncthing); echo "$s"
	[ "$s" = "$(printf "%s\n" "root /media/mirror/received-backups" "backup /media/mirror/received-backups/immich/current" "gavin /media/mirror/syncthing")" ]'
check "the mount started Docker and both timers" sh -c '
	for u in docker backup-pull.timer mirror-scrub.timer; do
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
echo "-- the fan, with the array's drive attached"
# Found by its LUKS label, never by a fixed name. The VM's USB disk answers no SMART, so
# the drive's temperature reads unknown: the unit sets the fan to the top, says why, and
# runs.
check "argon-fan finds the drive by its LUKS label, and runs" sh -c '
	d=$(basename "$(readlink -f /dev/disk/by-label/mirror-luks)")
	for i in $(seq 1 12); do
		journalctl -b --no-pager -u argon-fan | grep -q "drive found at /dev/$d," && break; sleep 5
	done
	journalctl -b --no-pager -u argon-fan | tail -n 6
	journalctl -b --no-pager -u argon-fan | grep -q "drive found at /dev/$d," &&
	systemctl is-active argon-fan.service'
[ "$mode" = first ] || exit 0

echo "-- the scrub"
check "a scrub runs, and finds no errors" sh -c '
	systemctl start mirror-scrub.service && btrfs scrub status /media/mirror | tee /dev/stderr | grep -qE "Error summary: +no errors found"'
