#!/bin/bash
# Boots openSUSE MicroOS (x86_64, KVM) with the probe's Combustion config and prints what
# sim/microos/probe/checks.sh finds, then reboots once and checks it again. CI runs it
# (.github/workflows/microos-sim.yml); it also runs on any Linux box with KVM and qemu.
#
# Usage: sim/microos/run-probe.sh <workdir>
# It writes only inside <workdir>: the image, an overlay, the config drive, a throwaway
# ssh key, the serial log and report.txt.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-probe.sh <workdir>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

fetch_image
make_config_drive "$here/probe"
# shellcheck disable=SC2119  # boot_vm takes extra qemu arguments, none here
boot_vm

wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
{
	echo "##### first boot"
	ssh_vm 'bash -s' < "$here/probe/checks.sh"
} | tee report.txt

# A reboot proves the snapshot Combustion left is the one that boots, and that Docker and
# the reboot policy survive it.
reboot_vm
ssh_vm 'systemctl is-system-running --wait' || true
{
	echo
	echo "##### after one reboot"
	ssh_vm 'snapper list --columns number,date,description | tail -n 5; getenforce;
		systemctl is-active docker; rebootmgrctl get-strategy'
} | tee -a report.txt

kill "$(cat qemu.pid)" 2>/dev/null || true
