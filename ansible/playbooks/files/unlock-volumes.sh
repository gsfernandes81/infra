# shellcheck shell=sh
# Reads, unlocks and mounts the encrypted volumes a host lists in `unlock_volumes`. Run on
# that host as root by server-unlock-arrays.yml, as `sh -c <this file> unlock-volumes
# <verb> ...`; never by hand, and never with a passphrase on its command line.
#
#   read   <name> <mount> [<name> <mount>]...   one line per volume: name, need, reason, by tabs
#   unlock <name> <mount>                       the passphrase on stdin, one line
#   mount  <name> <mount>                       a volume already open: mount it, ask nothing
#
# `need` is what the play does next: `open`, nothing (open and mounted); `mount`, no passphrase
# (open, not mounted); `ask`, the play asks for the passphrase (locked); `fail`, the reason
# says why it cannot. unlock and mount end with two lines, result=<word> and reason=<text>,
# and exit 0 whatever happened, so the play reads the outcome from them; neither line can
# hold the passphrase, which is never echoed, logged or written anywhere.
#
# ONE BRANCH PER INIT SYSTEM. systemd's is the only one so far (three). A host on another
# init gets `fail` from read, naming its init, until a branch is written for it here: zero's
# volumes are added with zero's branch, not before.
#
# ON SYSTEMD THE UNLOCK IS systemd's OWN. The play starts systemd-cryptsetup@<name>.service,
# as the manual unlock does, and answers the passphrase request that unit makes, through
# systemd-reply-password, which reads the passphrase on stdin. So every option in
# /etc/crypttab applies, password-cache=no included, and the unit is active afterwards: the
# lock command in hosts/three/leap/README.md, the mount's dependants and the PartOf= on
# Docker behave exactly as after the owner's own unlock. A second request from the same
# process after the answer means the passphrase was wrong: it is cancelled, which fails the
# unit, and the failed state is reset so a later manual unlock starts clean. That reading
# needs a second try: a crypttab line with tries=1 would fail the unit on a wrong passphrase
# without asking again, and the play would report a unit failure, not a wrong passphrase.
set -u

result() {
	printf 'result=%s\nreason=%s\n' "$1" "$2"
	exit 0
}

init_system() {
	if [ -d /run/systemd/system ]; then
		echo systemd
	elif [ -d /run/openrc ]; then
		echo openrc
	else
		echo unknown
	fi
}

# The device mounted at $1, resolved to its /dev node, or nothing.
mounted_from() {
	src=$(awk -v m="$1" '$2 == m { s = $1 } END { print s }' /proc/self/mounts)
	[ -n "$src" ] && readlink -f "$src"
}

# ── systemd ──────────────────────────────────────────────────────────────────
crypt_unit() { systemd-escape --template=systemd-cryptsetup@.service "$1"; }
mount_unit() { systemd-escape -p --suffix=mount "$1"; }
state_of() { systemctl show -p ActiveState --value "$1"; }
# Each unit $1 requires, with its state, on one line: which one failed, when a start fails
# for a dependency.
deps() {
	for d in $(systemctl show -p Requires -p BindsTo -p Requisite --value "$1"); do
		printf '%s=%s ' "$d" "$(state_of "$d")"
	done
}
# What the unit said since $2 (seconds since the epoch), on one line.
said() { journalctl -u "$1" --since "@$2" -o cat --no-pager 2> /dev/null | tail -n 3 | tr '\n' ' '; }

