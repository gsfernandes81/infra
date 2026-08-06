#!/bin/sh
# One-time ROOT setup for the destiny-director test bot on `two`
# (Raspberry Pi 1 B+, armv6l, ~475 MB usable RAM, Alpine 3.24.1 `sys` install, OpenRC).
#
# Read this before running it. It is the only step that NEEDS root: everything afterwards
# happens as `gavin`, over SSH, through `dd-ctl`. That is not the same as "afterwards is
# unprivileged" — `gavin` is in `wheel` with sudo installed, so `dd-ctl`'s dispatch is
# the whole boundary and its blast radius is root. See §1 and dd-ctl's own header.
#
#   sh root-setup.sh                       # everything except the destructive parts
#   DD_CTL_PUBKEY='ssh-ed25519 AAAA... label' sh root-setup.sh
#   DD_REMOVE_DOCKER=1 sh root-setup.sh    # additionally uninstall docker/containerd
#
# NOT EXECUTABLE, and not in bin/. Both are deliberate. CLAUDE.md's rule is that a
# one-shot script which tears down live stacks must not be left sitting on anyone's
# PATH; §12 of this one removes Docker, so that rule applies to it. It is kept anyway,
# here, because docs/host-setup.md exists precisely to record how a box was built and
# this is that record for `two` in the only form that cannot drift from what was
# actually run. Mode 0644 means it has to be invoked as `sh root-setup.sh`, which is
# also how it must be invoked on that box regardless — gavin's login shell is fish.
#
# Once it has been run and `two` is built, deleting it is a legitimate call; git history
# keeps it, and docs/host-setup.md's `two` section carries the summary. Do not move it
# to bin/.
#
# NOTE: `gavin`'s login shell is fish. Invoke this as `sh root-setup.sh`, never by
# relying on the shebang through a fish `ssh host 'script'` — and see §8, which is why
# a plain `.profile` export is not enough on this box.
#
# WHAT IT DOES NOT DO, and why. Each is a deliberate removal from the app repo's
# deploy/pi-bplus/root-setup.sh that this file is derived from:
#
#   * It creates NO user. That script created a `dd` account; this box already has
#     `gavin` (uid 1000, in wheel), and a second service account buys nothing — rootless
#     podman's isolation comes from the user namespace, not from which unprivileged uid
#     owns it. `gavin` gets the subuid/subgid range instead (§6).
#
#   * It installs NO boot autostart. The old /etc/local.d/podman-user.start is not
#     recreated, by decision. THE CONSEQUENCE IS INTENDED: after a power cut, a reboot,
#     or a watchdog reset, `two` comes back running NOTHING — no postgres, no bot, and
#     (see §9) no swap either. It stays that way until someone runs `dd-ctl deploy` over
#     SSH. On a box whose real job is being the fleet's lifeboat, a test bot that
#     silently resurrects itself at 03:00 and takes 200 MB of a 475 MB machine is the
#     wrong default. `restart: always` in compose.yaml covers process crashes; it does
#     not survive a reboot, and that is the point.
#
#   * It does NOT write to /boot. gpu_mem, the kernel cmdline and the armv6 kernel
#     selection are already configured. §10 VERIFIES and REPORTS them and writes
#     nothing. Generated content on the boot path is this fleet's one red line
#     (infra docs/decisions.md), and "the setup script also edits config.txt" is exactly
#     how that line gets crossed by accident.
#
#   * It does NOT edit /etc/fstab (§11). Same red line — /etc/fstab is tracked
#     read-only and never generated. It prints the recommendation; a human makes it.
#
#   * It takes NO service actions except the two it is explicitly asked for: enabling
#     zram swap (§9, additive and undone by `swapoff`) and, only under DD_REMOVE_DOCKER,
#     stopping and removing docker (§12). It never touches sshd, and never touches
#     cloudflared — the tunnel is the way in, and §12 refuses outright if cloudflared
#     turns out to be running as a docker container.
#
# POSIX sh, `set -eu`, idempotent — safe to re-run. Every mutation is announced, and a
# summary of what actually changed prints at the end.
#
set -eu

DD_USER="${DD_USER:-gavin}"
DD_CTL_PATH="${DD_CTL_PATH:-/usr/local/bin/dd-ctl}"
# Where the infra checkout is expected. dd-ctl reads compose.yaml and .env from
# <DD_CHECKOUT>/deployments/destiny-director. Nothing here creates or clones it — that
# is gavin's to do, unprivileged.
DD_CHECKOUT="${DD_CHECKOUT:-/home/gavin/infra}"
DD_STACK_DIR="$DD_CHECKOUT/deployments/destiny-director"
SUBID_START="${SUBID_START:-100000}"
SUBID_COUNT="${SUBID_COUNT:-65536}"
# Uncompressed capacity of the zram swap device, in MB. zram stores swapped pages
# compressed IN RAM, so this does not add memory — it trades CPU for effective capacity,
# and on one 700 MHz ARM1176 core that CPU is not cheap. It is a cushion for transient
# spikes, not a way to run a bigger workload.
ZRAM_SIZE_MB="${ZRAM_SIZE_MB:-256}"

SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Backups go OUTSIDE the directory of the file they back up, at mode 600. `foo.bak`
# beside `foo` is how a redacted secret survived in /etc/init.d on this fleet once
# already, and how a backup got picked up by OpenRC as a phantom service.
BACKUP_DIR="/root/.infra-backups/two/$STAMP"

CHANGED=''
NOTES=''

