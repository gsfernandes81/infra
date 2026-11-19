# shellcheck shell=bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# three's own checks, appended to checks.sh by run-host.sh, so check is defined: the array,
# locked as every boot leaves it, and what waits for it; the backup user, its key and its
# sudo; Wi-Fi; firewalld.
# three-unlocked.sh checks the array once it is unlocked.

echo "-- the array, locked as every boot leaves it"
check "crypttab names the array by its label, noauto" \
	grep -qE '^mirror[[:space:]]+LABEL=mirror-luks[[:space:]]+none[[:space:]]+luks,noauto,password-cache=no$' /etc/crypttab
check "fstab mounts it noauto, with the container context" sh -c '
	awk "\$2 == \"/media/mirror\"" /etc/fstab | tee /dev/stderr | grep -E "(^|[[:space:],])noauto," | grep -q context='
# So one stop of both, or a shutdown, unmounts before it closes the LUKS volume.
check "the mount is ordered after the LUKS unit" sh -c '
	systemctl show -p After media-mirror.mount | tee /dev/stderr | grep -qw "systemd-cryptsetup@mirror.service"'
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
check "the mount starts Docker and the scrub timer" sh -c '
	w=$(systemctl show -p Wants --value media-mirror.mount); echo "$w"
	for u in docker.service mirror-scrub.timer; do echo "$w" | grep -qw "$u" || exit 1; done'
check "the scrub timer waits for the mount, not started at boot" sh -c '
	! systemctl is-active --quiet mirror-scrub.timer'
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
check "its one key is root's, restricted, and runs only mirror-receive through sudo" sh -c '
	f=/home/backup/.ssh/authorized_keys; stat -c "%U %a" "$f"; grep -v "^#" "$f" | cut -c1-200
	[ "$(stat -c "%U %a" "$f")" = "root 644" ] && [ "$(grep -vc "^#" "$f")" = 1 ] &&
	grep -v "^#" "$f" | grep -q "^restrict,from=\"[^\"]*\",command=\"case " &&
	grep -v "^#" "$f" | grep -qF "in immich|syncthing) exec sudo -n /usr/local/sbin/mirror-receive \\\"\$SSH_ORIGINAL_COMMAND\\\" ;;"'
check "its sudoers file is root's, 0440, and passes visudo" sh -c '
	f=/etc/sudoers.d/60-backup; stat -c "%U %a" "$f"
	[ "$(stat -c "%U %a" "$f")" = "root 440" ] && visudo -cf "$f"'
check "mirror-receive is installed, root's, 0755" sh -c '
	f=/usr/local/sbin/mirror-receive; stat -c "%U %a" "$f"; [ "$(stat -c "%U %a" "$f")" = "root 755" ]'
check "the rsync daemon config and the snapshot timer are gone" sh -c '
	! test -e /etc/rsync-backup.conf && ! test -e /usr/local/sbin/mirror-snapshot &&
	! systemctl cat mirror-snapshot.timer mirror-snapshot.service >/dev/null 2>&1'

echo "-- networks"
check "the DHCP profile for Singapore waits below the static one" sh -c '
	nmcli -t -f NAME,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show | tee /dev/stderr | grep -qx "wired-dhcp:yes:50"'
check "NetworkManager can drive Wi-Fi" sh -c '
	rpm -q wpa_supplicant && ls /usr/lib*/NetworkManager/*/libnm-device-plugin-wifi.so'
check "firewalld lets Syncthing in, and not its GUI" sh -c '
	s=$(firewall-cmd --list-services); echo "$s"; echo "$s" | grep -qw syncthing && ! echo "$s" | grep -qw syncthing-gui'

echo "-- the fan"
# A VM has no Argon controller and no Pi I2C bus, so the unit is checked for waiting on its
# bus without failing the boot; the levels are the box's to show. The array's drive is
# not made yet, so the unit follows the CPU alone here (three-unlocked.sh finds the drive).
check "argon-fan is enabled and runs, waiting for its bus" sh -c '
	systemctl is-enabled argon-fan.service && systemctl is-active argon-fan.service'
check "i2c-dev is loaded at boot" test -d /sys/module/i2c_dev
show sh -c 'journalctl -b --no-pager -u argon-fan | tail -n 4'
show sh -c 'findmnt -no FSTYPE,OPTIONS /boot/efi || echo "nothing mounted at /boot/efi"
	tail -n 1 /boot/efi/extraconfig.txt 2>&1; grep "extraconfig\|boot/efi" /var/log/infra-firstboot.log'
