# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054  # read by run-host.sh; commas belong to qemu
# three's stand-ins for sim/microos/run-host.sh; sourced, never run.
#
# three is a NEW host, so its stick is the one `make-stick --new` builds: no tunnel
# credentials, .env, secrets or volumes (run-host.sh leaves them out for a host with no
# tunnel config). After the first boot, the hooks below do what the visit does next: put a
# tunnel in place as server-create-host-tunnel.yml and install-system-file would, make the
# array with server-create-three-array.yml, and unlock it with the README's own command.

# zero's two values in the backup user's authorized_keys, read from the tracked line and
# swapped on the stick for the run's own: its backup key, which the runner pushes with as
# zero would, and the address the runner's connections arrive from, qemu's host address on
# this network. Everything else on the line is the tracked one, as the box will carry it.
rm -f backup-key backup-key.pub
ssh-keygen -q -t ed25519 -N '' -C 'sim zero mirror-backup' -f backup-key
zero_line=$(grep -v '^#' "$repo/hosts/three/leap/system/backup-authorized-keys")
zero_from=$(sed -n 's/.*from="\([^"]*\)".*/\1/p' <<<"$zero_line")
zero_key=$(grep -oE 'ssh-ed25519 [A-Za-z0-9+/=]+ .*$' <<<"$zero_line")
declare -A standin=(
	["$zero_key"]="$(cat backup-key.pub)"
	["$zero_from"]=192.168.86.1
)

# qemu's user network on the UK subnet, so three's static address answers.
sim_net=192.168.86.0/24
sim_gateway=192.168.86.1
sim_dns=192.168.86.3
sim_address=192.168.86.103
sim_dhcp_address=192.168.86.15

tunnel_id=3a3a3a3a-0000-4000-8000-000000000003

# syncthing-three requires no name from .env; anything asked for gets a made-up value.
standin_env() { openssl rand -hex 16; }
deployments=(syncthing-three)
volumes=()

# The WD Red, new and blank, on USB as the Argon's bridge puts it. Its size is how the
# hooks find it on the box; server-create-three-array.yml formats it there. Beside it, a
# small drive that already holds a filesystem, which the play must refuse.
mirror_bytes=$((1536 * 1024 * 1024))
stranger_bytes=$((80 * 1024 * 1024))
make_disks() {
	truncate -s "$mirror_bytes" mirror.img
	rm -f stranger.img
	mke2fs -q -t ext4 -L stranger stranger.img "$((stranger_bytes / 1024 / 1024))M"
	echo "a blank $((mirror_bytes / 1024 / 1024))M drive for the array, and an $((stranger_bytes / 1024 / 1024))M one holding ext4"
}
disk_args=(
	-drive file="$PWD/mirror.img",if=none,id=mirror,format=raw
	-device usb-storage,bus=xhci.0,drive=mirror
	-drive file="$PWD/stranger.img",if=none,id=stranger,format=raw
	-device usb-storage,bus=xhci.0,drive=stranger
)

luks_password=$(openssl rand -hex 12)

# The unlock, exactly as hosts/three/leap/README.md § Unlocking gives it, typed at a
# terminal: unlock.py answers sudo's prompt and then systemd's.
sim_unlock() {
	if SIM_SUDO_PW=$password SIM_LUKS_PW=$luks_password python3 -I "$here/host/unlock.py" \
		-i key -p "$(cat port)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o BatchMode=yes gavin@127.0.0.1 \
		-- 'sudo systemctl start systemd-cryptsetup@mirror.service; and sudo systemctl start media-mirror.mount' \
		> unlock.log 2>&1; then
		echo "PASS the README's command unlocks and mounts the array"
	else
		echo "FAIL the README's command did not unlock the array:"
		tail -n 15 unlock.log | sed 's/^/    /'
	fi
	# The mount starts Docker, and the first run saw the next new ssh connection fail as it
	# did (exit 255). So the first attempt's own words are kept, ssh is waited for and how
	# long it was away reported, and if it never returns the console shows the firewall and
	# Docker's start.
	echo "the first ssh after the unlock: $(ssh -i key -p "$(cat port)" -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=known -o BatchMode=yes -o ConnectTimeout=5 gavin@127.0.0.1 true 2>&1 &&
		echo answered || true)"
	if ! wait_gavin static; then
		echo "the console's view of the firewall and Docker after the unlock:"
		python3 -I "$here/serial-login.py" serial.sock "$root_password" "$(cat <<'DIAG'
