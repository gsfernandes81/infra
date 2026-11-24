#!/usr/bin/env bash
# Inspects openSUSE's Leap 16.1 Immutable Raspberry Pi image read-only, on an arm64 GitHub
# runner, and reports what a first boot and a bench boot lean on: Combustion in the initrd,
# the Pi 4's Wi-Fi firmware, the packages the image carries, its boot path and its partition
# table; and for zero, the Pi 5's device tree and config.txt section, the drivers between
# its SD card and its RP1 Ethernet and whether the initrd has them, the array's bcache,
# dm-crypt and Adiantum modules, and that bcache-tools is absent.
# .github/workflows/pi-image.yml runs it; leap/README.md § How it is tested says what it is
# for.
#
#   sudo sim/pi-image/inspect.sh <workdir> pinned    the image leap/pins names
#   sudo sim/pi-image/inspect.sh <workdir> current   the newest build openSUSE publishes
#
# It fails only when the download or the checksum fails; every other finding is an ANSWER
# line in <workdir>/report.txt. A pinned build openSUSE has withdrawn is a finding, not a
# failure: the pin records the copy the owner keeps on two (plans/visit-runbook.md), and
# the current leg still inspects the newest build. Nothing is written to the image: the
# loop device is read-only, and the image's own rpm and lsinitrd run in a chroot whose
# writes land in a tmpfs overlay. Run it only on a throwaway runner: it mounts, chroots,
# loops and runs the image's own binaries as root.
#
# The current leg trusts openSUSE's server: it checks the image against the .sha256 file
# beside it and not against the signed .sha256.asc. Its report is evidence about openSUSE's
# newest build, never a pin.

set -euo pipefail

work=${1:?usage: inspect.sh <workdir> pinned|current}
which=${2:?usage: inspect.sh <workdir> pinned|current}
repo=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=leap/pins
. "$repo/leap/pins"
: "${pi_image_url:?leap/pins has no pi_image_url}" "${pi_image_sha256:?leap/pins has no pi_image_sha256}"

mkdir -p "$work"
report=$work/report.txt
: >"$report"
say() { printf '%s\n' "$*" | tee -a "$report"; }
answer() { say "ANSWER: $*"; }
section() { say ""; say "== $*"; }
# Runs a command and puts its output in the report, never stopping on its failure.
show() { "$@" 2>&1 | tee -a "$report" || true; }

# Which build is newest is read from openSUSE's directory listing, since the unversioned
# alias's .sha256 names no build.
base=${pi_image_url%/*}
stem=${pi_image_url##*/}
stem=${stem%-Build*}
listing=$(curl -fsSL --retry 3 "$base/" || true)
current_name=$(printf '%s\n' "$listing" |
	grep -oE "${stem//./\\.}-Build[0-9.]+\\.raw\\.xz" | sort -uV | tail -n 1 || true)
current_sha=
[ -n "$current_name" ] &&
	current_sha=$(curl -fsSL --retry 3 "$base/$current_name.sha256" | awk '{print $1; exit}' || true)

case $which in
pinned)
	url=$pi_image_url
	sha=$pi_image_sha256
	;;
current)
	[ -n "$current_name" ] && [ -n "$current_sha" ] || {
		answer "FAIL: no current build found in $base/"
		exit 1
	}
	url=$base/$current_name
	sha=$current_sha
	;;
*)
	echo "inspect.sh: pinned or current, not $which" >&2
	exit 2
	;;
esac

section "Image ($which)"
say "url: $url"
say "expected sha256: $sha"
answer "pinned build: ${pi_image_url##*/}"
if [ -z "$listing" ] || [ -z "$current_sha" ]; then
	answer "current build on openSUSE: unknown (openSUSE's directory did not answer)"
elif [ "$current_sha" = "$pi_image_sha256" ]; then
	answer "current build on openSUSE: $current_name sha256 $current_sha"
	answer "the pinned build is still the current one: yes"
else
	answer "current build on openSUSE: $current_name sha256 $current_sha"
	answer "the pinned build is still the current one: no"
fi
if [ "$which" = current ] && [ "$current_sha" = "$pi_image_sha256" ]; then
	answer "current: the pinned leg inspects this build"
	exit 0
fi

