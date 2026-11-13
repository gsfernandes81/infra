#!/usr/bin/env bash
# Inspects openSUSE's Leap 16.1 Immutable Raspberry Pi image read-only, on an arm64 GitHub
# runner, and reports what the first boot and the visit's bench test lean on: Combustion in
# the initrd, the Pi 4's Wi-Fi firmware, the packages the image carries, its boot path and
# its partition table. .github/workflows/pi-image.yml runs it; leap/README.md § How it is
# tested says what it is for.
#
#   sudo sim/pi-image/inspect.sh <workdir> pinned    the image leap/pins names
#   sudo sim/pi-image/inspect.sh <workdir> current   the newest build openSUSE publishes
#
# It fails only when the download or the checksum fails; every other finding is an ANSWER
# line in <workdir>/report.txt. Nothing is written to the image: the loop device is
# read-only, and the image's own rpm and lsinitrd run in a chroot whose writes land in a
# tmpfs overlay. Run it only on a throwaway runner: it mounts, chroots and loops as root.

set -euo pipefail

work=${1:?usage: inspect.sh <workdir> pinned|current}
which=${2:?usage: inspect.sh <workdir> pinned|current}
repo=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=leap/pins
. "$repo/leap/pins"

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
current_name=$(curl -fsSL --retry 3 "$base/" |
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
answer "current build on openSUSE: ${current_name:-unknown} sha256 ${current_sha:-unknown}"
if [ "$current_sha" = "$pi_image_sha256" ]; then
	answer "the pinned build is still the current one: yes"
else
	answer "the pinned build is still the current one: no"
fi
if [ "$which" = current ] && [ "$current_sha" = "$pi_image_sha256" ]; then
	answer "current: the pinned leg inspects this build"
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

# From here on nothing stops the run: each finding is reported, found or not.
set +e
xz -T0 -dc "$img.xz" >"$img" && rm -f "$img.xz"

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
	fw=$(cd "$root" && find usr/lib/firmware lib/firmware -path '*brcm*' -name 'brcmfmac43455*' 2>/dev/null | sort -u)
	show printf '%s\n' "${fw:-none}"
	if [ -n "$fw" ]; then
		owners=$(for f in $fw; do inroot rpm -qf --qf '%{NAME}\n' "/$f" 2>/dev/null; done | sort -u | tr '\n' ' ')
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
	# lsinitrd prints dracut's module list before the files.
	show sed -n '/dracut modules:/,/^==/p' "$list"
	show grep -iE 'combustion|ignition' "$list"
	c=$(grep -ciE 'combustion' "$list")
	i=$(grep -ciE 'ignition' "$list")
	answer "initrd ${f#"$mnt"/}: combustion: $([ "$c" -gt 0 ] && echo "yes, $c lines" || echo no); ignition: $([ "$i" -gt 0 ] && echo "yes, $i lines" || echo no)"
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
	mount -o ro,subvolid=5 "$(findmnt -n -o SOURCE --target "$root" | sed 's/\[.*//')" "$top"
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

exit 0
