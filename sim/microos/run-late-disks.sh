#!/bin/bash
# What happens when the USB disks behind a bcache + btrfs RAID1 array appear after boot,
# as zero's do: builds the array on three simulated USB disks, boots once without them,
# hot-plugs them, and reports at each stage. Then reboots with them present. CI runs it
# (.github/workflows/microos-sim.yml); sim/microos/README.md says what it shows.
#
# Usage: sim/microos/run-late-disks.sh <workdir>. It writes only inside <workdir>.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-late-disks.sh <workdir>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

fetch_image
make_config_drive "$here/late-disks"
qemu-img create -q -f qcow2 cache.qcow2 2G
qemu-img create -q -f qcow2 back0.qcow2 4G
qemu-img create -q -f qcow2 back1.qcow2 4G

# The disks as qemu arguments at boot, and as monitor commands for a hot-plug. The serials
# are how setup.sh tells them apart.
disk_args=()
disk_cmds=()
for d in cache back0 back1; do
	serial=SIM$(echo "$d" | tr '[:lower:]' '[:upper:]')
	# Absolute paths: qemu's -daemonize moves its working directory to /.
	disk_args+=(-drive "if=none,id=$d,file=$PWD/$d.qcow2,format=qcow2"
		-device "usb-storage,bus=xhci.0,drive=$d,id=u$d,serial=$serial")
	disk_cmds+=("drive_add 0 if=none,id=$d,file=$PWD/$d.qcow2,format=qcow2"
		"device_add usb-storage,bus=xhci.0,drive=$d,id=u$d,serial=$serial")
done

stage() { printf '\n##### %s\n' "$1" | tee -a report.txt; }
state() { ssh_vm 'bash -s' < "$here/late-disks/state.sh" | tee -a report.txt; }

: > report.txt
stage "first boot, disks attached: building the array"
boot_vm "${disk_args[@]}"
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
ssh_vm 'bash -s' < "$here/late-disks/setup.sh" 2>&1 | tee -a report.txt
ssh_vm 'systemctl poweroff' || true
wait_for_poweroff

stage "boot without the disks"
boot_vm
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
state

stage "60 s later: the three disks hot-plugged"
sleep 60
python3 -I "$here/qmp.py" qmp.sock "${disk_cmds[@]}" | tee -a report.txt
sleep 45
state

stage "the same, after asking systemd for the mount and the service by hand"
ssh_vm 'systemctl start media-array.mount sim-consumer.service' 2>&1 | tee -a report.txt || true
state

stage "reboot with the disks present"
reboot_vm
ssh_vm 'systemctl is-system-running --wait' || true
state

stage "tuning: a 180 s device timeout and a udev rule that asks for the mount"
ssh_vm 'bash -s' < "$here/late-disks/tune.sh" 2>&1 | tee -a report.txt
ssh_vm 'systemctl poweroff' || true
wait_for_poweroff

stage "boot without the disks, which are plugged 20 s after power-on"
boot_vm
sleep 20
python3 -I "$here/qmp.py" qmp.sock "${disk_cmds[@]}" | tee -a report.txt
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
ssh_vm 'systemd-analyze blame --no-pager | grep -E "media-array|sim-consumer"' 2>&1 | tee -a report.txt || true
state
ssh_vm 'systemctl poweroff' || true
wait_for_poweroff

stage "boot without the disks, which are plugged 4 minutes after power-on, after the timeout"
boot_vm
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
sleep_left=$((240 - 60))
sleep "$sleep_left"
python3 -I "$here/qmp.py" qmp.sock "${disk_cmds[@]}" | tee -a report.txt
sleep 45
state

kill "$(cat qemu.pid)" 2>/dev/null || true