# openSUSE answers 404 for a build it has replaced; any other failure is the download's.
if [ "$which" = pinned ] &&
	[ "$(curl -sIL --retry 3 -o /dev/null -w '%{http_code}' "$url")" = 404 ]; then
	answer "the pinned build is withdrawn from openSUSE (404): only the copy on two remains, and the current leg inspects ${current_name:-the newest build}"
	exit 0
fi

img=$work/image.raw
if ! curl -fL --retry 3 --retry-delay 15 -sS -o "$img.xz" "$url"; then
	answer "FAIL: download failed: $url"
	exit 1
fi
have=$(sha256sum "$img.xz" | awk '{print $1}')
say "bytes: $(stat -c %s "$img.xz"), sha256: $have"
if [ "$have" != "$sha" ]; then
	answer "FAIL: sha256 mismatch: have $have, want $sha"
	exit 1
fi
answer "download and sha256: OK ($(stat -c %s "$img.xz") bytes)"

if ! xz -T0 -dc "$img.xz" >"$img"; then
	answer "FAIL: the image did not decompress"
	exit 1
fi
rm -f "$img.xz"

# From here on nothing stops the run: each finding is reported, found or not.
set +e

mnt=$work/mnt
loop=
cleanup() {
	set +e
	for m in $(findmnt -rn -o TARGET | grep -F "$mnt" | sort -r); do umount -l "$m"; done
	[ -n "$loop" ] && losetup -d "$loop"
}
trap cleanup EXIT

section "Partition table"
show sfdisk -l "$img"
show sfdisk -d "$img"
loop=$(losetup -P -r -f --show "$img")
udevadm settle
show lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,PARTTYPENAME "$loop"
# The last partition is the one with the highest start sector.
last=$(sfdisk -d "$img" | awk -F'[:,= ]+' '/start=/ {print $1, $3}' | sort -k2,2n | tail -n 1 | awk '{print $1}')
last_dev=${loop}p${last#"$img"}
last_type=$(blkid -o value -s TYPE "$last_dev")
img_bytes=$(stat -c %s "$img")
last_end=$(($(sfdisk -d "$img" | awk -F'[:,= ]+' -v p="$last" '$1 == p {print $3 + $5}') * 512))
answer "partitions: $(lsblk -nr -o NAME,SIZE,FSTYPE,LABEL "$loop" | tail -n +2 | tr '\n' ';' | sed 's/;$//')"
answer "last partition: $last_dev ($last_type), ends at $last_end of $img_bytes image bytes; root is last: $([ "$last_type" = btrfs ] && echo yes || echo no)"

root=
for p in "$loop"p*; do
	t=$(blkid -o value -s TYPE "$p")
	d=$mnt/${p##*/}
	mkdir -p "$d"
	case $t in
	vfat) mount -o ro "$p" "$d" ;;
	btrfs) mount -o ro "$p" "$d" || mount -o ro,rescue=nologreplay "$p" "$d" && root=$d ;;
	*) rmdir "$d" ;;
	esac
done

section "Root filesystem"
if [ -z "$root" ]; then
	answer "root: no btrfs partition mounted"
else
	show btrfs subvolume get-default "$root"
	show btrfs subvolume list "$root"
	show btrfs property get "$root" ro
	show cat "$root/etc/os-release"
	answer "root default subvolume: $(btrfs subvolume get-default "$root" 2>&1)"
	answer "os: $(. "$root/usr/lib/os-release" 2>/dev/null; echo "${PRETTY_NAME:-unknown}") $(cat "$root/etc/os-release" 2>/dev/null | sed -n 's/^IMAGE_VERSION=//p')"
fi

# The image's own tools in a chroot over a tmpfs overlay: its rpm reads its sqlite database
# and may write beside it, and its lsinitrd knows its own initrd's compression.
ch=
if [ -n "$root" ]; then
	ov=$mnt/overlay
	mkdir -p "$ov"
	mount -t tmpfs tmpfs "$ov"
	mkdir -p "$ov/upper" "$ov/work" "$ov/merged"
	if mount -t overlay overlay -o "lowerdir=$root,upperdir=$ov/upper,workdir=$ov/work" "$ov/merged"; then
		ch=$ov/merged
		mount -t proc proc "$ch/proc"
		mount -t sysfs sysfs "$ch/sys"
		mount --bind /dev "$ch/dev"
		mount -t tmpfs tmpfs "$ch/tmp"
	fi