note()    { NOTES="$NOTES
  - $1"; }
changed() { CHANGED="$CHANGED
  - $1"; }
say()     { printf '%s\n' "$*"; }
ok()      { printf '       ok   %s\n' "$*"; }
warn()    { printf '       WARN %s\n' "$*"; }

backup() {  # backup <path>
	[ -f "$1" ] || return 0
	mkdir -p "$BACKUP_DIR"
	# The whole path with `/` mangled to `_`, not basename. Two files with the same
	# basename from different directories would otherwise land on each other inside one
	# run's backup directory, and the second would silently overwrite the first — so the
	# backup you reach for is of a file you were not thinking about. It does not happen
	# with the files this script touches today; it would be discovered the hard way if a
	# future section added one.
	_bk="$BACKUP_DIR/$(printf '%s' "${1#/}" | tr / _)"
	cp -a "$1" "$_bk"
	chmod 600 "$_bk"
	say "       backed up $1 -> $_bk (mode 600)"
}

pkg_installed() {  # pkg_installed <name>  — true only if actually installed
	[ -n "$(apk info -e "$1" 2>/dev/null)" ]
}

mem_avail_mb() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }

# ---------------------------------------------------------------------------------
say "== 1/12  preflight"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
id "$DD_USER" >/dev/null 2>&1 || {
	echo "no such user: $DD_USER. This script does not create users — see the header." >&2
	exit 1
}
if [ -f /etc/alpine-release ]; then
	ALPINE_REL="$(cat /etc/alpine-release)"
	ok "Alpine $ALPINE_REL"
	# Package names moved between 3.23 and 3.24 (shadow-uidmap -> shadow-subids, see
	# §3). If this box is ever rolled back or forward, re-check §3 against the real
	# APKINDEX for that release rather than trusting this script.
	case "$ALPINE_REL" in
		3.24.*) : ;;
		*) warn "this script's package list was verified against Alpine 3.24 — re-check §3" ;;
	esac
else
	warn "no /etc/alpine-release — this script targets Alpine/OpenRC"
fi
[ -d /run/openrc ] && ok "OpenRC is the running init" \
	|| warn "/run/openrc missing — is this really an OpenRC box?"
ok "arch $(uname -m), kernel $(uname -r)"
ok "memory: $(awk '/^MemTotal:/ {printf "%d MB total", $2/1024}' /proc/meminfo), $(mem_avail_mb) MB available"
ok "root fs: $(df -h / | awk 'NR==2 {print $4" free of "$2}')"

DD_UID="$(id -u "$DD_USER")"
DD_HOME="$(getent passwd "$DD_USER" | cut -d: -f6)"
DD_SHELL="$(getent passwd "$DD_USER" | cut -d: -f7)"
# The primary GROUP, asked for rather than assumed to equal the username. `chown
# gavin:gavin` fails outright if the primary group is `users`, and under `set -e` that
# kills this script mid-§5 — after the .ssh mkdir, before the key append, leaving a
# half-applied state on a box you reach through a tunnel.
DD_GROUP="$(id -gn "$DD_USER")"
[ -n "$DD_HOME" ] || { echo "cannot resolve $DD_USER's home directory" >&2; exit 1; }
[ -n "$DD_GROUP" ] || { echo "cannot resolve $DD_USER's primary group" >&2; exit 1; }
ok "$DD_USER: uid $DD_UID, group $DD_GROUP, home $DD_HOME, shell $DD_SHELL"

# `sudo` and the `wheel` group are relevant to everything below, so state them here
# rather than leaving them to be discovered. `gavin` is in `wheel` and sudo is
# installed, so anything that escapes the dd-ctl forced command lands on an account
# that can become root. Read the blast radius as root, not as "some unprivileged user".
if id -nG "$DD_USER" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
	warn "$DD_USER is in 'wheel' and sudo is present: an escape from dd-ctl is a root escape"
	note "THE DEPLOY KEY'S BLAST RADIUS IS ROOT. $DD_USER is in wheel with sudo installed, so
    dd-ctl's argument validation is the whole boundary and there is nothing behind it.
    dd-ctl has NOT had an adversarial review — see hosts/two/system/README.md."
fi

# The public key that gets the restricted forced command. A public key is not a secret,
# but nothing here bakes one in either — supply it, or leave an already installed one
# alone. There is no default: a wrong default key silently authorises somebody else's
# laptop.
#
# VALIDATED BEFORE ANYTHING IS WRITTEN, and validated here in the preflight so a bad
# value costs nothing. It is appended to authorized_keys AS ROOT in §5, and an embedded
# newline in it would append a SECOND line — one with no `command=` and no `restrict`,
# i.e. an entirely unrestricted key — while the run's output looked completely normal.
# Keys get copied out of chat windows, wikis and other people's terminals, so "a human
# supplied it" is not an assurance about its bytes. REFUSED, never sanitised: silently
# rewriting key material installs something nobody reviewed.
AUTHKEYS="$DD_HOME/.ssh/authorized_keys"
if [ -n "${DD_CTL_PUBKEY:-}" ]; then
	# The line count is checked SEPARATELY and FIRST, because grep matches per line and
	# would pass a two-line value on the strength of whichever line matched.
	if [ "$(printf '%s\n' "$DD_CTL_PUBKEY" | wc -l | tr -d ' ')" != 1 ]; then
		echo "refusing: DD_CTL_PUBKEY spans more than one line. An embedded newline" >&2
		echo "appends a second, UNRESTRICTED key line. Supply exactly one key." >&2
		exit 1
	fi
	if ! printf '%s\n' "$DD_CTL_PUBKEY" | grep -Eq \
		'^(ssh-ed25519|ecdsa-sha2-[a-z0-9-]+|ssh-rsa) [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$'
	then
		echo "refusing: DD_CTL_PUBKEY is not a single '<type> <base64> [comment]' key." >&2
		echo "Options and the command= prefix are added by this script — do not include" >&2
		echo "them, and do not include anything that is not a public key." >&2
		exit 1
	fi
	ok "DD_CTL_PUBKEY parses as one '<type> <base64> [comment]' public key"
fi

HAVE_FORCED_KEY=no
if [ -f "$AUTHKEYS" ]; then
	# The FULL prefix, including `restrict`, not just `command=`. A hand-written line
	# without `restrict` gets a pty, agent forwarding, port forwarding and ~/.ssh/rc —
	# a materially weaker thing. Accepting it as "already have the forced key" means
	# the weak line is never noticed and never replaced.
	if grep -qF "command=\"$DD_CTL_PATH\",restrict " "$AUTHKEYS"; then
		HAVE_FORCED_KEY=yes
	fi
	if grep -F "$DD_CTL_PATH" "$AUTHKEYS" | grep -qv 'restrict'; then
		warn "$AUTHKEYS has a dd-ctl line WITHOUT 'restrict'"
		note "A dd-ctl forced-command line in $AUTHKEYS lacks 'restrict', so that key still gets
    a pty and agent/port forwarding. Replace it by hand with:
      command=\"$DD_CTL_PATH\",restrict <type> <base64> <comment>
    This script appends and never edits, so it will not fix that line for you."
	fi
