# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054,SC2154  # read by run-host.sh; commas belong to qemu; $c, $here, $password and the helpers are run-host.sh's
# zero's stand-ins for sim/microos/run-host.sh; sourced, never run.
#
# zero has not moved, so run-host.sh tests a commit with hosts/zero/leap/MOVED and these
# stand-ins committed on top of the one under test, as the owner commits both before the
# day. Its stick is a moved box's, with zero's own carry-over besides: the array's key file,
# the Tailscale state, root's restore key with three's host key, Immich's .env and
# pearl-wallet's volume, and no secrets directory, which make-stick refuses on zero. Its
# disks are built in a VM of their own first (make_disks). After the play, the hooks below
# pull zero's snapshots as three would, and boot zero once with its array late.

# What the run makes up for zero's values: the run's key for three's pull, in the one key
# line backup-authorized-keys holds, and qemu's host address for three's tailnet address in
# its from=, since the runner's connections into the VM arrive from it (as in host/three.sh,
# where the same address stands in for zero's); a key for root's restore and one for
# three's host key in its known_hosts; the array's key file; and the Docker store's
# subvolume id, which make_disks gives the new store.
rm -f pull-key pull-key.pub restore-key restore-key.pub three-host three-host.pub data.key
ssh-keygen -q -t ed25519 -N '' -C 'sim three backup-pull' -f pull-key
ssh-keygen -q -t ed25519 -N '' -C 'sim zero restore' -f restore-key
ssh-keygen -q -t ed25519 -N '' -C 'sim three host' -f three-host
head -c 64 /dev/urandom > data.key
store_id=257
pull_line=$(grep '^restrict,' "$repo/hosts/zero/leap/system/backup-authorized-keys")
three_pull_key=${pull_line##*\" }
three_addr=$(printf '%s\n' "$pull_line" | sed -n 's/.*from="\([^"]*\)".*/\1/p')
if [ -z "$three_pull_key" ] || [ -z "$three_addr" ]; then
	echo "FAIL could not read three's key and address out of zero's backup-authorized-keys"
	exit 1
fi
declare -A standin=(
	[FILL-FROM-ZERO-STORE-SUBVOLID]=$store_id
	["$three_pull_key"]="$(cat pull-key.pub)"
	["$three_addr"]=192.168.86.1
)

# qemu's user network on zero's subnet, so its static address answers.
sim_net=192.168.86.0/24
sim_gateway=192.168.86.1
sim_dns=192.168.86.3
sim_address=192.168.86.100
sim_dhcp_address=192.168.86.15

tunnel_id=ce28c17c-a722-4ba1-8e46-21985337f13f

# Immich and Syncthing require no name from .env; anything asked for gets a made-up value.
standin_env() { openssl rand -hex 16; }
# The deploy stage plans these. pearl-wallet is left out: its image is built on the box,
# and its preflight hook refuses a volume with no wallet, which only the owner makes.
deployments=(immich syncthing)
carried=()
volumes=(pearl-wallet_wallet)

# The carry-over as make-stick writes it on zero, in place of run-host.sh's per-deployment
# one: Immich's .env alone, with the paths its .env.example names, and no secrets directory;
# then zero's own items. The key file is the one make_disks formats data-luks-4 with.
sim_carry() {
	rm -rf "${c:?}/env" "${c:?}/home"
	mkdir -p "$c/env" "$c/tailscale" "$c/root-ssh"
	printf '%s\n' UPLOAD_LOCATION=/media/immich/data DB_DATA_LOCATION=/media/immich/db \
		TZ=Etc/UTC "DB_PASSWORD=$(openssl rand -hex 16)" DB_USERNAME=postgres \
		DB_DATABASE_NAME=immich SIM_STANDIN=1 > "$c/env/immich.env"
	install -d -m 700 "$c/keys"
	install -m 400 data.key "$c/keys/data.key"
	# A state tailscaled can start from, with a key of the run's that it keeps when it
	# writes the file back, so the checks can tell the carried file from a new one.
	printf '{"_sim-marker":"c2lt"}\n' > "$c/tailscale/tailscaled.state"
	cp restore-key "$c/root-ssh/restore"
	cp restore-key.pub "$c/root-ssh/restore.pub"
	printf '%s %s\n' "$three_addr" "$(cut -d' ' -f1,2 three-host.pub)" > "$c/root-ssh/known_hosts"
	echo "zero's carry-over: Immich's .env, the key file, the Tailscale state, the restore key"
}

# ── zero's disks, built in a VM of their own ─────────────────────────────────
# The SSD and the two hard disks, on USB as zero's are, told apart by their serials. They
# are built inside a first, throwaway guest from the same image (host/zero-disks/), so
# make-bcache and cryptsetup never run on the runner. Its own work directory, so its key,
# config drive and qemu files leave the run's alone.
disk_spec() {
	local d
	for d in "$@"; do
		printf '%s\n' -drive "if=none,id=$d,file=$PWD/$d.qcow2,format=qcow2" \
			-device "usb-storage,bus=xhci.0,drive=$d,id=u$d,serial=SIM${d^^}"
	done
}
mapfile -t disk_args < <(disk_spec ssd back0 back1)
make_disks() {
	local base=$PWD/base.qcow2
	qemu-img create -q -f qcow2 ssd.qcow2 28G
	qemu-img create -q -f qcow2 back0.qcow2 4G
	qemu-img create -q -f qcow2 back1.qcow2 4G
	# A subshell for the directory; each step chained, since set -e does not reach inside
	# a command whose status is tested.
	(
		rm -rf disks && mkdir disks && cd disks &&
			qemu-img create -q -f qcow2 -F qcow2 -b "$base" disk.qcow2 40G &&
			make_config_drive "$here/host/zero-disks" &&
			boot_vm "${disk_args[@]}" &&
			wait_for_ssh &&
			ssh_vm 'cat > /root/data.key' < ../data.key &&
			ssh_vm "STORE_ID=$store_id bash -s" < "$here/host/zero-disks/build.sh" 2>&1 &&
			{ ssh_vm 'systemctl poweroff' || true; } &&
			wait_for_poweroff
	) || { echo "FAIL zero's disks could not be built"; return 1; }
}

# Hot-plugs disks into the running VM through qemu's QMP socket, as run-late-disks.sh does.
plug() {
	local cmds=() d
	for d in "$@"; do
		cmds+=("drive_add 0 if=none,id=$d,file=$PWD/$d.qcow2,format=qcow2"
			"device_add usb-storage,bus=xhci.0,drive=$d,id=u$d,serial=SIM${d^^}")
	done
	python3 -I "$here/qmp.py" qmp.sock "${cmds[@]}" > /dev/null
}

sim_after_setup() {
	sim_pull
	sim_late_array
}

# ── three's pull, from the runner standing in for three ──────────────────────
# The run's pull key, in the line the play installed for three's, with the runner's address
# in its from=. The listing of the snapshots module must name the newest timeline snapshot,
# which checks-zero.sh had snapperd take, so the forced command, sudo's rule, setpriv and
# the daemon's config are all proved at once.
sim_pull() {
	local newest out rsh
	rsh="ssh -i $PWD/pull-key -p $(cat port) -o StrictHostKeyChecking=no"
	rsh+=" -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
	echo "===== three's pull of zero's snapshots, from the runner"
	newest=$(root_sh "snapper --no-dbus --csvout -c immich list --columns number,description" |
		awk -F, '$2 == "timeline" { n = $1 } END { print n }')
	echo "    the newest timeline snapshot of immich: ${newest:-none}"
	if timeout 120 rsync -e "$rsh" backup@127.0.0.1::snapshots/ > pull-list.txt 2>&1 &&
		[ -n "$newest" ] && awk '{ print $NF }' pull-list.txt | grep -qx "$newest"; then
		echo "PASS three's key lists zero's snapshots through the forced rsync daemon, $newest included"
	else
		echo "FAIL three's key could not list zero's snapshots:"
		sed 's/^/    /' pull-list.txt
	fi
	sed 's/^/    | /' pull-list.txt
	# Any command asked for gets the daemon's greeting, never a shell's answer.
	# shellcheck disable=SC2086  # $rsh is the command line rsync is given, split as rsync splits it
	out=$(timeout 30 $rsh backup@127.0.0.1 id < /dev/null 2>&1 || true)
	case "$out" in
	*uid=*) echo "FAIL three's key ran a command on zero: $out" ;;
	*@RSYNCD*) echo "PASS three's key gets the rsync daemon whatever it asks for" ;;
	*) echo "FAIL three's key got neither the daemon nor a shell: $out" ;;
	esac
}