firewall-cmd --state; firewall-cmd --get-active-zones; firewall-cmd --list-all
nft list ruleset | head -n 120
journalctl -b --no-pager -u docker -u firewalld | tail -n 60
ss -tlnp | head -n 20; systemctl --no-pager status sshd | head -n 12
DIAG
)" || tail -n 60 serial.log
		return 1
	fi
}

# server-create-three-array.yml, run from the runner as the control node, as the phone runs
# it. The answers a person types come as -e: the device name for its question, and the
# passphrase twice, from a file only this run can read, removed straight after. Neither
# secret may appear in its output. Usage: array_play <log> <device> <pass> <pass again> [args]
array_play() {
	local log=$1 dev=$2 p1=$3 p2=$4 rc=0 s
	shift 4
	local inv=$repo/ansible/inventory.sim-host vars=$PWD/array-vars.yml
	cat > "$inv" <<INV
[fleet]
three ansible_host=127.0.0.1 ansible_port=$(cat port) ansible_user=gavin ansible_ssh_private_key_file=$PWD/key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
[control]
localhost
INV
	( umask 077; printf 'ansible_become_password: "%s"\narray_passphrase: "%s"\narray_passphrase_again: "%s"\n' \
		"$password" "$p1" "$p2" > "$vars" )
	install -d -m 700 "$HOME/.ssh/cp"
	# COLUMNS: wide, so the callback wraps no sentence the checks below look for.
	( cd "$repo/ansible" && COLUMNS=400 ANSIBLE_CONFIG=$repo/ansible/ansible.cfg ansible-playbook -i "$inv" \
		playbooks/server-create-three-array.yml -e "device=$dev" -e "confirm_device=$dev" -e "@$vars" "$@" \
		) < /dev/null > "$log" 2>&1 || rc=$?
	rm -f "$inv" "$vars"
	for s in "$password" "$p1" "$p2"; do
		if grep -qF -- "$s" "$log"; then
			echo "FAIL a secret appeared in the play's output ($log)"
			sed -i "s/$s/<secret>/g" "$log"
		fi
	done
	return "$rc"
}

