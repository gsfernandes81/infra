#!/bin/bash
# What happens when the USB disks behind a bcache + btrfs RAID1 array appear after boot,
# as zero's do: builds the array on three simulated USB disks, boots without them, plugs
# them in at chosen moments, and reports at each stage. CI runs it once per variant
# (.github/workflows/microos-sim.yml); sim/microos/README.md says what each shows.
#
# Usage: sim/microos/run-late-disks.sh <workdir> <plain|wantedby|udev>
# It writes only inside <workdir>.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-late-disks.sh <workdir> <variant>}
variant=${2:?usage: run-late-disks.sh <workdir> <variant>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

fetch_image
make_config_drive "$here/late-disks"
qemu-img create -q -f qcow2 cache.qcow2 2G
qemu-img create -q -f qcow2 back0.qcow2 4G
qemu-img create -q -f qcow2 back1.qcow2 4G

# One disk as qemu arguments at boot, or as monitor commands for a hot-plug. Absolute
# paths, because qemu's -daemonize moves its working directory to /. The serials are how
# setup.sh tells the disks apart.
serial_of() { echo "SIM$(echo "$1" | tr '[:lower:]' '[:upper:]')"; }
disk_args=()
for d in cache back0 back1; do
	disk_args+=(-drive "if=none,id=$d,file=$PWD/$d.qcow2,format=qcow2"
		-device "usb-storage,bus=xhci.0,drive=$d,id=u$d,serial=$(serial_of "$d")")
done
plug() {
	local cmds=() d
	for d in "$@"; do
		cmds+=("drive_add 0 if=none,id=$d,file=$PWD/$d.qcow2,format=qcow2"
			"device_add usb-storage,bus=xhci.0,drive=$d,id=u$d,serial=$(serial_of "$d")")
	done
	echo "plugged at $(date -u +%T), in the order: $*" | tee -a report.txt
	python3 -I "$here/qmp.py" qmp.sock "${cmds[@]}" | tee -a report.txt
}

stage() { printf '\n##### %s\n' "$1" | tee -a report.txt; }
state() { ssh_vm 'bash -s' < "$here/late-disks/state.sh" | tee -a report.txt; }

# The guest must see three USB disks after a plug, or a later "no bcache" would be a
# failed plug and not a finding.
assert_three_disks() {
	local n i
	for i in $(seq 1 30); do
		n=$(ssh_vm "lsblk -dno TRAN | grep -c usb" || true)
		[ "$n" = 3 ] && { echo "guest sees 3 USB disks"; return 0; }
		sleep 2
	done
	echo "guest sees ${n:-no} USB disks, not 3: the plug failed" | tee -a report.txt >&2
	return 1
}

# Polls for the mount for up to 90 s and reports how long it took, rather than sleeping a
# fixed time and reading a slow runner as "never".
wait_for_mount() {
	local i
	for i in $(seq 1 45); do
		if ssh_vm 'mountpoint -q /media/array'; then
			echo "array mounted ~$((i * 2)) s after the check began" | tee -a report.txt
			return 0
		fi
		sleep 2
	done
	echo "array NOT mounted after 90 s of polling" | tee -a report.txt
}

: > report.txt
echo "variant: $variant" | tee -a report.txt

stage "first boot, disks attached: building the array"
boot_vm "${disk_args[@]}"
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
ssh_vm "VARIANT=$variant bash -s" < "$here/late-disks/setup.sh" 2>&1 | tee -a report.txt
ssh_vm 'systemctl poweroff' || true
wait_for_poweroff

stage "boot without the disks"
boot_vm
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
state

stage "after boot and the default 90 s device timeout: the disks plugged, cache first"
plug cache back0 back1
assert_three_disks
wait_for_mount
state

stage "the same, after asking systemd for the mount and the service by hand"
ssh_vm 'systemctl start media-array.mount sim-consumer.service' 2>&1 | tee -a report.txt || true
state

stage "reboot with the disks present"
reboot_vm
ssh_vm 'systemctl is-system-running --wait' || true
state

stage "tuning: a 180 s device timeout"
ssh_vm 'bash -s' < "$here/late-disks/tune.sh" 2>&1 | tee -a report.txt
ssh_vm 'systemctl poweroff' || true
wait_for_poweroff

stage "boot without the disks, plugged 120 s after power-on: past the default, inside 180 s"
boot_vm
sleep 120
plug cache back0 back1
wait_for_ssh
assert_three_disks
ssh_vm 'systemctl is-system-running --wait' || true
state
ssh_vm 'systemctl poweroff' || true
wait_for_poweroff

stage "boot without the disks, plugged after boot has given up on them, cache LAST"
boot_vm
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
plug back1 back0 cache
assert_three_disks
wait_for_mount
state

kill "$(cat qemu.pid)" 2>/dev/null || true