fi
inroot() { chroot "$ch" "$@"; }

section "Packages"
if [ -n "$ch" ] && inroot rpm -qa >"$work/packages.txt" 2>"$work/rpm.err"; then
	sort -o "$work/packages.txt" "$work/packages.txt"
	say "$(wc -l <"$work/packages.txt") packages; the full list is packages.txt in the artifact"
	for p in combustion ignition jeos-firstboot health-checker NetworkManager wpa_supplicant \
		bcm43xx-firmware kernel-firmware-brcm kernel-firmware-all kernel-firmware \
		u-boot-rpiarm64 raspberrypi-firmware raspberrypi-firmware-config raspberrypi-eeprom \
		grub2 grub2-arm64-efi grub2-bls sdbootutil systemd-boot shim tailscale docker \
		transactional-update; do
		answer "package $p: $(inroot rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "$p" 2>&1 | tr '\n' ' ' | sed 's/ $//')"
	done
	kfw=$(grep -E '^kernel-firmware' "$work/packages.txt" | tr '\n' ' ' | sed 's/ $//')
	answer "kernel-firmware packages: ${kfw:-none}"
	answer "kernel packages: $(grep -E '^kernel-' "$work/packages.txt" | grep -v '^kernel-firmware' | tr '\n' ' ' | sed 's/ $//')"
else
	answer "packages: the image's rpm did not run: $(head -c 300 "$work/rpm.err" 2>/dev/null)"
fi

section "Wi-Fi firmware (the Pi 4's radio is a BCM43455)"
if [ -n "$root" ]; then
	# usr/lib only: lib is a link to it on a merged /usr, and would count each file twice.
	fw=$(cd "$root" && find usr/lib/firmware -path '*brcm*' -name 'brcmfmac43455*' 2>/dev/null | sort -u)
	show printf '%s\n' "${fw:-none}"
	if [ -n "$fw" ]; then
		# Some names hold spaces, so one path per line.
		owners=$(printf '%s\n' "$fw" | while IFS= read -r f; do
			inroot rpm -qf --qf '%{NAME}\n' "/$f" 2>/dev/null
		done | sort -u | tr '\n' ' ')
		answer "brcmfmac43455 firmware: $(echo "$fw" | wc -l) files, owned by: ${owners:-unknown}"
	else
		answer "brcmfmac43455 firmware: none in the image"
	fi
fi

section "Dracut modules in the root filesystem"
if [ -n "$root" ]; then
	show ls "$root/usr/lib/dracut/modules.d"
	answer "dracut modules in root for combustion: $(ls "$root/usr/lib/dracut/modules.d" 2>/dev/null | grep -i combustion | tr '\n' ' ' || true)"
	answer "dracut modules in root for ignition: $(ls "$root/usr/lib/dracut/modules.d" 2>/dev/null | grep -i ignition | tr '\n' ' ' || true)"
fi