fi
if [ -z "${DD_CTL_PUBKEY:-}" ] && [ "$HAVE_FORCED_KEY" = no ]; then
	cat >&2 <<EOF

refusing: no DD_CTL_PUBKEY, and no dd-ctl forced command in $AUTHKEYS.

Re-run with the deploy key's PUBLIC half:

  DD_CTL_PUBKEY='ssh-ed25519 AAAA... dd-ctl@yourbox' sh $0

EOF
	exit 1
fi

# ---------------------------------------------------------------------------------
say "== 2/12  apk repositories"

# The obvious one-liner here — `sed -i 's|^#\(.*/community\)$|\1|'` — uncomments EVERY
# commented line ending in /community. That includes an `edge/community` somebody
# disabled on purpose, and a second mirror's line. Silently changing which RELEASE
# packages come from is not a small bug on a box you reach through a tunnel; it is how
# you end up with edge packages on a stable box and no memory of asking.
#
# So the wanted line is DERIVED from the /main line that is already enabled, and only
# that exact string is uncommented. This box has two mirrors present in the file
# (dl-cdn.alpinelinux.org and alpine.mirror.wearetriple.com) and is pinned to
# `latest-stable`, so "the community belonging to the main we are already using" is the
# only definition that yields one answer rather than two.
MAIN_REPO="$(awk '!/^[[:space:]]*#/ && /\/main[[:space:]]*$/ {print $1; exit}' /etc/apk/repositories)"
if [ -z "$MAIN_REPO" ]; then
	warn "no enabled */main line in /etc/apk/repositories — leaving the file alone"
	note "Could not derive the community repository from an enabled */main line. Enable it by
    hand before re-running, or §3 will fail on packages that live in community."
