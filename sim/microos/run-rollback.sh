#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015
# Whether health-checker rolls a MicroOS box back from an update that breaks the service
# its plugin checks, keeps one that does not, and leaves a good snapshot alone when the
# check fails there. Every stage asserts its outcome; any FAIL fails the job. CI runs it
# (.github/workflows/microos-sim.yml).
#
# Usage: sim/microos/run-rollback.sh <workdir>. It writes only inside <workdir>.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-rollback.sh <workdir>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

# qemu daemonizes, so it outlives the script unless something stops it, on any exit.
trap 'kill "$(cat qemu.pid 2>/dev/null)" 2>/dev/null || true' EXIT

fails=0
stage() { printf '\n##### %s\n' "$1" | tee -a report.txt; }
state() { ssh_vm 'bash -s' < "$here/rollback/state.sh" | tee -a report.txt; }
pass() { echo "PASS: $*" | tee -a report.txt; }
fail() { echo "FAIL: $*" | tee -a report.txt; fails=$((fails + 1)); }
# The default snapshot's number, from the path btrfs reports for it.
default_snapshot() {
	ssh_vm 'btrfs subvolume get-default / | sed -n "s|.*/\.snapshots/\([0-9]*\)/snapshot.*|\1|p"'
}
active() { [ "$(ssh_vm "systemctl is-active $1" 2>/dev/null || true)" = active ]; }

# Reboots and waits for the guest to settle, through any reboots health-checker adds.
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
if ssh_vm '[ -d /boot/efi/loader/entries ]'; then
	fail "this image boots through BLS, where the guard cannot work; the stages below would mislead"
fi

stage "a reboot with nothing changed, so health-checker records this snapshot as good"
reboot_and_settle
state
good=$(default_snapshot)
ssh_vm 'grep -q "^LAST_WORKING_BTRFS_ID=" /var/lib/misc/health-check.state' \
	&& pass "health-checker recorded a working snapshot ($good)" \
	|| fail "health-check.state has no LAST_WORKING_BTRFS_ID, so the guard has nothing to read"
# A normal boot must stay clean: no ordering cycle, which systemd breaks by dropping a job,
# and no unit that found the bus missing. Both caught mistakes in the emergency-mode
# drop-ins this simulation once carried (docs/decisions.md), and stay as cheap guards.
if ssh_vm 'journalctl -b --no-pager | grep -qi "ordering cycle"'; then
	fail "a normal boot found an ordering cycle"
	ssh_vm 'journalctl -b --no-pager | grep -i -A2 "ordering cycle" | head -n 12' | tee -a report.txt
else
	pass "a normal boot found no ordering cycle"
fi
if ssh_vm 'journalctl -b --no-pager | grep -q "Failed to connect to bus"'; then
	fail "a normal boot logged 'Failed to connect to bus'"
else
	pass "a normal boot logged no D-Bus connection failure"
fi

stage "an update that breaks the stand-in, then a reboot"
ssh_vm "transactional-update --non-interactive run sh -c 'echo \"exit 1\" > /usr/bin/sim-tunnel'" 2>&1 \
	| tail -n 5 | tee -a report.txt
reboot_and_settle
state
[ "$(default_snapshot)" = "$good" ] && pass "rolled back to snapshot $good" \
	|| fail "default snapshot is $(default_snapshot), not $good"
active sim-tunnel && pass "the stand-in runs again" || fail "the stand-in is not running"
ssh_vm 'journalctl -b -1 -u health-checker --no-pager | grep -q "do a rollback"' \
	&& pass "the broken snapshot's boot logged the rollback" \
	|| fail "the previous boot did not log a rollback"

stage "an update that leaves the stand-in alone, then a reboot"
ssh_vm "transactional-update --non-interactive run touch /usr/share/sim-good-update" 2>&1 \
	| tail -n 5 | tee -a report.txt
reboot_and_settle
state
kept=$(default_snapshot)
[ "$kept" -gt "$good" ] && pass "kept the good update (snapshot $kept)" \
	|| fail "default snapshot is $kept, not newer than $good"
ssh_vm 'test -e /usr/share/sim-good-update' && pass "the update's file is there" \
	|| fail "the update's file is missing"

stage "the check failing on a snapshot that has booted fine (/etc/sim-fail), then a reboot"
# The guard's case: a failure here must not reboot or strand the box.
ssh_vm 'touch /etc/sim-fail'
if reboot_and_settle; then
	state
	[ "$(default_snapshot)" = "$kept" ] && pass "still on snapshot $kept" \
		|| fail "moved to snapshot $(default_snapshot)"
	ssh_vm 'journalctl -b -u health-checker --no-pager | grep -q "already passed; not checked"' \
		&& pass "the guard passed it unchecked" || fail "the guard did not log"
	ssh_vm 'journalctl -b --no-pager | grep -q "starting emergency shell"' \
		&& fail "the box went to emergency mode" || pass "no emergency mode"
	ssh_vm 'rm -f /etc/sim-fail'
else
	fail "the guest did not come back after a failing check on a good snapshot"
	screenshots
fi

python3 -I "$here/qmp.py" qmp.sock "system_reset" >/dev/null || true

echo
if [ "$fails" -gt 0 ]; then
	echo "$fails check(s) FAILED" | tee -a report.txt
	exit 1
fi
echo "all checks passed" | tee -a report.txt