# The play against the blank drive: --check first, which must write nothing, then the real
# run, then a second run, which must change nothing, as the first run against the owner's
# own array will. Then what it must refuse, each leaving the drive as it was.
array_plays() {
	local dev=$1 stranger=$2 rc
	if ! command -v ansible-playbook >/dev/null; then
		if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "FAIL no ansible-playbook here"; else echo "SKIP no ansible-playbook here"; fi
		return 0
	fi
	rc=0; array_play array-check.log "$dev" "$luks_password" "$luks_password" --check || rc=$?
	sed 's/^/    | /' array-check.log | tail -n 12
	if [ "$rc" = 0 ] && grep -q 'DRY RUN, nothing written' array-check.log &&
		[ -z "$(printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' wipefs -n $dev")" ]; then
		echo "PASS --check says what it would do, and the drive is still blank"
	else
		echo "FAIL --check failed (exit $rc) or wrote to the drive"
	fi

	rc=0; array_play array.log "$dev" "$luks_password" "$luks_password" || rc=$?
	sed 's/^/    | /' array.log | tail -n 16
	if [ "$rc" = 0 ] && grep -q 'Proved from what reads back' array.log; then
		echo "PASS the play made the array"
	else
		echo "FAIL the play could not make the array (exit $rc):"
		grep -B2 -A6 'FAILED' array.log | head -n 30 | sed 's/^/    | /'
	fi

	# The repo's callback shows a debug task as DONE, so a CHANGED line is a real change.
	rc=0; array_play array-again.log "$dev" "$luks_password" "$luks_password" || rc=$?
	sed 's/^/    | /' array-again.log | tail -n 10
	if [ "$rc" = 0 ] && ! grep -q ' CHANGED$' array-again.log && grep -q 'nothing was changed' array-again.log; then
		echo "PASS a second run adopts the array and changes nothing"
	else
		echo "FAIL the second run failed (exit $rc) or changed something:"
		grep -E ' (CHANGED|FAILED)$' array-again.log | sed 's/^/    | /'
	fi

	rc=0; array_play array-again-check.log "$dev" "$luks_password" "$luks_password" --check || rc=$?
	if [ "$rc" = 0 ] && grep -q 'a real run would change nothing' array-again-check.log; then
		echo "PASS --check on the array says a run would change nothing"
	else
		echo "FAIL --check on the array failed (exit $rc) or found something to change:"
		tail -n 12 array-again-check.log | sed 's/^/    | /'
	fi

	echo "-- what the play must refuse"
	rc=0; array_play array-wrong.log "$dev" wrong-passphrase wrong-passphrase || rc=$?
	if [ "$rc" != 0 ] && grep -q 'The passphrase did not open' array-wrong.log && ! grep -q ' CHANGED$' array-wrong.log; then
		echo "PASS a wrong passphrase is refused, and nothing written: $(grep -m1 -o 'cryptsetup refused.*' array-wrong.log)"
	else
		echo "FAIL a wrong passphrase was not refused as one (exit $rc):"
		tail -n 12 array-wrong.log | sed 's/^/    | /'
	fi
	rc=0; array_play array-differ.log "$dev" "$luks_password" "${luks_password}x" || rc=$?
	if [ "$rc" != 0 ] && grep -q 'The two passphrases differ' array-differ.log; then
		echo "PASS two passphrases that differ are refused"
	else
		echo "FAIL two passphrases that differ were not refused (exit $rc)"
	fi
	rc=0; array_play array-stranger.log "$stranger" "$luks_password" "$luks_password" || rc=$?
	if [ "$rc" != 0 ] && grep -q 'holds a signature, so it is not new' array-stranger.log &&
		[ "$(printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' blkid -p -s LABEL -o value $stranger")" = stranger ]; then
		echo "PASS a drive holding a filesystem is refused and left as it was: $(grep -m1 -o 'holds a signature.*' array-stranger.log | head -c 120)"
	else
		echo "FAIL the drive holding ext4 was not refused as one (exit $rc):"
		tail -n 12 array-stranger.log | sed 's/^/    | /'
	fi
}