else
	WANT_COMMUNITY="${MAIN_REPO%/main}/community"
	if grep -qxF "$WANT_COMMUNITY" /etc/apk/repositories; then
		ok "community already enabled: $WANT_COMMUNITY"
	else
		# Compare each line's UNCOMMENTED form against the one string we want, so a
		# leading `# ` or `#` both match and nothing else can. The temp file is written
		# inside /etc — root-only — because `cmd > file` truncates before cmd runs and
		# because a temp in world-writable /tmp is its own problem.
		REPO_TMP=/etc/apk/repositories.infra-tmp
		awk -v want="$WANT_COMMUNITY" '
			{ s = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", s) }
			s == want { print want; next }
			{ print }
		' /etc/apk/repositories > "$REPO_TMP"
		if cmp -s "$REPO_TMP" /etc/apk/repositories; then
			rm -f "$REPO_TMP"
			warn "no commented line for $WANT_COMMUNITY — community NOT enabled"
			note "Add this line to /etc/apk/repositories by hand, then re-run:
      $WANT_COMMUNITY"
		else
			backup /etc/apk/repositories
			mv "$REPO_TMP" /etc/apk/repositories
			chmod 644 /etc/apk/repositories
			changed "enabled $WANT_COMMUNITY (that line only)"
			say "       enabled $WANT_COMMUNITY"
		fi
	fi
fi
apk update

# ---------------------------------------------------------------------------------
say "== 3/12  packages"

# Verified against the real Alpine v3.24 armhf APKINDEX (main + community), not against
# 3.23 and not from memory. The names that matter:
#
#   podman 5.8.3          its own deps already pull conmon, containers-common, netavark,
#                         aardvark-dns, catatonit, passt and cmd:newuidmap/newgidmap.
#                         They are named again below so the requirement is visible in
#                         the file rather than implied by a dependency graph.
#   podman-compose 1.6.0  depends on python3~3.14, so this pulls a Python interpreter.
#                         Disk is not a constraint here (27 G free).
#   crun                  named explicitly because podman depends on the virtual
#                         `oci-runtime`, which BOTH crun and runc provide. runc has no
#                         good armv6 story; letting apk pick is not worth the risk.
#   shadow-subids         THE RENAME. On Alpine 3.23 this was `shadow-uidmap`; on 3.24
#                         the newuidmap/newgidmap binaries live in `shadow-subids` and
#                         `shadow-uidmap` DOES NOT EXIST. `apk add` is atomic, so the
#                         old name would abort this entire install with a "package not
#                         found" and nothing else would happen.
#   iptables              THE TRAP, and it is now a double one:
#                         (a) netavark shells out to iptables to program the bridge
#                             network's NAT and filter rules — including inside a
#                             ROOTLESS network namespace — but the netavark package does
#                             NOT depend on it.
#                         (b) iptables IS currently installed on this box, but as a
#                             dependency of docker-engine and/or k3s. §12 removes those.
#                             `apk del` also removes orphaned auto-installed deps, so
#                             removing docker would take iptables with it and break
#                             podman networking days later, for reasons nobody would
#                             connect back to the docker cleanup.
#                         Installing it HERE, before §12, makes it an explicit member of
#                         the world set, so the docker removal cannot reclaim it. That
#                         ordering is load-bearing. Do not move this below §12.
#                         ip6tables is deliberately not installed: nothing here creates
#                         an IPv6-enabled network.
#   git                   already present, listed so a rebuild of this box still gets
#                         it. Needed to clone the infra repo; nothing is built here.
#   zram-init             a plain wrapper script (/usr/sbin/zram-init) — see §9. On
#                         Alpine it ships NO OpenRC service and NO /etc/conf.d file,
#                         unlike the Gentoo packaging infra's docs/host-setup.md
#                         describes.
say "       installing..."
apk add --no-cache \
	podman podman-compose crun conmon netavark aardvark-dns \
	passt shadow-subids catatonit \
	iptables git zram-init ca-certificates
ok "required packages present"

# fuse-overlayfs is podman's rootless fallback storage driver. Alpine 3.24's kernel plus
# crun should give NATIVE rootless overlay — confirm with `dd-ctl status`, which prints
# the driver. Having the fallback installed beats discovering at 2am that the only
# remaining option is vfs, which copies every layer onto the SD card.
if pkg_installed fuse-overlayfs; then
	ok "fuse-overlayfs already installed"
else
	apk add --no-cache fuse-overlayfs
	changed "installed fuse-overlayfs (rootless storage fallback)"
fi
note "confirm the storage driver reads 'overlay' (not 'vfs') with: dd-ctl status"

# ---------------------------------------------------------------------------------
say "== 4/12  install dd-ctl"

# THE DESTINATION MUST BE A REAL FILE OWNED BY ROOT, 0755, in a directory only root can
# write. Not a symlink, and never the checkout's copy run in place. $DD_USER owns the
# checkout, so a forced command that resolves through any path they can rewrite is not a
# restriction at all — the key holder replaces the target and has an unrestricted shell.
# The point was never to protect the box from gavin, who has sudo and owns the compose
# file and the .env; it is that the holder of the RESTRICTED KEY cannot rewrite the
# dispatcher restricting them, and that stops being true the moment anyone but root can
# write the destination. Whoever next "simplifies" this by pointing authorized_keys at
# the checkout has removed the entire mechanism.
#
# The SOURCE is deployments/destiny-director/dd-ctl — the single canonical copy in the
# infra repo (see its header). Two ways to reach it, tried in order, and the one used is
# printed rather than assumed:
#
#   1. This script's own checkout, if it is being run from inside one. The normal case
#      once `two` has the repo.
#   2. A copy scp'd beside this script. THE FIRST-RUN CASE: on a fresh box the repo is
#      not cloned yet, so both files travel together to /tmp.
#
# DD_CTL_SRC overrides both, for the case neither anticipates.
if [ -n "${DD_CTL_SRC:-}" ]; then
	say "       dd-ctl source: \$DD_CTL_SRC"
elif [ -f "$SELF_DIR/../../../deployments/destiny-director/dd-ctl" ] \
	&& [ -f "$SELF_DIR/../../../bin/check-sources" ]; then
	# The second test is the one that makes this safe: it confirms the three levels up
	# really are an infra checkout rather than a coincidence of directory names.
	DD_CTL_SRC="$(CDPATH= cd -- "$SELF_DIR/../../../deployments/destiny-director" && pwd -P)/dd-ctl"
	say "       dd-ctl source: the infra checkout this script is in"
elif [ -f "$SELF_DIR/dd-ctl" ]; then
	DD_CTL_SRC="$SELF_DIR/dd-ctl"
	say "       dd-ctl source: copied beside this script (pre-clone path)"
else
	cat >&2 <<EOF
refusing: cannot find dd-ctl.

Run this from an infra checkout (hosts/two/setup/root-setup.sh), or scp
deployments/destiny-director/dd-ctl next to this script, or set DD_CTL_SRC.
EOF
	exit 1
fi
sh -n "$DD_CTL_SRC" || {
	echo "refusing: $DD_CTL_SRC fails 'sh -n'" >&2
	exit 1
}
if [ -f "$DD_CTL_PATH" ] && [ ! -L "$DD_CTL_PATH" ] && cmp -s "$DD_CTL_SRC" "$DD_CTL_PATH"; then
	ok "$DD_CTL_PATH already identical"
else
	backup "$DD_CTL_PATH"
	# `install` copies CONTENT, so the destination is a real file even when the source
	# is reached through a symlinked path. A pre-existing symlink at the destination is
	# removed first — otherwise install would follow it and write through to whatever it
	# points at, which on a compromised box is the whole problem.
	rm -f "$DD_CTL_PATH"
	install -o root -g root -m 0755 "$DD_CTL_SRC" "$DD_CTL_PATH"
	changed "installed $DD_CTL_PATH (root:root 0755) from $DD_CTL_SRC"
	say "       installed $DD_CTL_PATH"
fi

# Verify the property rather than trusting `install` to have produced it. This is what
# the restricted key rests on, and checking it costs three stat calls.
[ -f "$DD_CTL_PATH" ] && [ ! -L "$DD_CTL_PATH" ] || {
	echo "refusing to continue: $DD_CTL_PATH is missing, or is a symlink" >&2
	exit 1
}
DD_CTL_ID="$(stat -c '%U:%G %a' "$DD_CTL_PATH")"
[ "$DD_CTL_ID" = "root:root 755" ] || {
	echo "refusing to continue: $DD_CTL_PATH is '$DD_CTL_ID', want 'root:root 755'" >&2
	exit 1
}
DD_CTL_DIR="$(dirname -- "$DD_CTL_PATH")"
DD_CTL_DIR_OWNER="$(stat -c '%U' "$DD_CTL_DIR")"
DD_CTL_DIR_MODE="$(stat -c '%a' "$DD_CTL_DIR")"
# A root-owned file in a group- or world-writable directory can be replaced wholesale by
# anyone who can write the directory: unlink and create is not a write to the file.
if [ "$DD_CTL_DIR_OWNER" != root ] || [ $(( 0$DD_CTL_DIR_MODE & 022 )) -ne 0 ]; then
	echo "refusing to continue: $DD_CTL_DIR is $DD_CTL_DIR_OWNER $DD_CTL_DIR_MODE — a" >&2
	echo "non-root or group/world-writable directory lets $DD_CTL_PATH be replaced." >&2
	exit 1
fi
ok "$DD_CTL_PATH: real file, root:root 0755, in $DD_CTL_DIR ($DD_CTL_DIR_OWNER $DD_CTL_DIR_MODE)"

# ---------------------------------------------------------------------------------
say "== 5/12  restricted SSH key for $DD_USER"

mkdir -p "$DD_HOME/.ssh"
touch "$AUTHKEYS"
chown -R "$DD_USER:$DD_GROUP" "$DD_HOME/.ssh"
chmod 700 "$DD_HOME/.ssh"
chmod 600 "$AUTHKEYS"

if [ -n "${DD_CTL_PUBKEY:-}" ]; then
	# `restrict` is the allow-nothing baseline (no pty, no agent/port/X11 forwarding, no
	# ~/.ssh/rc); `command=` replaces whatever the client asked for with dd-ctl and hands
	# the client's string over in SSH_ORIGINAL_COMMAND. dd-ctl treats that as hostile —
	# see its header. It also means the forced command bypasses gavin's fish login shell
	# entirely, which is one less thing to get wrong.
	#
	# APPENDED, never replacing the file: gavin's own unrestricted key lives here too,
	# and rewriting authorized_keys from a setup script is how you lock yourself out of a
	# box reachable only through a Cloudflare tunnel. No sshd restart is needed or done.
	LINE="command=\"$DD_CTL_PATH\",restrict $DD_CTL_PUBKEY"
	if grep -qF "$LINE" "$AUTHKEYS"; then
		ok "this exact forced-command line is already present"
	else
		backup "$AUTHKEYS"
		printf '%s\n' "$LINE" >> "$AUTHKEYS"
		chown "$DD_USER:$DD_GROUP" "$AUTHKEYS"
		chmod 600 "$AUTHKEYS"
		changed "appended a dd-ctl forced-command key to $AUTHKEYS"
		say "       appended forced-command entry"
		note "older dd-ctl keys in $AUTHKEYS are NOT pruned — review and remove any you no longer want"
	fi
else
	ok "no DD_CTL_PUBKEY given; leaving the existing forced-command entries alone"
fi

# ---------------------------------------------------------------------------------
say "== 6/12  subuid/subgid ranges for $DD_USER"

# 65536 sub-ids is the conventional single-range grant; podman maps the container's
# uid 0..65535 onto it. Without it (and without shadow-subids above) every rootless
# container collapses to one uid and the image's `USER dd` breaks. /etc/subuid on this
# box already carries gavin:100000:65536 — hence grep-before-append, so a re-run cannot
# add a duplicate, overlapping range.
for f in /etc/subuid /etc/subgid; do
	touch "$f"
	if grep -q "^$DD_USER:" "$f"; then
		ok "$f already grants $DD_USER: $(grep "^$DD_USER:" "$f" | tr '\n' ' ')"
	else
		backup "$f"
		printf '%s:%s:%s\n' "$DD_USER" "$SUBID_START" "$SUBID_COUNT" >> "$f"
		changed "granted $DD_USER $SUBID_START:$SUBID_COUNT in $f"
		say "       added $DD_USER:$SUBID_START:$SUBID_COUNT to $f"
	fi
done

# ---------------------------------------------------------------------------------
say "== 7/12  cgroups — VERIFY ONLY"

# Already correct on this box: /sys/fs/cgroup is cgroup2fs, the OpenRC `cgroups` service
# is started, and cgroup.controllers lists memory. Nothing to do — so this section
# reports and changes nothing, and any deviation shows up here rather than as a podman
# error later.
#
# Worth knowing, and NOT worth trying to fix from here: rootless podman under OpenRC has
# no cgroup delegation for user slices — there is no systemd or logind to hand a user a
# writable sub-tree — so no per-container memory.max is possible on this box regardless
# of what the controllers say. That is why compose.yaml sets no mem_limit and why the
# bot raises its own oom_score_adj instead.
if [ -d /sys/fs/cgroup ]; then
	CGFS="$(stat -f -c %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
	[ "$CGFS" = cgroup2fs ] && ok "/sys/fs/cgroup is cgroup2fs (unified)" \
		|| warn "/sys/fs/cgroup is '$CGFS', expected cgroup2fs"
fi
if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
	CTRL="$(cat /sys/fs/cgroup/cgroup.controllers)"
	ok "controllers: $CTRL"
	case " $CTRL " in
		*" memory "*) ok "the memory controller is available" ;;
		*) warn "NO memory controller — podman stats will report nothing useful"
		   note "memory controller absent despite cgroup_enable=memory; investigate before deploying" ;;
	esac
