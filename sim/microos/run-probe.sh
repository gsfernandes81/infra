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

image_url=https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2
ssh_port=2222

# Tumbleweed's image moves daily, so the report records which one was tested.
curl -fsSL -o microos.qcow2 "$image_url"
curl -fsSL -o microos.qcow2.sha256 "$image_url.sha256"
want=$(awk '{print $1; exit}' microos.qcow2.sha256)
have=$(sha256sum microos.qcow2 | awk '{print $1}')
if [ "$want" != "$have" ]; then
	echo "image checksum mismatch: want $want, have $have" >&2
	exit 1
fi
echo "image: $(awk '{print $2; exit}' microos.qcow2.sha256) sha256 $have"

qemu-img create -q -f qcow2 -F qcow2 -b microos.qcow2 disk.qcow2 30G

# A fresh key per run; nothing outlives the runner.
rm -f key key.pub
ssh-keygen -q -t ed25519 -N '' -f key
rm -rf cfg && mkdir -p cfg/combustion
cp "$here/probe/combustion/script" cfg/combustion/script
cp key.pub cfg/combustion/authorized_keys
# mke2fs -d fills the filesystem from a directory, so no mount and no root are needed.
rm -f combustion.img
mke2fs -q -t ext4 -L combustion -d cfg combustion.img 16M

qemu-system-x86_64 \
	-enable-kvm -cpu host -m 4096 -smp 2 \
	-drive file=disk.qcow2,if=virtio,format=qcow2 \
	-drive file=combustion.img,if=virtio,format=raw \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22 \
	-device virtio-net-pci,netdev=n0 \
	-display none -monitor none -serial file:serial.log \
	-pidfile qemu.pid -daemonize

ssh_vm() {
	ssh -q -i key -p "$ssh_port" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
		root@127.0.0.1 "$@"
}

wait_for_ssh() {
	local i
	for i in $(seq 1 120); do
		if ssh_vm true 2>/dev/null; then
			echo "ssh up after ~$((i * 5))s"
			return 0
		fi
		sleep 5
	done
	echo "no ssh after 10 minutes; serial log follows" >&2
	tail -n 80 serial.log >&2
	return 1
}

wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
{
	echo "##### first boot"
	ssh_vm 'bash -s' < "$here/probe/checks.sh"
} | tee report.txt

# A reboot proves the snapshot Combustion left is the one that boots, and that Docker and
# the reboot policy survive it. The boot id tells a rebooted VM from one that has not gone
# down yet.
boot_before=$(ssh_vm cat /proc/sys/kernel/random/boot_id)
ssh_vm 'systemctl reboot' || true
for i in $(seq 1 60); do
	sleep 5
	boot_now=$(ssh_vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
	if [ -n "$boot_now" ] && [ "$boot_now" != "$boot_before" ]; then
		break
	fi
done
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
{
	echo
	echo "##### after one reboot"
	ssh_vm 'snapper list --columns number,date,description | tail -n 5; getenforce;
		systemctl is-active docker; rebootmgrctl get-strategy'
} | tee -a report.txt

kill "$(cat qemu.pid)" 2>/dev/null || true