sim_after_firstboot() {
	local dev
	echo "===== three's tunnel, as server-create-host-tunnel.yml and install-system-file leave it"
	# Stand-in credentials, and a config in the shape of every host's, then the start the
	# README gives once the config is in place.
	if ! { printf '%s\n' "$password"; cat <<TUNNEL; } | ssh_as gavin@127.0.0.1 "sudo -S -p '' bash -s" 2>&1 | sed 's/^/    /'; then
set -e
install -d -m 755 /etc/cloudflared
( umask 077; printf '{"AccountTag":"sim","TunnelSecret":"c2lt","TunnelID":"$tunnel_id"}\n' > /etc/cloudflared/three.json )
printf '%s\n' 'tunnel: $tunnel_id' 'credentials-file: /etc/cloudflared/three.json' \
	'metrics: 127.0.0.1:20241' 'ingress:' '  - hostname: ssh-three.sim.invalid' \
	'    service: ssh://127.0.0.1:22' '  - service: http_status:404' > /etc/cloudflared/config.yml
systemctl start --no-block cloudflared
TUNNEL
		echo "FAIL could not put the stand-in tunnel in place"
	fi
	sleep 5
	if printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl show -p ActiveState --value cloudflared" | grep -qE '^(active|activating)$'; then
		echo "PASS cloudflared starts once its config is in place"
	else
		echo "FAIL cloudflared did not start once its config was in place"
	fi

	echo "===== the array, made by server-create-three-array.yml and unlocked as the README says"
	dev=$(ssh_as gavin@127.0.0.1 "lsblk -dnbro NAME,SIZE" | awk -v s="$mirror_bytes" '$1 ~ /^sd/ && $2 == s { print "/dev/" $1 }' || true)
	stranger=$(ssh_as gavin@127.0.0.1 "lsblk -dnbro NAME,SIZE" | awk -v s="$stranger_bytes" '$1 ~ /^sd/ && $2 == s { print "/dev/" $1 }' || true)
	echo "the blank drive is ${dev:-not found}; the one holding ext4 is ${stranger:-not found}"
	array_plays "$dev" "$stranger"
	# make-mirror stays beside the play for now, so its refusal is still checked. The copy
	# under test, not the box's checkout, which is main's until the deploy stage.
	ssh_as gavin@127.0.0.1 "cat > /tmp/make-mirror" < "$repo/hosts/three/leap/make-mirror" ||
		echo "FAIL could not copy make-mirror to the box"
	if { printf '%s\n' "$password" "$dev"; } |
		ssh_as gavin@127.0.0.1 "sudo -S -p '' bash /tmp/make-mirror $dev" > make-mirror-again.log 2>&1; then
		echo "FAIL make-mirror erased a drive that already holds the array"
	elif grep -q 'not new\|mirror-luks exists' make-mirror-again.log; then
		echo "PASS make-mirror refuses a drive that is not new"
	else
		echo "FAIL make-mirror refused for another reason: $(tail -n 1 make-mirror-again.log)"
	fi
	# A FAIL is already printed; returning keeps the run from dying silently under set -e.
	sim_unlock || return 0
	as_root three-unlocked.sh first
	sim_backup
}