fi
rc-service cgroups status >/dev/null 2>&1 && ok "the cgroups service is started" \
	|| warn "the cgroups service is not started"

# The kernel cmdline on this box contains BOTH cgroup_disable=memory AND
# cgroup_enable=memory. The enable evidently wins — the controller is present — but a
# boot line that argues with itself is a trap for the next person who reads it, and the
# outcome depends on kernel parsing order rather than on intent. REPORTED, NEVER
# REWRITTEN: this script does not write to /boot, and a cmdline edit is a change you
# only find out about at the next reboot.
if grep -q 'cgroup_disable=memory' /proc/cmdline; then
	warn "the kernel cmdline contains cgroup_disable=memory AS WELL AS cgroup_enable=memory"
	note "CONTRADICTORY KERNEL CMDLINE: both cgroup_disable=memory and cgroup_enable=memory are
    present. The enable is currently winning (memory controller is live). Clean this up
    BY HAND in /boot/cmdline.txt, on a day you can watch the reboot — not from here."
fi
for want in cgroup_memory=1 cgroup_enable=memory; do
	grep -q "$want" /proc/cmdline && ok "running kernel has $want" \
		|| warn "running kernel is MISSING $want"
done

# ---------------------------------------------------------------------------------
say "== 8/12  XDG_RUNTIME_DIR for interactive sessions"

# Rootless podman needs XDG_RUNTIME_DIR and will not invent one. The usual answer,
# /run/user/<uid>, is created by logind — which Alpine does not have — or by the boot
# hook this deployment deliberately does not install. So dd-ctl uses podman's own
# fallback location, which an unprivileged process can create for itself, and creates it
# on every invocation.
#
# IT MUST BE THE SAME VALUE EVERYWHERE. Containers started under one XDG_RUNTIME_DIR are
# invisible to podman running under another: you get an empty `podman ps` standing next
# to a running bot. So the interactive shells get the same value written here.
#
# TWO files, because $DD_USER's login shell is fish and FISH DOES NOT READ .profile.
# Writing only .profile — which is what the app repo's script did, for a user whose shell
# was ash — would leave every interactive `podman ps` looking at an empty runtime dir.
RUNTIME_DIR="/tmp/podman-run-$DD_UID"

# /tmp IS WORLD-WRITABLE AND THIS PATH IS PREDICTABLE, so any other local uid — in
# principle including one of the subuids granted in §6 — can create it first and own it.
# Podman checks ownership and mode and refuses, so the exposure is denial of service
# rather than takeover; but the failure would present as podman being broken rather than
# as somebody else owning the directory, which is the expensive kind of wrong.
#
# Create it here, `mkdir -m 700` in one step (mkdir-then-chmod leaves a window at the
# default mode), and then VERIFY — creating it says nothing about what was already
# there. dd-ctl repeats this check on every invocation, because this script runs once
# and /tmp does not survive a reboot.
if [ -L "$RUNTIME_DIR" ]; then
	warn "$RUNTIME_DIR exists and is a SYMLINK — refusing to touch it"
	note "$RUNTIME_DIR is a symlink. Somebody else planted it. Remove it by hand, check who
    owns the target, and re-run. dd-ctl will refuse to start until this is resolved."