read_systemd() {
	name=$1 mount=$2
	unit=$(crypt_unit "$name")
	at=$(mounted_from "$mount")
	if [ -e "/dev/mapper/$name" ]; then
		dev=$(readlink -f "/dev/mapper/$name")
		if [ "$at" = "$dev" ]; then
			printf '%s\topen\topen, and mounted at %s\n' "$name" "$mount"
		elif [ -n "$at" ]; then
			printf '%s\tfail\topen, but %s has %s mounted on it\n' "$name" "$mount" "$at"
		else
			printf '%s\tmount\topen, not mounted\n' "$name"
		fi
		return
	fi
	if [ -n "$at" ]; then
		printf '%s\tfail\tlocked, but %s has %s mounted on it\n' "$name" "$mount" "$at"
	elif [ "$(systemctl show -p LoadState --value "$unit")" != loaded ]; then
		printf '%s\tfail\tno %s: /etc/crypttab has no line for %s\n' "$name" "$unit" "$name"
	elif [ "$(systemctl show -p LoadState --value "$(mount_unit "$mount")")" != loaded ]; then
		printf '%s\tfail\tno %s: /etc/fstab mounts nothing at %s\n' "$name" "$(mount_unit "$mount")" "$mount"
	else
		# The unit is bound to its drive's device unit, which is active only while the drive
		# is there: asking for a passphrase for a drive that is not attached would only wait.
		for d in $(systemctl show -p BindsTo --value "$unit"); do
			case $d in
			*.device)
				if ! systemctl is-active --quiet "$d"; then
					printf '%s\tfail\tits drive is not attached (%s is inactive)\n' "$name" "$d"
					return
				fi
				;;
			esac
		done
		printf '%s\task\tlocked\n' "$name"
	fi
}

# Mounts a volume that is open: the LUKS unit first, then the mount, as the manual unlock
# does. Starting the LUKS unit of an open volume asks for nothing, since systemd-cryptsetup
# finds the volume active and exits 0; it is started so the unit reads active, which the
# lock command stops. --no-block and a bounded wait, because a unit that did ask would wait
# for an answer with no timeout. The wait ends as soon as the unit is active, failed, or back
# to inactive after starting. NOTHING HERE STOPS THE LUKS UNIT: one that came up late would
# close a volume that is open, so a failure is only reset, and a unit still starting after
# 30 s is reported and left for the owner.
mount_systemd() {
	name=$1 mount=$2 since=$(date +%s)
	unit=$(crypt_unit "$name") munit=$(mount_unit "$mount")
	systemctl start --no-block "$unit" || result failed "systemctl could not start $unit"
	i=0 started=no
	while :; do
		state=$(state_of "$unit")
		case $state in
		active) break ;;
		failed)
			why=$(said "$unit" "$since")
			systemctl reset-failed "$unit" 2> /dev/null
			result failed "$unit failed on the open volume: ${why:-it said nothing}"
			;;
		inactive)
			if [ "$started" = yes ]; then
				result failed "$unit started and stopped again on the open volume: $(said "$unit" "$since")"
			fi
			;;
		*) started=yes ;;
		esac
		i=$((i + 1))
		if [ "$i" -gt 30 ]; then
			result failed "$unit is still $state after 30 s on the open volume, and is left as it is; check by hand: $(said "$unit" "$since")"
		fi
		sleep 1
	done
	systemctl start "$munit" || result failed "$munit did not start: $(said "$munit" "$since") Its dependencies: $(deps "$munit")"
	at=$(mounted_from "$mount")
	if [ -z "$at" ] || [ "$at" != "$(readlink -f "/dev/mapper/$name")" ]; then
		result failed "$munit started, but $mount is not mounted from /dev/mapper/$name"
	fi
}