# zero's push, from the runner standing in for zero: the options are read out of zero's own
# script, and the key is the one three's authorized_keys names. Then what the key must not
# do, and a push against the locked array.
sim_backup() {
	local opts rsh rc
	echo "===== zero's backup, pushed as hosts/zero/system/mirror-backup pushes it"
	opts=$(sed -n 's/^rsync_opts="\(.*\)"$/\1/p' "$repo/hosts/zero/system/mirror-backup")
	echo "rsync options from zero's script: $opts"
	rsh="ssh -i $PWD/backup-key -p $(cat port) -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=$PWD/known"
	# A file as Immich leaves one, owned by gavin's uid and not world-readable, pushed by root
	# as zero's cron pushes, so owner and mode go across as numbers.
	sudo rm -rf push && mkdir -p push/library
	echo one > push/library/a.jpg && echo two > push/library/b.jpg
	chmod 640 push/library/a.jpg && sudo chown 1000:1000 push/library/a.jpg
	# shellcheck disable=SC2086,SC2024  # opts is a list of options; the log is the runner's
	if sudo rsync $opts -e "$rsh" push/library "backup@127.0.0.1::incoming/immich/" > push.log 2>&1; then
		echo "PASS a push lands in incoming"
	else
		echo "FAIL the push was refused:"
		sed 's/^/    /' push.log
		printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' journalctl -b --no-pager -u sshd" | tail -n 8 | sed 's/^/    /'
	fi
	as_root three-backup.sh pushed
	sudo rm push/library/b.jpg && echo three > push/library/c.jpg
	# shellcheck disable=SC2086,SC2024
	sudo rsync $opts -e "$rsh" push/library "backup@127.0.0.1::incoming/immich/" > push.log 2>&1 || true
	as_root three-backup.sh mirrored

	echo "-- what the key must not do"
	if ssh -i backup-key -p "$(cat port)" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=known backup@127.0.0.1 'echo SIM-SHELL-OPENED' 2>&1 < /dev/null | grep -q SIM-SHELL-OPENED; then
		echo "FAIL the key ran a command of its own"
	else
		echo "PASS the key runs no command of its own"
	fi
	rm -rf pulled
	# Refused for the module's own reason, not for any error at all.
	if rsync -e "$rsh" "backup@127.0.0.1::incoming/immich/library/a.jpg" pulled > pull.log 2>&1 || [ -e pulled ]; then
		echo "FAIL a file was read back through the key"
	elif grep -q 'module is write only' pull.log; then
		echo "PASS no file can be read back: $(grep -m1 'write only' pull.log)"
	else
		echo "FAIL the read was refused, but not as write-only: $(tail -n 2 pull.log | tr '\n' ' ')"
	fi
	if rsync -e "$rsh" "backup@127.0.0.1::" 2>&1 | grep -q incoming; then
		echo "FAIL the module is listed to the key"
	else
		echo "PASS the module is not even listed"
	fi
	# Writes aimed at /tmp, which the backup user may write to (three-backup.sh shows it
	# first), so only the module's confinement can stop them: a name climbing out with ..,
	# and symlinks to /tmp, absolute and relative, written through.
	echo escape > escape
	rsync -e "$rsh" escape "backup@127.0.0.1::incoming/../../../../tmp/escape-dots" > /dev/null 2>&1 || true
	sudo rm -rf link && mkdir -p link && ln -s /tmp link/abs && ln -s ../../../../../../tmp link/rel
	rsync -a -e "$rsh" link/ "backup@127.0.0.1::incoming/link/" > /dev/null 2>&1 || true
	rsync -e "$rsh" escape "backup@127.0.0.1::incoming/link/abs/escape-abs" > /dev/null 2>&1 || true
	rsync -e "$rsh" escape "backup@127.0.0.1::incoming/link/rel/escape-rel" > /dev/null 2>&1 || true
	as_root three-backup.sh confined
	# Forwarding is asked for only when a connection comes through, so one is made, to
	# three's own sshd at an address PermitOpen allows; gavin's key, which may forward
	# there, shows the test can see a forward that works.
	local who k banner fpid
	for who in gavin backup; do
		k=key; [ "$who" = backup ] && k=backup-key
		ssh -i "$k" -p "$(cat port)" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=known -N -L 127.0.0.1:2299:192.168.86.103:22 "$who@127.0.0.1" > fwd.log 2>&1 &
		fpid=$!
		sleep 5
		banner=$(timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2299; head -c 7 <&3' 2>/dev/null || true)
		kill "$fpid" 2>/dev/null || true
		wait "$fpid" 2>/dev/null || true
		case "$who:$banner" in
		gavin:SSH-2.0) echo "PASS a forward that is allowed is seen, through gavin's key" ;;
		gavin:*) echo "FAIL the forwarding test cannot see even gavin's allowed forward: $(tail -n 1 fwd.log)" ;;
		backup:SSH-2.0) echo "FAIL the backup key forwarded a connection" ;;
		backup:*) echo "PASS the backup key forwards nothing: $(grep -m1 -i 'open failed\|prohibited' fwd.log || echo refused)" ;;
		esac
	done

	echo "-- against the locked array, then unlocked"
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service; and test ! -e /dev/mapper/mirror; and echo locked" ||
		echo "FAIL the README's lock command failed"
	# shellcheck disable=SC2086,SC2024
	if sudo rsync $opts -e "$rsh" push/library "backup@127.0.0.1::incoming/immich/" > push.log 2>&1; then
		echo "FAIL a push succeeded against the locked array"
	else
		echo "PASS a push against the locked array fails: $(grep -m1 -iE 'error|failed' push.log)"
	fi
	as_root three-backup.sh locked
	sim_unlock || return 0
	echo four > push/library/d.jpg
	# shellcheck disable=SC2086,SC2024
	if sudo rsync $opts -e "$rsh" push/library "backup@127.0.0.1::incoming/immich/" > push.log 2>&1; then
		echo "PASS the next push, once unlocked, succeeds"
	else
		echo "FAIL the push after the unlock was refused:"
		sed 's/^/    /' push.log
	fi
	as_root three-backup.sh after-lock
}

sim_after_reboot() {
	echo "===== the array after the reboot, unlocked again"
	sim_unlock || return 0
	as_root three-unlocked.sh again
}
