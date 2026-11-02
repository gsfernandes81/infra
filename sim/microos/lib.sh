# shellcheck shell=bash
# Shared by the simulations in this directory; sourced, never run. Every function works in
# the current directory, which the caller has made its own work directory.

image_url=https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2
ssh_port=2222

# Downloads Tumbleweed's current MicroOS image, checks it against the published checksum,
# and prints which build it is, because the image changes daily.
fetch_image() {
	local want have
	curl -fsSL -o microos.qcow2 "$image_url"
	curl -fsSL -o microos.qcow2.sha256 "$image_url.sha256"
	want=$(awk '{print $1; exit}' microos.qcow2.sha256)
	have=$(sha256sum microos.qcow2 | awk '{print $1}')
	if [ "$want" != "$have" ]; then
		echo "image checksum mismatch: want $want, have $have" >&2
		return 1
	fi
	echo "image: $(awk '{print $2; exit}' microos.qcow2.sha256) sha256 $have"
	qemu-img create -q -f qcow2 -F qcow2 -b microos.qcow2 disk.qcow2 30G
}

# Builds the Combustion config drive from <dir>/combustion/script, with a throwaway ssh
# key made for this run beside it. mke2fs -d fills the filesystem from a directory, so no
# mount and no root are needed.
make_config_drive() {
	local dir=$1
	rm -f key key.pub combustion.img
	ssh-keygen -q -t ed25519 -N '' -f key
	rm -rf cfg && mkdir -p cfg/combustion
	cp "$dir/combustion/script" cfg/combustion/script
	cp key.pub cfg/combustion/authorized_keys
	mke2fs -q -t ext4 -L combustion -d cfg combustion.img 16M
}

# Starts the VM in the background with the system disk, the config drive, a USB 3
# controller for the simulated USB disks, and a QMP socket for hot-plugging them. Extra
# qemu arguments follow. The system disk carries bootindex=0, so an extra disk added by a
# caller is never tried first.
boot_vm() {
	rm -f qmp.sock
	qemu-system-x86_64 \
		-enable-kvm -cpu host -m 4096 -smp 2 \
		-drive file="$PWD/disk.qcow2",if=none,id=sys,format=qcow2 \
		-device virtio-blk-pci,drive=sys,bootindex=0 \
		-drive file="$PWD/combustion.img",if=virtio,format=raw \
		-device qemu-xhci,id=xhci \
		-netdev user,id=n0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22 \
		-device virtio-net-pci,netdev=n0 \
		-qmp "unix:$PWD/qmp.sock,server=on,wait=off" \
		-display none -monitor none -serial "file:$PWD/serial.log" \
		-pidfile "$PWD/qemu.pid" -daemonize "$@"
}

# Waits for qemu to exit after the guest powers off.
wait_for_poweroff() {
	local pid i
	pid=$(cat qemu.pid)
	for i in $(seq 1 60); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 2
	done
	echo "qemu still running after 2 minutes; killing it" >&2
	kill "$pid" 2>/dev/null || true
}

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

# Reboots the guest and waits until a different boot id answers, so a VM that has not gone
# down yet is not taken for one that came back.
reboot_vm() {
	local before now i
	before=$(ssh_vm cat /proc/sys/kernel/random/boot_id)
	ssh_vm 'systemctl reboot' || true
	for i in $(seq 1 60); do
		sleep 5
		now=$(ssh_vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
		if [ -n "$now" ] && [ "$now" != "$before" ]; then
			break
		fi
	done
	wait_for_ssh
}