elif [ ! -d "$RUNTIME_DIR" ]; then
	mkdir -m 700 "$RUNTIME_DIR"
	chown "$DD_USER:$DD_GROUP" "$RUNTIME_DIR"
	changed "created $RUNTIME_DIR (0700, $DD_USER:$DD_GROUP)"
	say "       created $RUNTIME_DIR"
fi
if [ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ]; then
	RT_ID="$(stat -c '%U %a' "$RUNTIME_DIR")"
	if [ "$RT_ID" = "$DD_USER 700" ]; then
		ok "$RUNTIME_DIR is $DD_USER, mode 700"
	else
		warn "$RUNTIME_DIR is '$RT_ID', want '$DD_USER 700'"
		note "$RUNTIME_DIR is owned by somebody other than $DD_USER, or is not mode 700. Podman
    will refuse to use it and dd-ctl will refuse to start. Find out who created it
    before removing it — on a shared /tmp that is a question worth the answer."
	fi
fi

PROFILE="$DD_HOME/.profile"
if [ -f "$PROFILE" ] && grep -q 'XDG_RUNTIME_DIR' "$PROFILE"; then
	ok "$PROFILE already sets XDG_RUNTIME_DIR"
else
	printf 'export XDG_RUNTIME_DIR=%s\n' "$RUNTIME_DIR" >> "$PROFILE"
	chown "$DD_USER:$DD_GROUP" "$PROFILE"
	changed "added XDG_RUNTIME_DIR to $PROFILE (sh/ash/bash sessions)"
	say "       wrote $PROFILE"
fi

FISHCONF="$DD_HOME/.config/fish/conf.d/podman.fish"
if [ -f "$FISHCONF" ] && grep -q 'XDG_RUNTIME_DIR' "$FISHCONF"; then
	ok "$FISHCONF already sets XDG_RUNTIME_DIR"
else
	mkdir -p "$DD_HOME/.config/fish/conf.d"
	cat > "$FISHCONF" <<EOF
# Written by root-setup.sh. Rootless podman's runtime directory.
# MUST match the value dd-ctl sets for itself — see /usr/local/bin/dd-ctl. Containers
# created under a different XDG_RUNTIME_DIR are invisible to podman here.
set -gx XDG_RUNTIME_DIR $RUNTIME_DIR
EOF
	chown -R "$DD_USER:$DD_GROUP" "$DD_HOME/.config/fish"
	changed "wrote $FISHCONF (fish is $DD_USER's login shell, and fish ignores .profile)"
	say "       wrote $FISHCONF"
fi

# ---------------------------------------------------------------------------------
say "== 9/12  zram swap"

# This box has NO swap at all right now (/proc/swaps is empty) and no zram configured,
# despite what infra's docs/host-setup.md says about `two`. That doc also describes a
# /etc/conf.d/zram-init file and a zram-init OpenRC service: NEITHER EXISTS in Alpine's
# packaging. Alpine's zram-init package ships exactly one thing, /usr/sbin/zram-init, a
# wrapper script you invoke by hand; the conf.d/service pair is Gentoo's packaging of the
# same upstream project. `rc-update add zram-init` would fail with "service does not
# exist". docs/host-setup.md has been corrected accordingly.
#
# So this sets swap up LIVE, and it does NOT survive a reboot. Making it survive means
# boot-path code — a tracked /etc/init.d file with an infra- header, installed via
# bin/install-system-file — which is the shape docs/decisions.md rejected for the mount
# guards, on the box whose job is being the lifeboat. Not written, deliberately. Until
# somebody decides otherwise: no swap after a reboot, exactly like no containers after a
# reboot. Consistent, and stated rather than discovered.
#
# Set DD_SKIP_ZRAM=1 to skip. `swapoff /dev/zram0` undoes it.
if [ -n "${DD_SKIP_ZRAM:-}" ]; then
	ok "DD_SKIP_ZRAM set — skipping"
elif grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
	ok "a zram swap device is already active:"
	sed 's/^/            /' /proc/swaps
else
	# No -a (compression algorithm): the kernel default (lzo-rle on 6.x) is the right
	# pick on a CPU with no NEON, and hardcoding an algorithm this kernel may not have
	# compiled in turns a cushion into an error. -s 1 = one compression stream, because
	# there is one core.
	if zram-init -d 0 -s 1 -p 100 "$ZRAM_SIZE_MB"; then
		changed "enabled ${ZRAM_SIZE_MB} MB zram swap on /dev/zram0 (LIVE ONLY — gone after a reboot)"
		say "       zram swap active:"
		sed 's/^/            /' /proc/swaps
		note "zram swap is LIVE but NOT persistent. It disappears at the next reboot. Making it
    persistent needs an OpenRC service on the boot path — deliberately not written; see
    docs/decisions.md."
	else
		warn "zram-init failed — continuing without swap"
		note "zram swap could not be enabled; the stack must fit in RAM alone"
	fi
fi

# vm.swappiness for zram: swapping to compressed RAM is far cheaper than swapping to an
# SD card, so the kernel should be willing to do it. Written only if absent; applied at
# the next boot by the sysctl service, or now with `sysctl -p`.
SYSCTL_FILE=/etc/sysctl.d/60-zram.conf
if [ -f "$SYSCTL_FILE" ]; then
	ok "$SYSCTL_FILE already exists — not touched"
else
	cat > "$SYSCTL_FILE" <<'EOF'
# Written by root-setup.sh. Swapping to zram is compression, not I/O, so the usual
# reluctance to swap is miscalibrated for it. NOTE: /etc/sysctl.d/*.conf is the path
# Alpine reads; infra's docs/host-setup.md mentions /etc/sysctl.conf.d, which does not
# exist on Alpine and silently does nothing.
vm.swappiness = 100
vm.page-cluster = 0
EOF
	changed "wrote $SYSCTL_FILE (vm.swappiness=100, vm.page-cluster=0)"
	say "       wrote $SYSCTL_FILE — apply now with 'sysctl -p $SYSCTL_FILE'"
