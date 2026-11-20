# shellcheck shell=bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# three's own checks, appended to checks.sh by run-host.sh, so check is defined: the array,
# locked as every boot leaves it, and what waits for it; the backup and restore users;
# Wi-Fi; firewalld.
# three-unlocked.sh checks the array once it is unlocked.

echo "-- the array, locked as every boot leaves it"
check "crypttab names the array by its label, noauto" \
	grep -qE '^backup[[:space:]]+LABEL=backup-luks[[:space:]]+none[[:space:]]+luks,noauto,password-cache=no$' /etc/crypttab
check "fstab mounts it noauto, with the container context" sh -c '
	awk "\$2 == \"/media/backup\"" /etc/fstab | tee /dev/stderr | grep -E "(^|[[:space:],])noauto," | grep -q context='
# So one stop of both, or a shutdown, unmounts before it closes the LUKS volume.
check "the mount is ordered after the LUKS unit" sh -c '
	systemctl show -p After media-backup.mount | tee /dev/stderr | grep -qw "systemd-cryptsetup@backup.service"'
check "the boot left it locked and unmounted" sh -c '
	systemctl show -p ActiveState systemd-cryptsetup@backup.service media-backup.mount
	! systemctl is-active --quiet systemd-cryptsetup@backup.service && ! findmnt /media/backup && ! test -e /dev/mapper/backup'
check "nothing waits at a passphrase prompt" sh -c '! ls /run/systemd/ask-password/ask.* 2>/dev/null'
# Tried at boot, as multi-user wants it, and skipped: a condition timestamp proves it was
# tried, not merely never started.
check "Docker was skipped at boot by its condition, not failed" sh -c '
	systemctl show -p ActiveState -p ConditionResult -p ConditionTimestamp docker
	[ "$(systemctl show -p ActiveState --value docker)" = inactive ] &&
	[ "$(systemctl show -p ConditionResult --value docker)" = no ] &&
	[ -n "$(systemctl show -p ConditionTimestamp --value docker)" ]'
check "the mount starts Docker and both timers" sh -c '
	w=$(systemctl show -p Wants --value media-backup.mount); echo "$w"
	for u in docker.service backup-pull.timer backup-scrub.timer; do echo "$w" | grep -qw "$u" || exit 1; done'
check "the timers wait for the mount, not started at boot" sh -c '
	! systemctl is-active --quiet backup-pull.timer && ! systemctl is-active --quiet backup-scrub.timer'
# Leap's docker.socket is BindsTo=docker.service; enabled, a client's connection would start
# Docker by another road, so a preset that enables it should show here.
check "docker.socket is disabled and idle" sh -c '
	e=$(systemctl is-enabled docker.socket); a=$(systemctl is-active docker.socket); echo "$e, $a"
	[ "$e" = disabled ] && [ "$a" = inactive ]'

echo "-- the backup and restore users"
check "backup has no shell and no password; restore has a shell for its forced command, and no password" sh -c '
	getent passwd backup restore | tee /dev/stderr
	getent passwd backup | grep -q ":/home/backup:/usr/sbin/nologin$" &&
	getent passwd restore | grep -q ":/home/restore:/bin/bash$" &&
	passwd -S backup | grep -qE "^backup L" && passwd -S restore | grep -qE "^restore L"'
check "their homes and .ssh are root's, so neither can change its keys or ssh config" sh -c '
	stat -c "%U %a %n" /home/backup /home/backup/.ssh /home/restore /home/restore/.ssh | tee /dev/stderr |
		grep -v "^root 755 " | grep -q . && exit 1 || exit 0'
check "backup logs in nowhere on three: no authorized_keys" test ! -e /home/backup/.ssh/authorized_keys
check "backup's ssh config and zero's pinned host key are root's, 644" sh -c '
	s=$(stat -c "%U %a" /home/backup/.ssh/config /home/backup/.ssh/known_hosts | sort -u); echo "$s"
	[ "$s" = "root 644" ] && grep -q "^zero ssh-ed25519 " /home/backup/.ssh/known_hosts &&
	grep -qE "^[[:space:]]+StrictHostKeyChecking yes$" /home/backup/.ssh/config'
check "restore has one key, root's, restricted, that starts only the read-only daemon through sudo" sh -c '
	f=/home/restore/.ssh/authorized_keys; stat -c "%U %a" "$f"; grep -v "^#" "$f" | cut -c1-140
	[ "$(stat -c "%U %a" "$f")" = "root 644" ] && [ "$(grep -vc "^#" "$f")" = 1 ] &&
	grep -v "^#" "$f" | grep -q "^restrict,from=\"[^\"]*\",command=\"sudo -n /usr/bin/setpriv --reuid=restore .* /usr/bin/rsync --server --daemon --config=/etc/rsyncd-restore.conf \.\" "'
check "sudoers-restore passes visudo, root 0440" sh -c '
	visudo -cf /etc/sudoers.d/60-restore && [ "$(stat -c "%U %a" /etc/sudoers.d/60-restore)" = "root 440" ]'
check "the pull, its snapshot service and three's snapper config are in place" sh -c '
	ls -l /usr/local/bin/backup-pull /etc/snapper/configs/received-immich
	[ -x /usr/local/bin/backup-pull ] && systemctl cat backup-pull.service backup-snapshot.service > /dev/null &&
	systemctl show -p OnSuccess --value backup-pull.service | grep -qw backup-snapshot.service'
check "nothing of the old push is left: no rsync-backup.conf, no mirror-snapshot script, service or timer" sh -c '
	! ls /etc/rsync-backup.conf /usr/local/sbin/mirror-snapshot /etc/systemd/system/mirror-snapshot.timer \
		/etc/systemd/system/mirror-snapshot.service 2>/dev/null'
check "/rsyncd-munged does not exist, so no munged symlink leads anywhere" test ! -e /rsyncd-munged

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
