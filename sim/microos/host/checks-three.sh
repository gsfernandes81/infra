# shellcheck shell=bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# three's own checks, appended to checks.sh by run-host.sh, so check is defined: the array,
# locked as every boot leaves it, and what waits for it; the backup user; Wi-Fi; firewalld.
# three-unlocked.sh checks the array once it is unlocked.

echo "-- the array, locked as every boot leaves it"
check "crypttab names the array by its label, noauto" \
	grep -qE '^mirror[[:space:]]+LABEL=mirror-luks[[:space:]]+none[[:space:]]+luks,noauto$' /etc/crypttab
check "fstab mounts it noauto, with the container context" sh -c '
	awk "\$2 == \"/media/mirror\"" /etc/fstab | tee /dev/stderr | grep -E "(^|[[:space:],])noauto," | grep -q context='
check "the boot left it locked and unmounted" sh -c '
	systemctl show -p ActiveState systemd-cryptsetup@mirror.service media-mirror.mount
	! systemctl is-active --quiet systemd-cryptsetup@mirror.service && ! findmnt /media/mirror && ! test -e /dev/mapper/mirror'
check "nothing waits at a passphrase prompt" sh -c '! ls /run/systemd/ask-password/ask.* 2>/dev/null'
# Tried at boot, as multi-user wants it, and skipped: a condition timestamp proves it was
# tried, not merely never started.
check "Docker was skipped at boot by its condition, not failed" sh -c '
	systemctl show -p ActiveState -p ConditionResult -p ConditionTimestamp docker
	[ "$(systemctl show -p ActiveState --value docker)" = inactive ] &&
	[ "$(systemctl show -p ConditionResult --value docker)" = no ] &&
	[ -n "$(systemctl show -p ConditionTimestamp --value docker)" ]'
check "the mount starts Docker and both timers" sh -c '
	w=$(systemctl show -p Wants --value media-mirror.mount); echo "$w"
	for u in docker.service mirror-snapshot.timer mirror-scrub.timer; do echo "$w" | grep -qw "$u" || exit 1; done'
check "the timers wait for the mount, not started at boot" sh -c '
	! systemctl is-active --quiet mirror-snapshot.timer && ! systemctl is-active --quiet mirror-scrub.timer'
# Leap's docker.socket is BindsTo=docker.service; enabled, a client's connection would start
# Docker by another road, so a preset that enables it should show here.
check "docker.socket is disabled and idle" sh -c '
	e=$(systemctl is-enabled docker.socket); a=$(systemctl is-active docker.socket); echo "$e, $a"
	[ "$e" = disabled ] && [ "$a" = inactive ]'

echo "-- the backup user"
check "backup has a shell for its forced command, and no password" sh -c '
	getent passwd backup | tee /dev/stderr | grep -q ":/home/backup:/bin/bash$" &&
	passwd -S backup | tee /dev/stderr | grep -qE "^backup L"'
check "its home and .ssh are root's, so it cannot change its keys" sh -c '
	stat -c "%U %a %n" /home/backup /home/backup/.ssh | tee /dev/stderr | grep -v "^root 755 " | grep -q . && exit 1 || exit 0'
# Item 2 of the handoff decides how the push is confined; openSUSE's rsync package does not
# install rrsync, so what is there is shown.
show sh -c 'command -v rrsync || echo "no rrsync on PATH"; ls -l /usr/share/doc/packages/rsync/support/rrsync 2>&1; rsync --version | head -n 1'

echo "-- networks"
check "the DHCP profile for Singapore waits below the static one" sh -c '
	nmcli -t -f NAME,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show | tee /dev/stderr | grep -qx "wired-dhcp:yes:50"'
check "NetworkManager can drive Wi-Fi" sh -c '
	rpm -q wpa_supplicant && ls /usr/lib*/NetworkManager/*/libnm-device-plugin-wifi.so'
check "firewalld lets Syncthing in, and not its GUI" sh -c '
	s=$(firewall-cmd --list-services); echo "$s"; echo "$s" | grep -qw syncthing && ! echo "$s" | grep -qw syncthing-gui'
