# shellcheck shell=bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# zero's own checks, appended to checks.sh by run-host.sh, so check, show and docker_checks
# are defined: the array assembled and opened with nobody at the box, Docker on its new
# store, the carry-over only zero has, the backup source, and snapper through snapperd.

echo "-- the array"
check "both bcache devices are attached to the cache, writethrough" sh -c '
	n=0
	for d in /sys/block/bcache*/bcache; do
		n=$((n + 1)); s=$(cat "$d/state"); m=$(cat "$d/cache_mode"); echo "$d: $s, $m"
		case "$s" in clean | dirty) ;; *) exit 1 ;; esac
		case "$m" in *"[writethrough]"*) ;; *) exit 1 ;; esac
	done
	[ "$n" = 2 ]'
check "data-4 is open from the key file, with no passphrase asked" sh -c '
	u="systemd-cryptsetup@data\x2d4.service"
	systemctl is-active "$u" && cryptsetup status data-4 | tee /dev/stderr | grep -q "type: *LUKS2" &&
	! journalctl -b --no-pager -u "$u" | grep -i passphrase'
check "the array is btrfs RAID1 on its two devices, none missing" sh -c '
	s=$(btrfs filesystem show 813c830a-0892-41e8-b39b-32d661c79e2c); echo "$s"
	echo "$s" | grep -q "Total devices 2" && ! echo "$s" | grep -qi missing &&
	btrfs filesystem df /media/immich | tee /dev/stderr | grep -q "^Data, RAID1"'
check "/media/immich is subvolume 281, with zero's context=" sh -c '
	findmnt -no OPTIONS /media/immich | tee /dev/stderr | grep "subvolid=281," |
		grep -q "context=\"\?system_u:object_r:container_file_t:s0"'
check "/media/syncthing is subvolume 278, with zero's context=" sh -c '
	findmnt -no OPTIONS /media/syncthing | tee /dev/stderr | grep "subvolid=278," |
		grep -q "context=\"\?system_u:object_r:container_file_t:s0"'

echo "-- Docker"
check "Docker runs, on the new store on the SSD" sh -c '
	systemctl is-active docker && findmnt -no SOURCE /var/lib/docker | tee /dev/stderr | grep -q "\[/var-lib-docker-leap\]$"'
docker_checks

echo "-- the carry-over only zero has"
check "the array's key file is root's alone, 0400 in a 0700 /etc/keys" sh -c '
	stat -c "%a %U %n" /etc/keys /etc/keys/data.key | tee /dev/stderr | tr "\n" " " |
		grep -q "^700 root /etc/keys 400 root /etc/keys/data.key $"'
# The carried file holds a key of the run's that tailscaled keeps when it writes the file back,
# so a state it made afresh, at a path the first boot's write never reached, fails this.
check "the carried Tailscale state is in /var/lib/tailscale after the reboots" sh -c '
	ls -lZ /var/lib/tailscale/tailscaled.state &&
	jq -e ".\"_sim-marker\" == \"c2lt\"" /var/lib/tailscale/tailscaled.state'
check "root's restore key and three's host key are in place, root's" sh -c '
	stat -c "%a %U %n" /root/.ssh/restore /root/.ssh/restore.pub | tee /dev/stderr | tr "\n" " " |
		grep -q "^600 root /root/.ssh/restore 644 root /root/.ssh/restore.pub $" &&
	t=$(awk "/^tailnet_addresses:/ { f = 1; next } f && /^[^[:space:]]/ { f = 0 } f && \$1 == \"three:\" { print \$2 }" \
		/home/gavin/infra/ansible/group_vars/all.yml) && ssh-keygen -F "$t" -f /root/.ssh/known_hosts'
check "no secrets directory came across, as make-stick refuses one on zero" sh -c '
	! ls -d /home/gavin/.*-secrets 2>/dev/null'

echo "-- the backup source"
check "backup has a real shell, no password, and root's home and .ssh" sh -c '
	getent passwd backup | tee /dev/stderr | grep -q ":/home/backup:/bin/bash$" &&
	passwd -S backup | tee /dev/stderr | grep -qE "^backup (L|LK) " &&
	[ "$(stat -c "%U %a" /home/backup /home/backup/.ssh | sort -u)" = "root 755" ] &&
	stat -c "%a %U %n" /home/backup/.ssh/authorized_keys | tee /dev/stderr | grep -q "^644 root "'
check "firewalld lets Syncthing through" sh -c 'firewall-cmd --list-services | tee /dev/stderr | grep -qw syncthing'
check "snapper's configs are root and immich, for Leap's timers" grep -qx 'SNAPPER_CONFIGS="root immich"' /etc/sysconfig/snapper
check "Leap's snapper timers are enabled" systemctl is-enabled snapper-timeline.timer snapper-cleanup.timer

# The timeline run as Leap's hourly timer starts it: the service asks snapperd over D-Bus,
# so the snapshot is made in snapperd's own confined domain, on a mount labelled
# container_file_t, which nothing else on the fleet has run (plans/zero-leap.md § snapper).
timeline() { snapper --no-dbus --csvout -c immich list --columns number,description | grep -c ',timeline$'; }
since=$(date +%s)
before=$(timeline)
show systemctl start snapper-timeline.service
after=$(timeline)
show sh -c 'ps -eZ | grep -w snapperd || echo "snapperd has exited"'
check "snapper-timeline took a snapshot of immich through snapperd, $before before, $after after" \
	sh -c "[ $after -gt $before ] && ! systemctl cat snapper-timeline.service | grep -e --no-dbus &&
		systemctl is-active snapperd.service"
show sh -c "journalctl --since @$since --no-pager -u snapper-timeline -u snapperd | tail -n 8"
# Where a denial would be read: the journal, and auditd's log where auditd runs.
show sh -c 'systemctl is-active auditd; journalctl -b --no-pager | grep -ci "avc:"'
check "SELinux enforced and denied snapper nothing" sh -c "
	[ \"\$(getenforce)\" = Enforcing ] || exit 1
	d=\$({ journalctl --since @$since --no-pager; ausearch --input-logs -m avc -ts recent 2>/dev/null; } |
		grep -i 'avc: *denied' | grep -i snapper); echo \"\$d\"; [ -z \"\$d\" ]"

# On disk, not through the mount: context= makes every file read as container_file_t whatever
# it holds, so the array's trees are read off the device for a security.selinux item. A file
# written through a container and snapper's snapshot are what Leap wrote there. The same read
# of /home, which the first boot labelled, must find some, or the read proves nothing.
show docker run --rm -v /media/syncthing:/d docker.io/library/alpine:3.22 sh -c 'echo leap > /d/sim-written-on-leap'
sync
home_dev=$(findmnt -no SOURCE /home | sed 's/\[.*//')
home_id=$(btrfs subvolume show /home | awk '/Subvolume ID:/ { print $3 }')
check "the label read finds the labels the first boot wrote under /home" sh -c "
	n=\$(btrfs inspect-internal dump-tree -t $home_id $home_dev | grep -c 'name: security.selinux'); echo \"\$n\"; [ \"\$n\" -gt 0 ]"
check "no file on the array holds an SELinux label, so Alpine reads it as it left it" sh -c "
	n=\$(btrfs inspect-internal dump-tree /dev/mapper/data-4 | grep -c 'name: security.selinux'); echo \"\$n\"; [ \"\$n\" = 0 ]"
