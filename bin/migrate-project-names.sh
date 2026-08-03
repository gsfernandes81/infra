#!/bin/sh
# Phase 2c — one-shot. Recreate both stacks under their corrected project names.
#
# WHY THIS IS NEEDED
# Until Phase 2b, deployments/torrents and deployments/ionic-traces both declared
# `name: ionic`, so all six containers shared one compose project. 2b renamed the
# torrents stack to `torrents`. A compose project name is baked into container
# labels at creation time, so the running containers are no longer associated with
# their compose file and cannot be relabelled in place — they must be replaced.
#
# WHAT IT DOES
# Brings BOTH projects down, then brings BOTH up. Downtime is expected and was
# authorised. All persistent state is on /media bind mounts: gluetun holds none,
# and qBittorrent's config lives on /media/torrents-config. Recreating loses
# nothing.
#
# ORDER MATTERS: both downs run before either up. While the old `ionic` label is
# still shared, a down issued after a fresh up could remove the newly created
# containers.
#
# NOT USED: --remove-orphans. That flag is what made the original collision
# dangerous, and it has no business here.
#
# Run:  bash ~/infra/bin/migrate-project-names.sh

set -eu

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
TORRENTS="$REPO/deployments/torrents/compose.yaml"
IONIC="$REPO/deployments/ionic-traces/compose.yaml"
QBCONF=/media/torrents-config/qBittorrent/qBittorrent.conf

for f in "$TORRENTS" "$IONIC"; do
	[ -f "$f" ] || { echo "missing compose file: $f" >&2; exit 1; }
done

# --- pre-flight, unprivileged -------------------------------------------------

echo "=============================================================="
echo " Pre-flight"
echo "=============================================================="
printf 'torrents project name    : %s\n'  "$(sed -n 's/^name: *//p' "$TORRENTS")"
printf 'ionic-traces project name: %s\n'  "$(sed -n 's/^name: *//p' "$IONIC")"

if [ "$(sed -n 's/^name: *//p' "$TORRENTS")" != "torrents" ]; then
	echo "ABORT: torrents compose still says 'ionic' — Phase 2b has not been applied." >&2
	exit 1
fi

PORT_BEFORE=''
if [ -r "$QBCONF" ]; then
	PORT_BEFORE=$(sed -n 's/^Session\\Port=//p' "$QBCONF")
	printf 'qBittorrent Session\\Port : %s   (expect this to CHANGE)\n' "${PORT_BEFORE:-unset}"
else
	echo "note: cannot read $QBCONF — will skip the port check"
fi

cat <<EOF

This will:
  1. docker compose -p ionic  down   (torrents file)   <- both downs first
  2. docker compose -p ionic  down   (ionic-traces file)
  3. docker compose           up -d  (torrents file)   -> project "torrents"
  4. docker compose           up -d  (ionic-traces file) -> project "ionic"

Six containers stop and are recreated. send2ereader is NOT touched.
EOF

printf '\nProceed? [y/N] '
read -r reply
case "$reply" in
	y | Y | yes | YES) ;;
	*) echo "Aborted. Nothing changed."; exit 0 ;;
esac

# Cache the sudo credential once so the steps below do not each prompt mid-flight.
sudo -v

# --- the recreate -------------------------------------------------------------

echo
echo "=============================================================="
echo " 1/2  bringing both projects down"
echo "=============================================================="
# -p ionic overrides the `name:` in the file, which is how we reach the containers
# that are still labelled with the OLD project name.
sudo docker compose -p ionic -f "$TORRENTS" down
sudo docker compose -p ionic -f "$IONIC"    down

echo
echo "=============================================================="
echo " 2/2  bringing both projects up under corrected names"
echo "=============================================================="
sudo docker compose -f "$TORRENTS" up -d
sudo docker compose -f "$IONIC"    up -d

# --- verification -------------------------------------------------------------

echo
echo "=============================================================="
echo " Verification"
echo "=============================================================="

echo "--- project labels (want: 3x torrents, 3x ionic, 1x send2ereader) ---"
sudo docker inspect \
	-f '{{index .Config.Labels "com.docker.compose.project"}}  {{.Name}}' \
	$(sudo docker ps -q) | sort

echo
echo "--- waiting for gluetun to reconnect and Proton to assign a port ---"
echo "    (this is the real test: the UP hook must write the new port into"
echo "     qBittorrent.conf via the localhost auth bypass)"

new_port=''
i=0
while [ "$i" -lt 60 ]; do
	if [ -r "$QBCONF" ]; then
		cur=$(sed -n 's/^Session\\Port=//p' "$QBCONF")
		if [ -n "$cur" ] && [ "$cur" != "$PORT_BEFORE" ]; then
			new_port=$cur
			break
		fi
	fi
	i=$((i + 1))
	sleep 5
done

echo
if [ -n "$new_port" ]; then
	echo "PASS  Session\\Port changed: ${PORT_BEFORE:-unset} -> $new_port"
	echo "      The port-forward hook fired and authenticated. This is the"
	echo "      whole point of the exercise."
else
	echo "NOT YET  Session\\Port is still '${PORT_BEFORE:-unset}' after 5 minutes."
	echo
	echo "      This is not necessarily broken — Proton can take a while, and"
	echo "      qBittorrent may not have flushed its config to disk yet. Check"
	echo "      gluetun's own view first:"
	echo
	echo "        sudo docker logs torrents-gluetun-1 2>&1 | grep -i -e 'port forward' -e forwarded | tail"
	echo
	echo "      If gluetun reports a port but qBittorrent never took it, the"
	echo "      shared-netns auth chain is what to suspect. Nothing is lost:"
	echo "      the same wget can be run by hand inside the gluetun container."
	echo "      See docs/port-forwarding.md."
fi

echo
echo "--- gluetun's port-forwarding log lines ---"
sudo docker logs "$(sudo docker ps -qf 'label=com.docker.compose.project=torrents' -f 'label=com.docker.compose.service=gluetun')" 2>&1 \
	| grep -i -e 'port forward' -e forwarded | tail -5 || echo "(none found)"

echo
echo "--- listening ports (want 8080, 7777, 3001, 8384, 22000) ---"
netstat -tln 2>/dev/null | grep -E ':(8080|3001|7777|8384|22000)\b' || echo "(netstat unavailable)"

echo
echo "--- compose projects ---"
sudo docker compose ls -a

echo
echo "Done. If Session\\Port changed and all five ports are listening, Phase 2c"
echo "succeeded and the ionic collision is gone for good."