section "Initrds"
initrds=()
# Only where a boot loader looks: the root's /boot, and anywhere on a FAT partition. The
# root's /usr holds dracut's own initrd-* units, which are not initrds.
for d in "$mnt"/*; do
	[ "$d" = "$mnt/overlay" ] || [ "$d" = "$mnt/top" ] && continue
	w=$d
	[ "$d" = "$root" ] && w=$d/boot
	while IFS= read -r f; do initrds+=("$f"); done < <(find "$w" -xdev \( -iname 'initrd*' -o -iname '*.initrd' \) -type f 2>/dev/null)
done
[ ${#initrds[@]} -eq 0 ] && answer "initrd: none found on any partition"
# Each initrd that could be listed, as "path|listing", for the Pi 5's checks below.
listed=()
n=0
for f in "${initrds[@]}"; do
	n=$((n + 1))
	list=$work/initrd-$n.txt
	say "initrd $n: ${f#"$mnt"/} ($(stat -c %s "$f") bytes)"
	# The image's lsinitrd first; it can exit 0 having listed nothing when a decompressor
	# is missing, so a listing with no usr/ path counts as a failure.
	how=
	if [ -n "$ch" ] && cp "$f" "$ch/tmp/initrd" && inroot lsinitrd /tmp/initrd >"$list" 2>&1 &&
		grep -q 'usr/' "$list"; then
		how="the image's lsinitrd"
	elif lsinitramfs "$f" >"$list" 2>&1 && grep -q 'usr/' "$list"; then
		how="the runner's lsinitramfs"
	else
		answer "initrd ${f#"$mnt"/}: could not be listed: $(head -c 300 "$list")"
		continue
	fi
	[ -n "$ch" ] && rm -f "$ch/tmp/initrd"
	say "listed with $how; the full listing is initrd-$n.txt in the artifact"
	listed+=("$f|$list")
	# lsinitrd prints dracut's module list before the files.
	show sed -n '/dracut modules:/,/^==/p' "$list"
	show grep -iE 'combustion|ignition' "$list"
	# Yes means dracut built the module in and its program is there. lsinitramfs prints
	# no module list, so a listing made by it can answer only the second half.
	mods=$(sed -n '/^dracut modules:/,/^==/p' "$list")
	for m in combustion ignition; do
		if [ -z "$mods" ]; then
			inmod="no module list"
		elif printf '%s\n' "$mods" | grep -qx "$m"; then
			inmod=yes
		else
			inmod=no
		fi
		bin=no
		grep -qE "(^|[ /])usr/bin/$m\$" "$list" && bin=yes
		verdict=no
		[ "$inmod" = yes ] && [ "$bin" = yes ] && verdict=yes
		answer "initrd ${f#"$mnt"/}: $m: $verdict (dracut module: $inmod; usr/bin/$m: $bin)"
	done
	answer "initrd ${f#"$mnt"/}: combustion service or script: $(grep -oE '[^ ]*(combustion\.service|usr/bin/combustion|combustion-prepare[^ ]*)$' "$list" | sort -u | tr '\n' ' ' || true)"
done

section "Boot partitions"
for d in "$mnt"/*; do
	[ "$d" = "$mnt/overlay" ] || [ "$d" = "$root" ] && continue
	say "-- ${d##*/}"
	show find "$d" -maxdepth 3 -printf '%10s %P\n'
	for f in config.txt extraconfig.txt cmdline.txt; do
		[ -f "$d/$f" ] && say "--- ${d##*/}/$f" && show cat "$d/$f"
	done
	while IFS= read -r f; do
		say "--- ${f#"$mnt"/}"
		show head -n 60 "$f"
	done < <(find "$d" \( -iname 'grub.cfg' -o -path '*/loader/*.conf' \) -type f 2>/dev/null)
	while IFS= read -r f; do
		# GRUB and systemd-boot embed shim's name too, so they are asked for first.
		kind=
		for k in 'GNU GRUB' 'systemd-boot' 'U-Boot [0-9][^ ]*' 'shim'; do
			kind=$(strings "$f" | grep -m 1 -oE "$k")
			[ -n "$kind" ] && break
		done
		answer "boot binary ${f#"$mnt"/}: ${kind:-unrecognised}"
	done < <(find "$d" \( -iname '*.efi' -o -iname 'u-boot*.bin' \) -type f 2>/dev/null)
	answer "fat ${d##*/}: config.txt $([ -f "$d/config.txt" ] && echo yes || echo no); u-boot $(ls "$d" | grep -qi '^u-boot' && echo yes || echo no); EFI $([ -d "$d/EFI" ] && echo yes || echo no)"
	[ -f "$d/config.txt" ] && answer "config.txt kernel line: $(grep -E '^[[:space:]]*(kernel|arm_64bit|armstub)=' "$d/config.txt" | tr '\n' ' ')"
done