fi

# ---------------------------------------------------------------------------------
say "== 10/12  /boot — VERIFY ONLY, nothing written"

boot_grep() {  # boot_grep <pattern> <description>
	found=''
	for f in /boot/config.txt /boot/usercfg.txt; do
		[ -f "$f" ] || continue
		if grep -qE "$1" "$f"; then found="$f"; break; fi
	done
	if [ -n "$found" ]; then
		ok "$2  (in $found)"
	else
		warn "$2  — NOT FOUND in /boot/config.txt or /boot/usercfg.txt"
		note "expected but missing on /boot: $2"
	fi
}

if [ -f /boot/config.txt ]; then
	grep -qE '^[[:space:]]*include[[:space:]]+usercfg\.txt' /boot/config.txt \
		&& ok "config.txt includes usercfg.txt" \
		|| warn "config.txt has no 'include usercfg.txt' — anything in usercfg.txt is INERT"
	boot_grep '^[[:space:]]*gpu_mem=16' 'gpu_mem=16 (headless; RAM back to Linux)'
	boot_grep '^[[:space:]]*arm_64bit=0' 'arm_64bit=0 (armv6 board; 64-bit would not boot)'
	boot_grep '^[[:space:]]*kernel=vmlinuz-rpi' 'kernel=vmlinuz-rpi'
	boot_grep '^[[:space:]]*initramfs[[:space:]]+initramfs-rpi' 'initramfs initramfs-rpi'
else
	warn "/boot/config.txt not found — is /boot mounted?"
	note "/boot/config.txt missing; check 'mount | grep boot' before trusting section 10"
fi

# ---------------------------------------------------------------------------------
say "== 11/12  root filesystem mount options — VERIFY ONLY"

if awk '$2 == "/" && $4 ~ /noatime/ {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
	ok "root fstab entry already carries noatime"
elif grep -q ' / ' /etc/fstab 2>/dev/null; then
	warn "root fstab entry has no noatime"
	note "SD-card wear: consider adding noatime to the / entry in /etc/fstab BY HAND. Current entry:
      $(awk '$2 == "/" {print}' /etc/fstab)"
else
	warn "could not find a / entry in /etc/fstab"
fi

# ---------------------------------------------------------------------------------
say "== 12/12  docker / containerd / k3s removal"

# Docker 29.5.3 and containerd are installed and running on this box, and containerd
# alone holds ~34 MB RSS out of 475 MB. The owner has approved removing all of it: this
# deployment is rootless podman, gavin is not in the docker group and is not going to
# be, and running two container runtimes on this board is paying twice for one job.
#
# DESTRUCTIVE, so it is OPT-IN: without DD_REMOVE_DOCKER=1 this section only reports.
# Run the script once without it, read what it says, then run it again with it.
#
# ORDERING, and it matters:
#   1. iptables was already made an explicit world member in §3. `apk del` reclaims
#      orphaned auto-installed dependencies, and iptables is a dependency of both
#      docker-engine and k3s — without §3 first, this section would silently take
#      podman's networking with it.
#   2. Services are stopped and removed from their runlevels BEFORE the packages go.
#      Deleting a package out from under a running service leaves a service script
#      pointing at a missing binary.
#   3. docker-engine HARD-DEPENDS on the containerd package, and so does k3s. infra's
#      CLAUDE.md landmine "never apk del containerd" exists precisely because removing
#      it under a live docker kills every container at the next start. That rule is
#      satisfied here by removing the dependents in the SAME transaction, not by
#      exempting ourselves from it. containerd is never removed alone.
#   4. /var/lib/docker is NOT deleted. `apk del` does not touch it, and neither does
#      this: measure before deleting. Its size is reported so the decision can be made
#      with a number in it.

DOCKER_PKGS=''
for p in docker docker-engine docker-cli docker-cli-buildx docker-cli-compose \
         docker-openrc containerd containerd-openrc k3s k3s-openrc; do
	if pkg_installed "$p"; then DOCKER_PKGS="$DOCKER_PKGS $p"; fi
done

if [ -z "$DOCKER_PKGS" ]; then
	ok "no docker/containerd/k3s packages installed — nothing to do"
else
	say "       installed:$DOCKER_PKGS"
	if [ -S /var/run/docker.sock ]; then
		say "       docker.sock: $(ls -l /var/run/docker.sock)"
	fi
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		DOCKER_CONTAINERS="$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')"
		DOCKER_RUNNING="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
		say "       containers: $DOCKER_CONTAINERS total, $DOCKER_RUNNING running"
		[ "$DOCKER_RUNNING" != 0 ] && docker ps --format '            {{.Names}}  {{.Image}}  {{.Status}}'
	else
		DOCKER_CONTAINERS=0
		DOCKER_RUNNING=0
		say "       docker CLI/daemon not answering; going by package state only"
	fi
	if [ -d /var/lib/docker ]; then
		say "       /var/lib/docker: $(du -sh /var/lib/docker 2>/dev/null | cut -f1) (NOT deleted by this script)"
	fi
fi

# THE ONE THING THAT MUST NOT HAPPEN: this box is reachable only through a Cloudflare
# tunnel. If cloudflared were a docker container rather than the OpenRC service it is
# believed to be, stopping docker would cut the session doing the stopping and leave no
# way back in.
#
# The check this replaces asked `docker ps | grep -i cloudflare` and refused on a match.
# That is proving a negative from container NAMES: a tunnel container called `tunnel`,
# `argo`, or started from a retagged image sails past it, and the check then reads
# "safe" for exactly the case it exists to catch. It also only ran when the docker CLI
# answered, so a sick daemon skipped it entirely. A check that can pass for the wrong
# reason is worse than no check (docs/decisions.md).
#
# Inverted: REQUIRE positive proof that cloudflared is the OpenRC service, and refuse
# when the evidence is merely absent. Two independent facts, both required:
#
#   1. OpenRC reports the service started.
#   2. The running cloudflared's parent chain reaches pid 1 with no containerd, dockerd,
#      shim, conmon or runtime in it. A containerised process is reparented to a shim,
#      so this tells the two apart without trusting any name a container chose for
#      itself. Read from /proc/<pid>/status, not /proc/<pid>/stat — a comm containing
#      spaces or parentheses breaks field-numbered parsing of the latter.
cloudflared_is_openrc_service() {
	command -v rc-service >/dev/null 2>&1 || return 1
	rc-service cloudflared status 2>/dev/null | grep -qi 'started' || return 1
	CF_PID="$(pgrep -x cloudflared 2>/dev/null | head -n1)"
	[ -n "${CF_PID:-}" ] || return 1
	_p="$CF_PID"
	_hops=0
	while [ "$_p" -gt 1 ] 2>/dev/null; do
		[ "$_hops" -lt 32 ] || return 1
		case "$(cat "/proc/$_p/comm" 2>/dev/null || echo '?')" in
			*containerd*|*dockerd*|*shim*|*conmon*|*runc*|*crun*) return 1 ;;
			'?') return 1 ;;
		esac
		_p="$(awk '/^PPid:/ {print $2; exit}' "/proc/$_p/status" 2>/dev/null || echo '')"
		[ -n "$_p" ] || return 1
		_hops=$((_hops + 1))
	done
	[ "$_p" = 1 ]
}

