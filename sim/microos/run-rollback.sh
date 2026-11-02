#!/bin/bash
# Whether health-checker rolls a MicroOS box back from an update that breaks the service
# its plugin checks, keeps one that does not, and what it does when that check fails on a
# snapshot that has already booted fine. CI runs it (.github/workflows/microos-sim.yml).
#
# Usage: sim/microos/run-rollback.sh <workdir>. It writes only inside <workdir>.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-rollback.sh <workdir>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

stage() { printf '\n##### %s\n' "$1" | tee -a report.txt; }
state() { ssh_vm 'bash -s' < "$here/rollback/state.sh" | tee -a report.txt; }

# Waits for the guest to answer on a boot other than <boot id>, through however many
# reboots health-checker makes on the way, then for it to settle.
wait_for_new_boot() {
	local before=$1 now i
	for i in $(seq 1 90); do
		sleep 5
		now=$(ssh_vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
		if [ -n "$now" ] && [ "$now" != "$before" ]; then
			# health-checker may reboot again; wait until the boot id holds for 60 s.
			sleep 60
			if [ "$(ssh_vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)" = "$now" ]; then
				ssh_vm 'systemctl is-system-running --wait' >/dev/null 2>&1 || true
				return 0
			fi
			before=$now
		fi
	done
	echo "the guest did not settle on a new boot" | tee -a report.txt >&2
	tail -n 60 serial.log >&2
	return 1
}

# What the screen shows, for a guest that stops answering: GRUB and the early boot write to
# the display, not to the serial log. Saves screen-<n>.png and qemu's run state.
screenshots() {
	local n
	for n in 1 2 3; do
		python3 -I "$here/qmp.py" qmp.sock "screendump $PWD/screen-$n.ppm" "info status" \
			| tee -a report.txt || true
		python3 -I "$here/ppm2png.py" "screen-$n.ppm" "screen-$n.png" \
			|| echo "screen-$n: could not convert; the .ppm is kept" | tee -a report.txt
		sleep 120
	done
}

# Reboots, counting the boots the guest goes through until it settles.
reboot_and_settle() {
	local before
	before=$(ssh_vm cat /proc/sys/kernel/random/boot_id)
	ssh_vm 'systemctl reboot' || true
	wait_for_new_boot "$before"
	ssh_vm 'journalctl --list-boots --no-pager | tail -n 4' | tee -a report.txt
}

: > report.txt
fetch_image | tee -a report.txt
make_config_drive "$here/rollback"
# shellcheck disable=SC2119  # boot_vm takes extra qemu arguments, none here
boot_vm
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true

stage "first boot"
state
ssh_vm 'bash -s' < "$here/rollback/cloudflared.sh" | tee -a report.txt

stage "a reboot with nothing changed, so health-checker records this snapshot as good"
reboot_and_settle
state

stage "an update that breaks the stand-in, then a reboot"
ssh_vm "transactional-update --non-interactive run sh -c 'echo \"exit 1\" > /usr/bin/sim-tunnel'" 2>&1 \
	| tail -n 5 | tee -a report.txt
reboot_and_settle
state

stage "an update that leaves the stand-in alone, then a reboot"
ssh_vm "transactional-update --non-interactive run touch /usr/share/sim-good-update" 2>&1 \
	| tail -n 5 | tee -a report.txt
reboot_and_settle
state
ssh_vm 'ls -l /usr/share/sim-good-update' 2>&1 | tee -a report.txt || true

stage "the check failing on a snapshot that has booted fine (/etc/sim-fail), then a reboot"
# The case the cloudflared plugin must never be able to cause, by an outage or by a
# mistake in /etc. Without the plugin's guard, health-checker rebooted once and then
# started emergency.target, and the guest never answered again; with it, the guest must
# come back on the same snapshot, reachable. If it does not, screenshots follow.
ssh_vm 'touch /etc/sim-fail'
if reboot_and_settle; then
	echo "SETTLED: the guest came back after a failing check on a good snapshot" | tee -a report.txt
	state
	ssh_vm 'rm -f /etc/sim-fail; systemctl list-units --state=active --type=service --no-pager --no-legend | wc -l' 2>&1 | tee -a report.txt || true
else
	echo "NO SETTLED BOOT: the guest is not answering; screenshots follow" | tee -a report.txt
	screenshots
	if wait_for_ssh; then
		echo "it answered after the screenshots" | tee -a report.txt
		state
	fi
fi

stage "forced into emergency.target on a good snapshot (/etc/sim-fail-hard): is there still a way in?"
# The guard cannot help here by design: the check fails whatever the snapshot. health-
# checker then reboots once and starts emergency.target. The kept units must leave ssh
# answering, with the stacks stopped.
ssh_vm 'rm -f /etc/sim-fail; rm -f /var/lib/misc/health-check.rebooted; touch /etc/sim-fail-hard' || true
# What systemd will do with the units emergency mode is meant to keep, recorded before the
# box goes dark: the drop-ins in force, and every dependency that could pull them down.
# shellcheck disable=SC2016  # the loop runs in the guest, so its variables expand there
ssh_vm 'for u in sshd.service NetworkManager.service dbus.service dbus-broker.service dbus.socket; do
		echo "== $u"; systemctl show "$u" -p IgnoreOnIsolate -p Requires -p Requisite -p BindsTo \
			-p PartOf -p Conflicts -p DropInPaths -p DefaultDependencies 2>&1; done
	systemctl show emergency.target emergency.service -p Conflicts -p ConflictedBy -p Wants 2>&1
	ls -la /etc/systemd/system/emergency.target.wants 2>&1
	ls -d /var/log/journal 2>&1' 2>&1 | tee -a report.txt
before=$(ssh_vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo none)
ssh_vm 'systemctl reboot' || true
reached=no
for _ in $(seq 1 72); do
	sleep 10
	if [ "$(ssh_vm 'systemctl is-active emergency.target' 2>/dev/null)" = active ]; then
		reached=yes
		break
	fi
done
if [ "$reached" = yes ]; then
	echo "REACHABLE IN EMERGENCY: ssh answered with emergency.target active" | tee -a report.txt
	ssh_vm 'cat /proc/sys/kernel/random/boot_id; systemctl is-active sshd sim-tunnel docker 2>&1;
		systemctl list-units --state=active --type=service --no-pager --no-legend | wc -l;
		journalctl -b -u health-checker --no-pager | tail -n 6' 2>&1 | tee -a report.txt
	echo "boot id before the reboot: $before" | tee -a report.txt
else
	echo "NOT REACHABLE: no ssh with emergency.target active within 12 minutes" | tee -a report.txt
	screenshots
	# A hard reset, then the dark boot's own journal: which jobs stopped the kept units, and
	# what asked for them. sim-fail-hard goes first, through the next boot's first ssh,
	# before health-checker can fail again; if it cannot, the screens are the record.
	python3 -I "$here/qmp.py" qmp.sock "system_reset" | tee -a report.txt || true
	if wait_for_ssh; then
		ssh_vm 'rm -f /etc/sim-fail-hard'
		ssh_vm 'journalctl --list-boots --no-pager | tail -n 4
			journalctl -b -1 -o short-precise --no-pager \
				| grep -iE "isolat|emergency|transaction|Stopping (OpenSSH|Network Manager|D-Bus)|Stopped target (Basic|System Init)|Job .* (sshd|NetworkManager|dbus)" \
				| head -n 60' 2>&1 | tee -a report.txt
	fi
fi

kill "$(cat qemu.pid)" 2>/dev/null || true