unlock_systemd() {
	name=$1 mount=$2
	unit=$(crypt_unit "$name")
	reply=
	for r in /usr/lib/systemd/systemd-reply-password /lib/systemd/systemd-reply-password; do
		if [ -x "$r" ]; then
			reply=$r
			break
		fi
	done
	[ -n "$reply" ] || result failed "no systemd-reply-password on this host"
	pw=
	IFS= read -r pw || true
	[ -n "$pw" ] || result failed "no passphrase arrived"
	since=$(date +%s)
	systemctl reset-failed "$unit" 2> /dev/null
	systemctl start --no-block "$unit" || result failed "systemctl could not start $unit"
	# The request is a file in /run/systemd/ask-password whose PID= is the unit's own
	# process: systemd-cryptsetup asks for itself. Each file answered is remembered, so the
	# one being answered is not mistaken for a second request while it is still there.
	answered='' outcome='' deadline=$((since + 60))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		state=$(state_of "$unit")
		if [ "$state" = active ]; then
			outcome=active
			break
		elif [ "$state" = failed ] || { [ "$state" = inactive ] && [ -n "$answered" ]; }; then
			outcome=failed
			break
		fi
		pid=$(systemctl show -p MainPID --value "$unit")
		for f in /run/systemd/ask-password/ask.*; do
			if [ ! -f "$f" ] || [ "$pid" = 0 ] || ! grep -qx "PID=$pid" "$f" 2> /dev/null; then
				continue
			fi
			case " $answered " in *" $f "*) continue ;; esac
			sock=$(sed -n 's/^Socket=//p' "$f")
			if [ -z "$answered" ]; then
				# printf is the shell's own, so the passphrase is in no process's arguments.
				printf '%s\n' "$pw" | "$reply" 1 "$sock"
				pw=
				# The KDF runs once per try, and the next request, if any, waits for it.
				deadline=$(($(date +%s) + 120))
			else
				"$reply" 0 "$sock"
				outcome=wrong
			fi
			answered="$answered $f"
		done
		[ -n "$outcome" ] && break
		sleep 1
	done
	pw=
	case $outcome in
	active)
		mount_systemd "$name" "$mount"
		result unlocked "unlocked, and mounted at $mount"
		;;
	wrong)
		# The cancelled request fails the unit; wait for that, then clear it.
		i=0
		while [ "$(state_of "$unit")" = activating ] && [ "$i" -lt 30 ]; do
			i=$((i + 1))
			sleep 1
		done
		systemctl reset-failed "$unit" 2> /dev/null
		if [ -e "/dev/mapper/$name" ]; then
			result failed "the passphrase was asked for again, yet /dev/mapper/$name exists; check by hand"
		fi
		result wrong "wrong passphrase; still locked"
		;;
	failed)
		why=$(said "$unit" "$since")
		systemctl reset-failed "$unit" 2> /dev/null
		result failed "$unit failed: ${why:-it said nothing}"
		;;
	*)
		if [ -z "$answered" ]; then
			# The start job would otherwise wait on, for a request nobody answers.
			systemctl stop --no-block "$unit"
			asks=$(grep -h '^PID=\|^Id=' /run/systemd/ask-password/ask.* 2> /dev/null | tr '\n' ' ')
			result failed "$unit asked for no passphrase within 60 s (requests open: ${asks:-none}): $(said "$unit" "$since")"
		fi
		result failed "answered, but $unit is still $(state_of "$unit") after 120 s; check by hand"
		;;
	esac
}

# ── the verbs ────────────────────────────────────────────────────────────────
verb=${1:-}
[ $# -gt 0 ] && shift
init=$(init_system)
case $verb in
read)
	while [ $# -ge 2 ]; do
		if [ "$init" = systemd ]; then
			read_systemd "$1" "$2"
		else
			printf '%s\tfail\tthis play unlocks on systemd only so far, and this host runs %s\n' "$1" "$init"
		fi
		shift 2
	done
	;;
unlock | mount)
	[ $# -eq 2 ] || result failed "usage: $verb <name> <mount>"
	[ "$init" = systemd ] || result failed "this play unlocks on systemd only so far, and this host runs $init"
	if [ "$verb" = unlock ]; then
		unlock_systemd "$1" "$2"
	else
		mount_systemd "$1" "$2"
		result mounted "was open; mounted at $2"
	fi
	;;
*)
	echo "usage: read <name> <mount>... | unlock <name> <mount> | mount <name> <mount>" >&2
	exit 2
	;;
esac
