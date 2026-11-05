# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054  # read by run-host.sh; commas belong to qemu
# three's stand-ins for sim/microos/run-host.sh; sourced, never run.
#
# three is a NEW host, so its stick is the one `make-stick --new` builds: no tunnel
# credentials, .env, secrets or volumes (run-host.sh leaves them out for a host with no
# tunnel config). After the first boot, the hooks below do what the visit does next: put a
# tunnel in place as server-create-host-tunnel.yml and install-system-file would, format
# the drive with make-mirror, and unlock it with the README's own command.

# zero's two values in the backup user's authorized_keys: the run's own backup key, which
# the runner pushes with as zero would, and the address the runner's connections arrive
# from, which is qemu's host address on this network.
rm -f backup-key backup-key.pub
ssh-keygen -q -t ed25519 -N '' -C 'sim zero mirror-backup' -f backup-key
declare -A standin=(
	[FILL-FROM-ZERO-BACKUP-KEY]="$(cat backup-key.pub)"
	[FILL-FROM-ZERO-TAILNET-ADDRESS]=192.168.86.1
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
# hooks find it on the box; make-mirror formats it there.
mirror_bytes=$((1536 * 1024 * 1024))
make_disks() {
	truncate -s "$mirror_bytes" mirror.img
	echo "a blank $((mirror_bytes / 1024 / 1024))M drive for the array"
}
disk_args=(
	-drive file="$PWD/mirror.img",if=none,id=mirror,format=raw
	-device usb-storage,bus=xhci.0,drive=mirror
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

	echo "===== the array, made by make-mirror and unlocked as the README says"
	dev=$(ssh_as gavin@127.0.0.1 "lsblk -dnbro NAME,SIZE" | awk -v s="$mirror_bytes" '$2 == s { print "/dev/" $1 }' || true)
	echo "the blank drive is ${dev:-not found}"
	# The script under test, not the box's checkout, which is main's until the deploy stage.
	ssh_as gavin@127.0.0.1 "cat > /tmp/make-mirror" < "$repo/hosts/three/leap/make-mirror" ||
		echo "FAIL could not copy make-mirror to the box"
	if { printf '%s\n' "$password" "$dev" "$luks_password" "$luks_password"; } |
		ssh_as gavin@127.0.0.1 "sudo -S -p '' bash /tmp/make-mirror $dev" > make-mirror.log 2>&1; then
		echo "PASS make-mirror made the array"
	else
		echo "FAIL make-mirror could not make the array"
	fi
	sed 's/^/    /' make-mirror.log
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
	if rsync -e "$rsh" "backup@127.0.0.1::incoming/immich/library/a.jpg" pulled > pull.log 2>&1 || [ -e pulled ]; then
		echo "FAIL a file was read back through the key"
	else
		echo "PASS no file can be read back: $(tail -n 1 pull.log)"
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
		"sudo -S -p '' systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service" ||
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