# ── a late array ─────────────────────────────────────────────────────────────
# The owner's call 7 (plans/zero-leap.md § A late or missing array): no guard, Docker's
# restart loop brings a container back once the array mounts. A stand-in container under
# restart: always that exits without the array's marker, then zero powered off and booted
# with the SSD alone, so Docker and the container start on the bare mountpoints, then both
# hard disks plugged in, inside the device timeout. bcache, data-4, btrfs and the mounts
# must come up by themselves, and the container on the array, with nobody at the box.
sim_late_array() {
	local t0 at i n ok ssd_only
	echo "===== a late array: zero booted without its hard disks, then given them"
	root_sh "docker run -d --restart always --name sim-late -v /media/immich:/data:ro \
		docker.io/library/alpine:3.22 sh -c 'cat /data/marker && exec sleep infinity'" > /dev/null ||
		echo "FAIL could not start the stand-in container on the array"
	root_sh 'systemctl poweroff' || true
	wait_for_poweroff
	t0=$(date +%s)
	mapfile -t ssd_only < <(disk_spec ssd)
	boot_vm "${ssd_only[@]}"
	wait_gavin static
	root_sh 'mountpoint -q /media/immich' &&
		echo "FAIL /media/immich is mounted with the hard disks out" ||
		echo "PASS with the hard disks out, /media/immich is the bare mountpoint"
	for i in $(seq 1 20); do
		n=$(root_sh "docker inspect -f '{{.RestartCount}}' sim-late" || true)
		[ "${n:-0}" -gt 0 ] 2>/dev/null && break
		sleep 3
	done
	echo "    the container meanwhile: $(root_sh "docker inspect -f 'restarts={{.RestartCount}} running={{.State.Running}}' sim-late")"
	# Its log keeps the runs before the power-off, which read the marker, so what counts is
	# the last line now and how many reads there are before the plug.
	root_sh 'docker logs sim-late 2>&1 | tail -n 1' | grep -q 'No such file' &&
		echo "PASS the container fails on the bare mountpoint, and Docker keeps restarting it" ||
		echo "FAIL the container is not failing on the bare mountpoint: $(root_sh 'docker logs sim-late 2>&1 | tail -n 1')"
	n=$(root_sh 'docker logs sim-late 2>&1 | grep -cx marker' || true)
	at=$(($(date +%s) - t0))
	plug back0 back1 || echo "FAIL could not plug the hard disks in"
	# The device timeout runs from early in the boot, so a plug past it tests another case.
	if [ "$at" -lt 170 ]; then
		echo "    plugged both hard disks ${at}s after power-on, inside the 180 s device timeout"
	else
		echo "FAIL the hard disks went in ${at}s after power-on, too late to be inside the 180 s device timeout"
	fi
	ok=
	for i in $(seq 1 60); do
		if root_sh 'mountpoint -q /media/immich && mountpoint -q /media/syncthing'; then
			ok=$((i * 3))
			break
		fi
		sleep 3
	done
	if [ -n "$ok" ]; then
		echo "PASS the array opened and mounted by itself, ~${ok}s after the plug"
	else
		echo "FAIL the array did not mount within 3 minutes of the plug:"
		root_sh 'cat /sys/block/bcache*/bcache/state; systemctl --no-pager status "systemd-cryptsetup@data\x2d4.service" media-immich.mount | head -n 30' 2>&1 | sed 's/^/    /'
	fi
	ok=
	for i in $(seq 1 50); do
		if [ "$(root_sh "docker inspect -f '{{.State.Running}}' sim-late")" = true ] &&
			[ "$(root_sh 'docker logs sim-late 2>&1 | grep -cx marker' || true)" -gt "${n:-0}" ]; then
			ok=yes
			break
		fi
		sleep 3
	done
	[ -n "$ok" ] &&
		echo "PASS the container on the array came back by itself: $(root_sh "docker inspect -f 'restarts={{.RestartCount}}' sim-late")" ||
		echo "FAIL the container on the array did not come back: $(root_sh 'docker logs sim-late 2>&1 | tail -n 3')"
	root_sh 'docker rm -f sim-late' > /dev/null || true
}