section "GRUB and health-checker in the root"
if [ -n "$root" ]; then
	show cat "$root/etc/sysconfig/bootloader"
	show ls -la "$root/boot" "$root/boot/grub2" "$root/boot/loader/entries"
	# grubenv is padded with #; only its settings are worth printing.
	say "--- /boot/grub2/grubenv settings"
	show grep -av '^#' "$root/boot/grub2/grubenv"
	say "--- /boot/grub2/grub.cfg: menu entries, and lines naming the env block, writable or health"
	show grep -nE "^menuentry|^submenu|env_block|writable|health" "$root/boot/grub2/grub.cfg"
	say "--- /boot/grub2/grub.cfg: the block that mounts /boot/writable"
	show sed -n '/boot_rw_subvol=/,/^fi/p' "$root/boot/grub2/grub.cfg"
	say "--- /usr/sbin/health-checker: lines naming the GRUB env"
	show grep -nE 'grub2-editenv|grubenv|env_block|writable' "$root/usr/sbin/health-checker"
	# /boot/writable is a subvolume of its own, so it is read from the top level.
	top=$mnt/top
	mkdir -p "$top"
	rootdev=$(findmnt -n -o SOURCE --target "$root" | sed 's/\[.*//')
	mount -o ro,subvolid=5 "$rootdev" "$top" ||
		mount -o ro,subvolid=5,rescue=nologreplay "$rootdev" "$top"
	say "--- @/boot/writable"
	show find "$top/@/boot/writable" -maxdepth 2 -printf '%10s %P\n'
	say "--- health-checker's files"
	[ -n "$ch" ] && show inroot rpm -ql health-checker
	hc=$( [ -n "$ch" ] && inroot rpm -ql health-checker 2>/dev/null | grep -E '/libexec/health-checker/|/plugins/' | sed 's|.*/||' | tr '\n' ' ')
	hcg=$( [ -n "$ch" ] && inroot rpm -ql health-checker 2>/dev/null | xargs -r -I{} grep -l -E 'grub2-editenv|grubenv|env_block' "$ch{}" 2>/dev/null | sed "s|^$ch||" | tr '\n' ' ')
	answer "bootloader setting: $(grep -E '^LOADER_TYPE=' "$root/etc/sysconfig/bootloader" 2>/dev/null || echo none)"
	answer "grub in root: grub.cfg $([ -f "$root/boot/grub2/grub.cfg" ] && echo yes || echo no), grubenv $([ -f "$root/boot/grub2/grubenv" ] && echo yes || echo no), settings in grubenv: $(grep -avc '^#' "$root/boot/grub2/grubenv"), BLS entries $(find "$root/boot/loader/entries" -type f 2>/dev/null | wc -l)"
	answer "grub.cfg names env_block: $(grep -c env_block "$root/boot/grub2/grub.cfg") lines; /boot/writable: $(find "$top/@/boot/writable" -mindepth 1 2>/dev/null | wc -l) entries"
	answer "health-checker plugins: ${hc:-none found}"
	answer "health-checker files that touch the GRUB env: ${hcg:-none}"
fi

section "The Pi 5 and zero's array"
# zero is a Pi 5 whose array is bcache under LUKS2 with Adiantum (plans/zero-leap.md). The
# answers ask the image's own modprobe, in the chroot, what it would load for a module, a
# crypto algorithm or a device's modalias, so aliases and built-in modules resolve as on
# the booted box. A module file counts as in an initrd only when its exact path under
# lib/modules is in that initrd's listing, so bcache never matches mbcache. Each group
# carries a calibration line: something known present that must read present, and a
# made-up name that must read absent.

# Yes when a device tree has a node whose compatible list holds this exact string: dtc
# decompiles it, so a string is matched whole and quoted, never inside another.
# shellcheck disable=SC2317  # called through yn
dtbhas() { dtc -q -I dtb -O dts "$1" 2>/dev/null | grep -E '^[[:space:]]*compatible = ' | grep -qF "\"$2\""; }
yn() { "$@" && echo yes || echo no; }

fats=()
for d in "$mnt"/*; do
	[ "$d" = "$mnt/overlay" ] || [ "$d" = "$mnt/top" ] || [ "$d" = "$root" ] && continue
	fats+=("$d")
done
pi5dtb=
pi4dtb=
for d in "${fats[@]}"; do
	f=${d##*/}
	# The firmware loads the first for a Pi 5 and the second for a D0-stepping board.
	for dtb in bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb; do
		if [ -f "$d/$dtb" ]; then
			answer "pi5: $f/$dtb: present, $(stat -c %s "$d/$dtb") bytes; a device tree for raspberrypi,5-model-b: $(yn dtbhas "$d/$dtb" raspberrypi,5-model-b)"
		else
			answer "pi5: $f/$dtb: absent"
		fi
	done
	[ -z "$pi5dtb" ] && [ -f "$d/bcm2712-rpi-5-b.dtb" ] && pi5dtb=$d/bcm2712-rpi-5-b.dtb
	[ -z "$pi4dtb" ] && [ -f "$d/bcm2711-rpi-4-b.dtb" ] && pi4dtb=$d/bcm2711-rpi-4-b.dtb
	if [ -f "$d/config.txt" ]; then
		if grep -qxF '[pi5]' "$d/config.txt"; then
			answer "pi5: $f/config.txt [pi5] section: yes: $(awk '/^\[/ { on = ($0 == "[pi5]"); next } on && !/^[[:space:]]*(#|$)/' "$d/config.txt" | tr '\n' ' ')"
		else
			answer "pi5: $f/config.txt [pi5] section: no"
		fi
	fi
	# U-Boot names the device tree of each board it recognises; the Pi 4's is the control.
	if [ -f "$d/u-boot.bin" ]; then
		ub=$(strings "$d/u-boot.bin")
		answer "pi5: $f/u-boot.bin names bcm2712-rpi-5-b.dtb: $(yn grep -qE '(^|/)bcm2712-rpi-5-b\.dtb$' <<<"$ub"); calibration, bcm2711-rpi-4-b.dtb: $(yn grep -qE '(^|/)bcm2711-rpi-4-b\.dtb$' <<<"$ub")"
	fi
