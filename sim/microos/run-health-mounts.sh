#!/bin/bash
# What stock health-checker does about the fleet's data mounts, with no plugin of ours: its
# btrfs-subvolumes-mounted plugin fails when an fstab entry with a subvol option has a
# failed mount unit, and ignores nofail. Which entries it selects, and what a data disk
# missing at boot or a mount that fails at once does to a good snapshot and to a new one,
# decide whether openSUSE's own rollback can strand a host whose disks are late. CI runs it
# (.github/workflows/microos-sim.yml); sim/microos/README.md says what it shows.
#
# It reports and does not judge: the job fails only when the harness does (no boot, no
# ssh), and the answers are the ANSWER lines.
#
# Usage: sim/microos/run-health-mounts.sh <workdir>. It writes only inside <workdir>.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-health-mounts.sh <workdir>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

# qemu daemonizes, so it outlives the script unless something stops it, on any exit.
trap 'kill "$(cat qemu.pid 2>/dev/null)" 2>/dev/null || true' EXIT

stage() { printf '\n##### %s\n' "$1" | tee -a report.txt; }
state() { ssh_vm 'bash -s' < "$here/health-mounts/state.sh" | tee -a report.txt || true; }
answer() { echo "ANSWER: $*" | tee -a report.txt; }
default_snapshot() {
	ssh_vm 'btrfs subvolume get-default / | sed -n "s|.*/\.snapshots/\([0-9]*\)/snapshot.*|\1|p"'
}
boot_id() { ssh_vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }
disk=(-drive "if=none,id=data,file=$PWD/data.qcow2,format=qcow2"
	-device "usb-storage,bus=xhci.0,drive=data,id=udata,serial=SIMDATA")

# Powers the guest off and boots it again, with the data disk or without, then waits past
# the 180 s device timeout so every late mount has had its chance to fail, through any
# reboot health-checker makes meanwhile. Fails if the guest stops answering.
power_cycle() {
	local before
	before=$(boot_id)
	ssh_vm 'systemctl poweroff' || true
	wait_for_poweroff
	if [ "$1" = with ]; then boot_vm "${disk[@]}"; else boot_vm; fi
	wait_for_new_boot "$before" || return 1
	for _ in $(seq 1 60); do
		[ "$(ssh_vm 'cut -d. -f1 /proc/uptime' 2>/dev/null || echo 0)" -ge 240 ] && break
		sleep 5
	done
	[ -n "$(boot_id)" ]
}
# Reboots and waits for the guest to settle, through any reboots health-checker adds.
reboot_settle() {
	local before
	before=$(boot_id)
	ssh_vm 'systemctl reboot' || true
	wait_for_new_boot "$before"
}
# For a guest that stopped answering: what its screen and serial log show, then the end
# of the run, since every later stage needs ssh.
stranded() {
	answer "$1: the box STOPPED ANSWERING; the screens and serial log follow"
	screenshots
	tail -n 40 serial.log | tee -a report.txt
	exit 0
}

: > report.txt
fetch_image | tee -a report.txt
make_config_drive "$here/health-mounts"
qemu-img create -q -f qcow2 data.qcow2 2G

stage "first boot, the data disk attached: three fstab shapes"
boot_vm "${disk[@]}"
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
ssh_vm 'rpm -q health-checker; systemctl cat health-checker.service | grep -E "^(After|Before|Wants|Requires)="' \
	| tee -a report.txt
ssh_vm 'bash -s' < "$here/health-mounts/setup.sh" 2>&1 | tee -a report.txt
picked=$(ssh_vm 'findmnt --types btrfs --options subvol --fstab --output target --raw --noheadings' | tr '\n' ' ')
answer "the plugin's own findmnt selects: ${picked:-nothing} (of /media/sv subvol=, /media/svid subvolid=, /media/whole no option)"

stage "a reboot with the disk, so health-checker records this snapshot as good"
reboot_settle || stranded "a reboot with the disk"
state
good=$(default_snapshot)
echo "good snapshot: $good" | tee -a report.txt

stage "the good snapshot, booted without the data disk"
power_cycle without || stranded "missing disk on a good snapshot"
state
answer "missing disk on a good snapshot: default snapshot $(default_snapshot) (good was $good), $(ssh_vm 'journalctl --list-boots --no-pager | wc -l') boots so far, system $(ssh_vm 'systemctl is-system-running' || true)"

stage "an update, then its first boot without the data disk"
ssh_vm "transactional-update --non-interactive run touch /usr/share/sim-update" 2>&1 \
	| tail -n 3 | tee -a report.txt
new=$(default_snapshot)
power_cycle without || stranded "missing disk on an update's first boot"
state
now=$(default_snapshot)
if [ "$now" = "$new" ]; then
	answer "missing disk on an update's first boot: the update ($new) was kept"
else
	answer "missing disk on an update's first boot: default is $now, the update was $new, so it was ROLLED BACK"
fi

stage "the disk back, and a mount that fails at once (subvol=does-not-exist), then a reboot"
power_cycle with || stranded "booting with the disk back"
ssh_vm "uuid=\$(findmnt -no UUID /media/whole); echo \"UUID=\$uuid /media/bad btrfs nofail,subvol=does-not-exist 0 0\" >> /etc/fstab; systemctl daemon-reload; tail -n 1 /etc/fstab" \
	| tee -a report.txt
reboot_settle || stranded "a mount failing at once on a good snapshot"
state
answer "a mount failing at once on a good snapshot: the box answers ssh, default snapshot $(default_snapshot), system $(ssh_vm 'systemctl is-system-running' || true)"

echo
echo "done; the ANSWER lines are the findings" | tee -a report.txt
