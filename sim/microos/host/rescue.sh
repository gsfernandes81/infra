#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated host as root while it is in rescue mode (run-host.sh), and prints
# PASS or FAIL per check: the ways in are up, and the rest of the box is down, so the mode
# is really rescue and not a box that never left multi-user.
set -u

check() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then
		echo "PASS $name"
	else
		echo "FAIL $name"
		printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
	fi
}

# A target waits for the units it wants to finish starting, and cloudflared here has
# stand-in credentials, so it takes its whole 90 s start timeout; allow for that.
check "the box is in rescue mode" sh -c '
	for i in $(seq 1 36); do systemctl is-active --quiet rescue.target && break; sleep 5; done
	systemctl is-active rescue.target && ! systemctl is-active --quiet multi-user.target'
for u in sshd NetworkManager cloudflared tailscaled systemd-user-sessions; do
	# cloudflared has stand-in credentials here, so it may be between retries.
	check "$u is up in rescue mode" sh -c '
		st=$(systemctl show -p ActiveState --value "$1"); echo "$1: $st"
		[ "$st" = active ] || [ "$st" = activating ]' sh "$u"
done
check "no /run/nologin turns gavin away" sh -c '! test -e /run/nologin'
check "Docker is down, as rescue mode means" sh -c '! systemctl is-active --quiet docker'