done
[ -n "$pi5dtb" ] && show dtc -q -I dtb -O dts -o "$work/bcm2712-rpi-5-b.dts" "$pi5dtb"

kver=
ird=
irdlist=
[ -n "$root" ] && kver=$(cd "$root/usr/lib/modules" 2>/dev/null &&
	for k in *; do [ -f "$k/modules.dep" ] && echo "$k"; done | sort -V | tail -n 1)

# What the image's modprobe would load for a module, dependencies first: one line per
# module, "name path" with the path under /lib/modules, or "name builtin".
chain() {
	inroot modprobe -S "$kver" --show-depends "$1" 2>/dev/null | awk '
		$1 == "insmod" { p = $2; sub(/^.*\/lib\/modules\//, "", p); n = p; sub(/^.*\//, "", n)
			sub(/\.ko(\.(zst|xz|gz))?$/, "", n); gsub(/-/, "_", n); print n, p }
		$1 == "builtin" { print $2, "builtin" }'
}
# The modules an alias, a modalias or a module name resolves to.
targets() { inroot modprobe -S "$kver" -R "$1" 2>/dev/null | tr - _ | sort -u; }
# One module as the root has it, and, given an initrd's path index, whether that initrd
# has its file and every module file it depends on.
modline() {
	local m=$1 idx=${2-} c self name path n=0 miss=()
	c=$(chain "$m")
	self=$(awk -v m="$m" '$1 == m { print $2; exit }' <<<"$c")
	case $self in
	'') printf '%s: not in the root' "$m" && return ;;
	builtin) printf '%s: built into the kernel' "$m" && return ;;
	esac
	printf '%s: module %s' "$m" "${self#"$kver"/}"
	[ -n "$idx" ] || return
	if ! grep -qxF "$self" "$idx"; then
		printf ', not in the initrd'
		return
	fi
	while read -r name path; do
		[ "$path" = builtin ] || [ "$name" = "$m" ] && continue
		n=$((n + 1))
		grep -qxF "$path" "$idx" || miss+=("$name")
	done <<<"$c"
	if [ ${#miss[@]} -eq 0 ]; then
		printf ', in the initrd with all %s module dependencies' "$n"
	else
		printf ', in the initrd but without %s of %s dependencies: %s' "${#miss[@]}" "$n" "${miss[*]}"
	fi
}
# Every module a lookup resolves to, joined.
resolved() {
	local t out=
	for t in $(targets "$1"); do out="$out${out:+; }$(modline "$t" "${2-}")"; done
	printf '%s' "${out:-no module in the root resolves it}"
}

if [ -z "$ch" ] || [ -z "$kver" ]; then
	answer "pi5 and array modules: not checked (chroot: ${ch:-none}; kernel: ${kver:-none})"
else
	say "kernel modules: /lib/modules/$kver"
	# The initrd the boot loader pairs with this kernel, or else the first one listed.
	for e in "${listed[@]}"; do
		case ${e%%|*} in *"-$kver") ird=${e%%|*} irdlist=${e#*|} ;; esac
	done
	[ -z "$ird" ] && [ ${#listed[@]} -gt 0 ] && ird=${listed[0]%%|*} irdlist=${listed[0]#*|}
	idx=
	if [ -n "$irdlist" ]; then
		idx=$work/initrd-paths.txt
		awk '{ for (i = 1; i <= NF; i++) if ((j = index($i, "lib/modules/"))) print substr($i, j + 12) }' \
			"$irdlist" | sort -u >"$idx"
		say "initrd for the module checks: ${ird#"$mnt"/}"
	else
		answer "pi5: no initrd could be listed, so the initrd half is not checked"
	fi
	say "--- modules.alias lines for RP1's PCI id and its device tree nodes"
	show grep -iE 'v00001DE4|rp1' "$root/usr/lib/modules/$kver/modules.alias"
	show grep -aiE 'rp1' "$root/usr/lib/modules/$kver/modules.builtin"
	# The devices zero's first boot needs before it reaches the LAN: the SD card, then the
	# Ethernet behind RP1, which sits on PCIe. "label|compatible|lookup": the compatible is
	# checked in the Pi 5's device tree, and the lookup, a modalias, is resolved by modprobe.
	for item in \
		"SD card|brcm,bcm2712-sdhci|" \
		"PCIe, which RP1 sits on|brcm,bcm2712-pcie|" \
		"RP1 itself, PCI 1de4:0001|pci1de4,1|pci:v00001DE4d00000001sv00001DE4sd00000001bc02sc00i00" \
		"RP1 clocks|raspberrypi,rp1-clocks|" \
		"RP1 pin control|raspberrypi,rp1-gpio|" \
		"RP1 Ethernet MAC|raspberrypi,rp1-gem|" \
		"Ethernet PHY, BCM54213PE, id 0x600d84a2|-|mdio:01100000000011011000010010100010"; do
		label=${item%%|*}
		rest=${item#*|}
		compat=${rest%%|*}
		lookup=${rest#*|}
		[ -n "$lookup" ] || lookup="of:NnodeT<NULL>C$compat"
		indt=
		[ "$compat" != - ] && indt="; in bcm2712-rpi-5-b.dtb: $([ -n "$pi5dtb" ] && yn dtbhas "$pi5dtb" "$compat" || echo 'no dtb')"
		answer "pi5 $label ($compat)$indt; driver: $(resolved "$lookup" "$idx")"
	done
	answer "pi5 calibration, the Pi 4's Ethernet (brcm,bcm2711-genet-v5, which one and three first-booted over); in bcm2711-rpi-4-b.dtb: $([ -n "$pi4dtb" ] && yn dtbhas "$pi4dtb" brcm,bcm2711-genet-v5 || echo 'no dtb'); driver: $(resolved 'of:NnodeT<NULL>Cbrcm,bcm2711-genet-v5' "$idx")"
	answer "pi5 calibration, a made-up device (infra,no-such-device); in bcm2712-rpi-5-b.dtb: $([ -n "$pi5dtb" ] && yn dtbhas "$pi5dtb" infra,no-such-device || echo 'no dtb'); driver: $(resolved 'of:NnodeT<NULL>Cinfra,no-such-device' "$idx")"

	# The array: bcache under LUKS2, cipher xchacha12,aes-adiantum-plain64. The crypto API
	# loads an algorithm's module by its crypto- alias, so that is what is resolved.
	for m in bcache dm_mod dm_crypt; do
		answer "array module $(modline "$m")"
	done
	for a in adiantum xchacha12 xchacha20 nhpoly1305 aes; do
		answer "array crypto $a (crypto-$a): $(resolved "crypto-$a")"
	done
	answer "array calibration: $(modline btrfs) (the root's own filesystem); $(modline mbcache); $(modline no_such_module_infra) (made up)"
fi

if [ -n "$root" ]; then
	bt=$([ -n "$ch" ] && inroot rpm -q bcache-tools 2>&1)
	rules=$(cd "$root" && find usr/lib/udev etc/udev -name '*bcache*' 2>/dev/null | tr '\n' ' ')
	btr=$(cd "$root" && find usr/lib/udev etc/udev -name '*btrfs*' 2>/dev/null | tr '\n' ' ')
	irules=
	[ -n "$irdlist" ] && irules=$(grep -oE '[^ ]*udev/[^ ]*bcache[^ /]*$' "$irdlist" | sort -u | tr '\n' ' ')
	answer "bcache-tools: ${bt:-rpm did not run}; bcache udev files in the root: ${rules:-none}; in the initrd: ${irules:-none}; calibration, btrfs udev files in the root: ${btr:-none}"
fi

exit 0
