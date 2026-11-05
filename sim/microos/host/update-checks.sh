#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated host as root after server-update-leap.yml (run-host.sh), and prints
# PASS or FAIL per check: both pins moved off the stand-ins run-host.sh put in their place,
# each stand-in kept as the previous, and the update recipes installed.
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

check "cloudflared is the pinned ${EXPECT_CLOUDFLARED:?}, and running" sh -c '
	/usr/local/bin/cloudflared --version | tee /dev/stderr | grep -q "version $EXPECT_CLOUDFLARED " &&
	systemctl show -p ExecMainStatus -p ActiveState cloudflared && systemctl is-enabled cloudflared'
check "the cloudflared it replaced is kept as the previous" \
	grep -q 0.0.0-sim /usr/local/lib/cloudflared.previous
check "Compose is the pinned ${EXPECT_COMPOSE:?}" sh -c '
	/usr/local/lib/docker/cli-plugins/docker-compose version --short | tee /dev/stderr | grep -qx "v\{0,1\}$EXPECT_COMPOSE"'
check "the Compose it replaced is kept beside, not in, the plugin directory" sh -c '
	grep -q 0.0.0-sim /usr/local/lib/docker/docker-compose.previous &&
	[ "$(ls /usr/local/lib/docker/cli-plugins)" = docker-compose ]'
check "the update recipes are installed for logins" \
	grep -q 'Updates on this box are by hand' /etc/motd.d/50-infra-updates
check "the downloads are gone" sh -c '! ls /var/tmp/infra-* 2>/dev/null'