if [ -n "$DOCKER_PKGS" ] && [ -n "${DD_REMOVE_DOCKER:-}" ]; then
	if ! cloudflared_is_openrc_service; then
		warn "could NOT confirm cloudflared is running as the OpenRC service"
		note "REFUSED to remove docker. This box is reachable only through the Cloudflare
    tunnel, and this script requires POSITIVE proof that cloudflared is the OpenRC
    service and is not containerised before it will stop docker. It could not get
    that proof — which may mean the tunnel is containerised, or only that the
    service is stopped or cloudflared is not running right now. Establish which,
    from a session that does not traverse the tunnel, then re-run. Check:
      rc-service cloudflared status
      pgrep -x cloudflared
      cat /proc/\$(pgrep -x cloudflared)/status"
		DOCKER_PKGS=''
	else
		ok "cloudflared is the OpenRC service (pid $CF_PID, parent chain reaches init)"
	fi
fi

if [ -n "$DOCKER_PKGS" ] && [ -n "${DD_REMOVE_DOCKER:-}" ]; then
	if [ "${DOCKER_RUNNING:-0}" != 0 ] && [ -z "${DD_REMOVE_DOCKER_FORCE:-}" ]; then
		warn "$DOCKER_RUNNING container(s) are RUNNING — refusing"
		note "docker removal refused: containers are running. Look at what they are (listed
    above). If they are genuinely disposable, re-run with DD_REMOVE_DOCKER_FORCE=1."
	else
		MEM_BEFORE="$(mem_avail_mb)"
		DISK_BEFORE="$(df -k / | awk 'NR==2 {print $4}')"

		for svc in docker containerd k3s; do
			if [ -f "/etc/init.d/$svc" ]; then
				say "       stopping $svc"
				rc-service "$svc" stop || warn "$svc stop returned non-zero; continuing"
				rc-update del "$svc" default 2>/dev/null || true
				rc-update del "$svc" boot 2>/dev/null || true
				changed "stopped $svc and removed it from its runlevels"
			fi
		done

		# One transaction, so apk resolves the dependency order itself and containerd is
		# never removed while a dependent still needs it.
		# shellcheck disable=SC2086  # deliberate word splitting of our own built list
		say "       apk del$DOCKER_PKGS"
		apk del $DOCKER_PKGS
		changed "removed packages:$DOCKER_PKGS"

		command -v docker >/dev/null 2>&1 \
			&& warn "a 'docker' binary is still on PATH — investigate" \
			|| ok "docker binary gone"
		[ -S /var/run/docker.sock ] \
			&& warn "/var/run/docker.sock still exists" \
			|| ok "docker.sock gone"
		# iptables must have survived §3's explicit install. Verify rather than assume —
		# this is the specific failure the ordering exists to prevent.
		pkg_installed iptables \
			&& ok "iptables survived the removal (this is what §3 was for)" \
			|| { warn "IPTABLES WAS REMOVED — podman networking will fail"; note "reinstall iptables immediately: apk add iptables"; }

		sleep 2
		MEM_AFTER="$(mem_avail_mb)"
		DISK_AFTER="$(df -k / | awk 'NR==2 {print $4}')"
		ok "memory available: ${MEM_BEFORE} MB -> ${MEM_AFTER} MB"
		ok "root fs free: $(( (DISK_AFTER - DISK_BEFORE) / 1024 )) MB reclaimed by package removal"
		if [ -d /var/lib/docker ]; then
			note "/var/lib/docker still holds $(du -sh /var/lib/docker 2>/dev/null | cut -f1). apk del does
    not remove it and neither did this. Delete it by hand once you are satisfied
    nothing in it is wanted."
		fi
	fi
elif [ -n "$DOCKER_PKGS" ]; then
	say ""
	say "       DRY RUN — nothing removed. To actually remove the above:"
	say "         DD_REMOVE_DOCKER=1 sh $0"
	note "docker/containerd/k3s are still installed and running. Re-run with DD_REMOVE_DOCKER=1."
fi

# ---------------------------------------------------------------------------------
say ""
say "======================================================================"
if [ -n "$CHANGED" ]; then
	say "CHANGED:$CHANGED"
else
	say "CHANGED: nothing — this box was already set up."
fi
say ""
if [ -n "$NOTES" ]; then
	say "NOTES / ACTION REQUIRED:$NOTES"
	say ""
fi
cat <<EOF
NEXT, and none of it needs root. $DD_USER's shell is fish, so these are written to be
pasted into an interactive fish session; anything with sh syntax is run as 'sh -c'.

  1. as $DD_USER:
       git clone <infra-repo-url> $DD_CHECKOUT
       cp $DD_STACK_DIR/.env.example $DD_STACK_DIR/.env
       chmod 600 $DD_STACK_DIR/.env
       \$EDITOR $DD_STACK_DIR/.env          # fill it in; it is gitignored

  2. from your workstation, with the restricted key:
       ssh -i <key> $DD_USER@ssh-two.gsrpi.uk status
       ssh -i <key> $DD_USER@ssh-two.gsrpi.uk deploy-beacon

Nothing on this box starts at boot, by design. After a power cut it runs no containers
and (see section 9) no swap until someone acts. That is intended, not a bug to fix by
adding a local.d hook.
EOF
