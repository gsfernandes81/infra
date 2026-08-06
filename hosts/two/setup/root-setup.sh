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
#   DD_CTL_ROTATE=1 sh root-setup.sh       # REPLACE an already-installed dispatch key
#   DD_CTL_PUBKEY='ssh-ed25519 AAAA... label' sh root-setup.sh   # bring your own key
#   DD_REMOVE_DOCKER=1 sh root-setup.sh    # prints `apk del --simulate` and STOPS
#   DD_REMOVE_DOCKER=1 DD_REMOVE_DOCKER_CONFIRMED=1 sh root-setup.sh   # actually removes
#
# THE DISPATCH KEY IS GENERATED HERE, and nothing has to be prepared before running this.
# §5 runs `ssh-keygen -t ed25519` into a directory on tmpfs, installs the PUBLIC half as
# the `command="…",restrict` line in $DD_USER's authorized_keys, prints the PRIVATE half
# ONCE as base64, and removes the directory before the script exits. Nothing on this box
# keeps a copy, and the private half never touches the SD card.
#
# The operator's whole job is to copy that one base64 line into the Claude Code cloud
# environment variable block as DD_CTL_KEY_B64. A SessionStart hook in the destiny-director
# repo writes it back out to ~/.ssh/id_ed25519_ddctl at the start of every agent session,
# so an ephemeral container has the key without anyone re-authorising anything.
#
# WHY BASE64: an environment variable block holds one line per value, and an OpenSSH
# private key is a multi-line PEM. Base64 of the whole file is the only encoding that
# survives that round trip without anyone hand-editing newlines back in.
#
# THE TWO HALVES LIVE IN TWO PLACES, and only one of them is secret: the public half on
# `two`, the private half in the cloud environment block. THAT BLOCK IS NOT MASKED — its
# values are readable to anyone who can open the environment's settings — which is exactly
# why the only key that belongs in it is this one: a key whose entire reach is the six
# argument-less verbs in dd-ctl. A shell key must never go there.
#
# ROTATION IS EXPLICIT, and that is the important half of this. If a dispatch line is
# already installed, a plain re-run does NOT generate a second one: two valid dispatch
# keys, with the operator unable to tell which one their environment holds, is worse than
# either alone. It reports the installed key's fingerprint and skips. DD_CTL_ROTATE=1 is
# how you replace it, and it REPLACES — the one deliberate exception to this file's
# append-never-rewrite doctrine for authorized_keys, taken with a backup first and with
# every other line in the file compared byte-for-byte before the new file is moved into
# place. See §5.
#
# DD_CTL_PUBKEY still works and is the escape hatch: a key already in a password manager,
# or a FIDO/`sk-` key, which this script cannot generate for you. Supplied keys go through
# the same validation, the same one-line rule and the same rotation gate as generated ones.
#
# The docker removal takes THREE runs, not two, and the middle one is the point: the
# package list §12 names is ten packages, but `apk del` reclaims orphaned dependencies
# too and the real transaction is around 36 — including `coreutils`, pulled in by k3s.
# Losing coreutils is not cosmetic: §7's `stat -f -c %T /sys/fs/cgroup` returns UNKNOWN
# under busybox's stat instead of `cgroup2fs`, so a re-run of this script would then warn
# about a cgroup setup that is in fact fine. A list nobody read is not an approval, so
# the middle run prints `apk del --simulate` and refuses to go further.
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
# THAT LOGIN SHELL IS ALSO PART OF THE DEPLOY KEY'S TRUSTED COMPUTING BASE, which is the
# single most important thing in this file. sshd does not exec a forced command; it runs
# `$SHELL -c "<command>"`. fish reads /etc/fish/config.fish, ~/.config/fish/conf.d/*.fish
# and ~/.config/fish/config.fish on EVERY startup, including a non-interactive `-c` (only
# `fish -N` skips them), and ~/.config/fish/ is gavin-writable — §8 of this script writes
# into it. So §4's proof that /usr/local/bin/dd-ctl is root-owned and unwritable is
# defeated one level up. See §5 for the full statement and what is and is not done about
# it.
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
	# NOT A SYMLINK, and the two tests are separate on purpose. `cp -a` preserves a
	# symlink AS a symlink, and the `chmod 600` below then FOLLOWS it and changes the
	# mode of whatever it points at — proven: a 755 target came back 600. So a backup of
	# a planted link would silently re-permission a file nobody was thinking about, which
	# is the same class of accident as the `.bak` in /etc/init.d this function's directory
	# choice exists to avoid.
	if [ -L "$1" ]; then
		warn "$1 is a SYMLINK — not backed up, and not followed"
		note "$1 is a symlink. It was NOT backed up (copying it and then chmod'ing the copy
    would have changed the mode of its target). Find out who planted it before letting
    anything here write through it."
		return 0
	fi
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

pkg_installed() {  # pkg_installed <name>  — true only if THAT package is installed
	# `apk info -e <name>` MATCHES BY PROVIDES, and prints the providing package's real
	# name — not the name asked for. `apk info -e shadow-uidmap` prints `shadow-subids`,
	# and `apk info -e docker` prints `podman-docker` on a box where podman-docker is
	# installed, because it provides `docker`. The old `[ -n "$(…)" ]` test therefore said
	# yes for a package that is not installed, and §12 would have put `docker` on its
	# removal list and taken podman-docker out with the real docker packages.
	#
	# So require the OUTPUT to be the name asked for, whole line and literally.
	apk info -e "$1" 2>/dev/null | grep -qxF "$1"
}

mem_avail_mb() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }

# --- the dispatch key ---------------------------------------------------------------
#
# EXACTLY ONE dispatch line in authorized_keys, at any time. Everything below exists to
# hold that invariant, because the failure it prevents is silent: append a second
# `command="…",restrict` line and the box has two valid dispatch keys, both working, with
# no way for the operator to tell which one their environment block holds. Revoking the
# wrong one then looks like a broken deploy rather than a revocation.
#
# DD_CTL_PREFIX is the full option string, not just `command=`. A hand-written line
# missing `restrict` gets a pty, agent forwarding, port forwarding and ~/.ssh/rc — a
# materially weaker key — so treating it as "the dispatch key is installed" would mean the
# weak line is never noticed and never replaced.
#
# THE TESTS BELOW ARE LITERAL PREFIX TESTS (`index($0, pfx) == 1`), not regular
# expressions. That is stronger than the anchored greps this replaces in two ways: no
# character in DD_CTL_PATH can widen what matches, and a COMMENTED-OUT copy of a dispatch
# line cannot match, because `#` is at position 1 and the prefix therefore is not.
DD_CTL_PREFIX=''   # set in §1, once DD_CTL_PATH has been validated

check_pubkey() {  # check_pubkey <value> <label>  — refuses, never sanitises
	# VALIDATED BEFORE ANYTHING IS WRITTEN. The value is appended to authorized_keys AS
	# ROOT, and an embedded newline in it would append a SECOND line — one with no
	# `command=` and no `restrict`, i.e. an entirely unrestricted key — while the run's
	# output looked completely normal. Keys get copied out of chat windows, wikis and other
	# people's terminals, so "a human supplied it" is not an assurance about its bytes.
	# REFUSED, never sanitised: silently rewriting key material installs something nobody
	# reviewed.
	#
	# THE GENERATED KEY GOES THROUGH THIS TOO. ssh-keygen's output needs no sanity check
	# for its own sake; running it through the same function is what makes the two paths
	# provably produce the same shape of line, so the census, the dedupe and the rotation
	# logic below cannot be reasoning about one shape while §5 installs another.
	_v="$1"; _label="$2"
	# The line count is checked SEPARATELY and FIRST, because grep matches per line and
	# would pass a two-line value on the strength of whichever line matched.
	if [ "$(printf '%s\n' "$_v" | wc -l | tr -d ' ')" != 1 ]; then
		echo "refusing: $_label spans more than one line. An embedded newline" >&2
		echo "appends a second, UNRESTRICTED key line. Supply exactly one key." >&2
		return 1
	fi
	# The key TYPES accepted include the FIDO/security-key variants. A hardware-backed
	# `sk-ssh-ed25519@openssh.com` key is the better key to hold for a deploy that can
	# become root, so rejecting it as "malformed" pushed the operator toward the weaker
	# option with a message that blamed their key. It is also the case this script cannot
	# generate for itself, which is the whole reason DD_CTL_PUBKEY survives.
	#
	# The COMMENT field permits tabs. `[^[:cntrl:]]` excludes tab — tab IS a control
	# character — so a key pasted out of a wiki or a spreadsheet, where the separator
	# arrives as a tab, was refused for a reason the message did not name. The literal
	# tab is built here rather than written as `\t`, which is not portable inside a
	# bracket expression; the `x` suffix survives command substitution's stripping of
	# trailing NEWLINES only, but costs nothing and makes the intent explicit.
	_tab="$(printf '\tx')"; _tab="${_tab%x}"
	if ! printf '%s\n' "$_v" | grep -Eq \
		"^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-[a-z0-9-]+|sk-ecdsa-sha2-[a-z0-9-]+@openssh\.com|ssh-rsa) [A-Za-z0-9+/=]+([ $_tab][[:print:]$_tab]*)?\$"
	then
		echo "refusing: $_label is not a single '<type> <base64> [comment]' key." >&2
		echo "Options and the command= prefix are added by this script — do not include" >&2
		echo "them, and do not include anything that is not a public key." >&2
		return 1
	fi
}

dispatch_count() {  # dispatch_count <authorized_keys>  — how many live dispatch lines
	[ -f "$1" ] || { echo 0; return 0; }
	awk -v pfx="$DD_CTL_PREFIX" 'index($0, pfx) == 1 { n++ } END { print n + 0 }' "$1"
}

dispatch_fingerprints() {  # dispatch_fingerprints <authorized_keys>
	# The fingerprint is how the operator identifies this key later — in this file's own
	# census, in `ssh -v` output, and against whatever their environment block holds. A
	# line ssh-keygen cannot read is reported as such rather than skipped: a fingerprint
	# list that silently omits a line is a check that passes for the wrong reason.
	awk -v pfx="$DD_CTL_PREFIX" \
		'index($0, pfx) == 1 { print substr($0, length(pfx) + 1) }' "$1" \
	| while IFS= read -r _dk; do
		printf '%s\n' "$_dk" | ssh-keygen -lf - 2>/dev/null \
			|| printf 'UNREADABLE — ssh-keygen cannot fingerprint this line\n'
	done
}

append_dispatch_line() {  # append_dispatch_line <authorized_keys> <line>
	# The doctrine everywhere else in this file: append, never rewrite. $DD_USER's own
	# unrestricted key lives in this file, and rewriting authorized_keys from a setup
	# script is how you lock yourself out of a box reachable only through a tunnel.
	printf '%s\n' "$2" >> "$1"
}

replace_dispatch_line() {  # replace_dispatch_line <authorized_keys> <line>
	# THE ONE DELIBERATE EXCEPTION to append-never-rewrite, and it is why rotation has to
	# be asked for by name. Everything here is arranged so that a botched rewrite cannot
	# reach the live file: the new content is built beside it, checked, and only then
	# renamed over it. rename(2) within a directory is atomic — there is no instant at
	# which authorized_keys is half-written or missing.
	#
	# The check that matters is the third one: every line that is NOT a dispatch line must
	# come back byte-for-byte identical. That is what distinguishes "replaced the dispatch
	# key" from "rewrote gavin's authorized_keys and hoped". Counting lines would not catch
	# a mangled key; comparing the kept lines does.
	_ak="$1"; _line="$2"
	_tmp="$_ak.infra-tmp"; _keep="$_ak.infra-keep"
	rm -f "$_tmp" "$_keep"
	awk -v pfx="$DD_CTL_PREFIX" 'index($0, pfx) != 1' "$_ak" > "$_keep"
	cp "$_keep" "$_tmp"
	printf '%s\n' "$_line" >> "$_tmp"
	chmod 600 "$_tmp"
	# `awk … | cmp -s - file` takes CMP's exit status, which is the one wanted here.
	# CLAUDE.md records the general trap (`a | b || c` tests b); this is the case where
	# that is the intent, stated so the next reader does not "fix" it.
	if ! awk -v pfx="$DD_CTL_PREFIX" 'index($0, pfx) != 1' "$_tmp" | cmp -s - "$_keep"; then
		rm -f "$_tmp" "$_keep"
		echo "refusing: rewriting $_ak would have changed a line that is not a dispatch line" >&2
		return 1
	fi
	if [ "$(dispatch_count "$_tmp")" != 1 ] || ! grep -qxF "$_line" "$_tmp"; then
		rm -f "$_tmp" "$_keep"
		echo "refusing: the rewritten $_ak does not hold exactly one dispatch line" >&2
		return 1
	fi
	# And that the result is a file sshd can still parse. ssh-keygen -lf exits non-zero
	# when it can read no key at all from the file, which is the wholesale-corruption case
	# this is here to catch — it does not, and is not asked to, validate every line.
	if ! ssh-keygen -lf "$_tmp" >/dev/null 2>&1; then
		rm -f "$_tmp" "$_keep"
		echo "refusing: ssh-keygen cannot read any key from the rewritten $_ak" >&2
		return 1
	fi
	mv -f "$_tmp" "$_ak"
	rm -f "$_keep"
}

# WHERE THE PRIVATE HALF IS GENERATED. /dev/shm first: it is tmpfs, so the key exists in
# RAM and never reaches the SD card — which is the only storage on this box that keeps
# what you delete. The fallback under /root is honest about being second best: on flash,
# `shred` overwrites the logical block and the controller's FTL is free to leave the
# original one intact, so the fallback is best-effort where /dev/shm is exact.
#
# /proc/mounts, not `stat -f -c %T`. §12 can remove coreutils, and busybox's `stat -f`
# answers UNKNOWN for filesystems it does not name — the same trap §7's cgroup check
# documents. Asking /proc/mounts whether /dev/shm is a tmpfs mount is exact under either
# stat, and unprivileged.
KEYDIR=''
make_keydir() {
	if [ -d /dev/shm ] && [ ! -L /dev/shm ] \
		&& awk '$2 == "/dev/shm" && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts
	then
		KEYDIR="$(mktemp -d /dev/shm/dd-ctl-key.XXXXXX)"
	else
		warn "/dev/shm is not a tmpfs mount — generating under /root instead"
		note "The dispatch key was generated in a directory on /root, not on tmpfs, because
    /dev/shm is not a tmpfs mount. It was shredded and removed, but shred on flash
    overwrites a logical block and the card's controller may keep the original. Treat
    the key as having touched the SD card."
		KEYDIR="$(mktemp -d /root/.dd-ctl-key.XXXXXX)"
	fi
	# mktemp -d already creates at 0700; asserted rather than assumed, because everything
	# below writes a private key into it.
	chmod 700 "$KEYDIR"
	[ "$(stat -c '%U %a' "$KEYDIR")" = "root 700" ] || {
		echo "refusing: $KEYDIR is not root-owned mode 700" >&2
		exit 1
	}
}

scrub_keydir() {
	# CALLED FROM THE EXIT TRAP, so an abort anywhere below §5 still removes the private
	# key. It must stay safe to call when nothing was generated, and safe to call twice.
	[ -n "$KEYDIR" ] || return 0
	if [ -d "$KEYDIR" ]; then
		# `find … -type f` rather than a fixed list of names: ssh-keygen's output file set
		# is its business, and a file this function did not think of is exactly the one
		# that would be left behind. -n 1, not the default 3 — on flash the extra passes
		# buy nothing but wear, and on tmpfs the first pass is already the whole story.
		find "$KEYDIR" -type f -exec shred -f -u -n 1 {} \; 2>/dev/null || true
		rm -rf "$KEYDIR"
	fi
	# An `x && warn` here would make the function's exit status 1 in the normal case, and
	# this runs from the EXIT trap under `set -e` — which would take the summary with it.
	if [ -e "$KEYDIR" ]; then
		warn "could NOT remove $KEYDIR — it may still hold the private key"
	fi
	KEYDIR=''
}

# THE SUMMARY PRINTS EVEN WHEN THE RUN DIES. `set -e` plus a summary at the bottom of the
# file means any mid-run abort — a failed `apk add`, a refusal in §4, a signal — leaves
# the record of what already changed only in scrollback, on a box reached through a
# tunnel. Every mutation above appends to CHANGED, so the trap is what makes that list
# worth keeping. RUN_COMPLETED gates the "NEXT" block only: a half-applied box should not
# be handed next steps as though it were built.
#
# The trap now also scrubs the generated private key, and the two belong together: both
# are things that must happen however the run ends. scrub_keydir runs FIRST, because if
# anything in summary() were to fail, the key would still be gone.
RUN_COMPLETED=no
summary() {
	say ""
	say "======================================================================"
	[ "$RUN_COMPLETED" = yes ] || say "RUN DID NOT COMPLETE — the sections after the failure did not run."
	if [ -n "$CHANGED" ]; then
		say "CHANGED:$CHANGED"
	elif [ "$RUN_COMPLETED" = yes ]; then
		say "CHANGED: nothing — this box was already set up."
	else
		# NOT "already set up". The run stopped early, so "nothing changed" here means
		# "nothing changed BEFORE the failure" and says nothing about the rest of the box.
		say "CHANGED: nothing, up to the point where the run stopped."
	fi
	say ""
	if [ -n "$NOTES" ]; then
		say "NOTES / ACTION REQUIRED:$NOTES"
		say ""
	fi
	[ "$RUN_COMPLETED" = yes ] || return 0
	cat <<EOF
NEXT, and none of it needs root. $DD_USER's shell is fish, so these are written to be
pasted into an interactive fish session; anything with sh syntax is run as 'sh -c'.

  1. as $DD_USER:
       git clone <infra-repo-url> $DD_CHECKOUT
       cp $DD_STACK_DIR/.env.example $DD_STACK_DIR/.env
       chmod 600 $DD_STACK_DIR/.env
       \$EDITOR $DD_STACK_DIR/.env          # fill it in; it is gitignored

  2. wherever the dispatch key's private half now lives — a Claude Code session that
     has DD_CTL_KEY_B64 in its environment block, or your own workstation:
       ssh -i ~/.ssh/id_ed25519_ddctl $DD_USER@ssh-two.gsrpi.uk status
       ssh -i ~/.ssh/id_ed25519_ddctl $DD_USER@ssh-two.gsrpi.uk deploy-beacon

  3. if this run PRINTED a private key: paste it into the environment block as
     DD_CTL_KEY_B64, then clear this terminal's scrollback. It is not recoverable
     from this box — DD_CTL_ROTATE=1 issues a new one, and invalidates this one.

Nothing on this box starts at boot, by design. After a power cut it runs no containers
and (see section 9) no swap until someone acts. That is intended, not a bug to fix by
adding a local.d hook.
EOF
}
trap 'scrub_keydir; summary' EXIT

# AND THE SIGNALS, WHICH THE EXIT TRAP DOES NOT COVER BY ITSELF. That claim above — "a
# signal" — was not true of the previous version: an untrapped SIGINT or SIGTERM
# terminates a POSIX shell without running the EXIT trap at all (verified against dash and
# busybox ash 1.37). It cost nothing when the trap only printed a summary. It costs a
# private key sitting in /dev/shm now, on the one run where the operator hits ^C while
# reading the output. Each handler does nothing but `exit`, which DOES run the EXIT trap,
# so there is still exactly one place that scrubs and one place that prints.
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM

# ---------------------------------------------------------------------------------
say "== 1/13  preflight"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
# DD_CTL_PATH is interpolated into ANCHORED grep patterns below (§1 and §5), where it is
# a basic regular expression rather than a fixed string — `grep -F` cannot anchor, and
# anchoring is the whole point of those greps. So constrain the path to characters that
# mean themselves. `.` is allowed and is the one benign exception: as a BRE it matches
# any character, but the only strings that would then match are paths differing from this
# one by a single character in that position, which is not a case anybody is attacking.
case "$DD_CTL_PATH" in
	/*) : ;;
	*) echo "refusing: DD_CTL_PATH must be an absolute path" >&2; exit 1 ;;
esac
case "$DD_CTL_PATH" in
	*[!A-Za-z0-9./_-]*)
		echo "refusing: DD_CTL_PATH contains a character outside [A-Za-z0-9./_-]." >&2
		echo "It is interpolated into anchored grep patterns; a metacharacter there" >&2
		echo "would silently widen what those patterns match." >&2
		exit 1 ;;
esac
# The literal prefix the dispatch-line helpers match on. They use it with awk's index()
# and with `grep -F`, so no character in it is special to them — the charset check above
# still matters, but only for the one remaining BRE, the "names dd-ctl but is not a
# dispatch line" grep further down this section.
DD_CTL_PREFIX="command=\"$DD_CTL_PATH\",restrict "
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

# The public key that gets the restricted forced command. It arrives one of two ways —
# generated by §5 (the default, and nothing needs preparing for it) or supplied in
# DD_CTL_PUBKEY — and this block decides which, and whether it is installed at all,
# BEFORE anything is written. A bad value costs nothing here.
#
# There is still no default key baked in, and there never can be: a wrong default silently
# authorises somebody else's laptop. "Generate one" is not a default key; it is a new key
# nobody else has ever held.
AUTHKEYS="$DD_HOME/.ssh/authorized_keys"
if [ -n "${DD_CTL_PUBKEY:-}" ]; then
	check_pubkey "$DD_CTL_PUBKEY" DD_CTL_PUBKEY || exit 1
	KEY_SOURCE=supplied
	ok "DD_CTL_PUBKEY parses as one '<type> <base64> [comment]' public key"
else
	KEY_SOURCE=generate
	command -v ssh-keygen >/dev/null 2>&1 || {
		echo "refusing: no ssh-keygen, and no DD_CTL_PUBKEY to fall back on." >&2
		echo "ssh-keygen ships in openssh-keygen, which openssh-server depends on — a box" >&2
		echo "running sshd should have it. Install it, or supply DD_CTL_PUBKEY yourself." >&2
		exit 1
	}
fi

# HOW MANY DISPATCH LINES ARE ALREADY THERE. Counted, not merely detected, because the
# whole point of the rotation gate is that the answer must never become 2.
#
# dispatch_count() matches a LITERAL prefix at position 1, which is what makes a
# COMMENTED-OUT copy of a dispatch line impossible to mistake for a live one. An earlier
# unanchored `grep -qF` did exactly that: a line sshd ignores entirely reported the box as
# already holding the restricted key, and §5's dedupe then said "already present" and
# installed nothing — with nothing in CHANGED: to show for it. A check that passes for the
# wrong reason is worse than no check (docs/decisions.md).
DISPATCH_N="$(dispatch_count "$AUTHKEYS")"
if [ -f "$AUTHKEYS" ]; then
	# Lines that NAME dd-ctl but are not a dispatch line. The old form asked whether
	# the line contained the string `restrict` anywhere, which a key COMMENT of
	# `dd-ctl-restricted@laptop` satisfies — defeating the warning on exactly the weak
	# line it exists to find. Comment lines are dropped first because sshd ignores them,
	# so warning about one is noise. The pipeline's exit status is the LAST grep's, which
	# is what is wanted here and is stated because CLAUDE.md records the general trap.
	if grep -v '^[[:space:]]*#' "$AUTHKEYS" \
		| grep -F "$DD_CTL_PATH" \
		| grep -qv "^command=\"$DD_CTL_PATH\",restrict "
	then
		warn "$AUTHKEYS has a dd-ctl line that is NOT '$DD_CTL_PREFIX…'"
		note "A line in $AUTHKEYS names $DD_CTL_PATH but does not begin with
      ${DD_CTL_PREFIX}<type> <base64> <comment>
    so it is either missing 'restrict' — that key still gets a pty and agent/port
    forwarding — or carries options this script did not write. Fix it by hand: rotation
    replaces dispatch lines and will not touch this one. The census at the end of this
    run lists every key."
	fi
fi

# THE PLAN, DECIDED HERE AND ANNOUNCED HERE, so the operator learns what §5 intends before
# §2-§4 have scrolled it off the screen. Four outcomes:
#
#   install   nothing is installed yet — install one (generated or supplied).
#   present   the supplied key IS the installed dispatch key. Nothing to do, no rotation
#             needed; re-running with the same DD_CTL_PUBKEY is not a request to churn.
#   keep      a dispatch key is installed and no rotation was asked for. SKIP — do not
#             generate, do not append. This is the case that matters: appending here would
#             leave two valid dispatch keys, both working, and the operator could not tell
#             which one their environment block holds. Reported with the fingerprint so it
#             can be matched against what they have.
#   rotate    DD_CTL_ROTATE=1 and something is installed — REPLACE it.
#
# The gate applies to supplied keys too, and deliberately. The hazard is not "the script
# generated a key"; it is "authorized_keys grew a second dispatch line", which a supplied
# key does just as readily. Before this, DD_CTL_PUBKEY with a different key silently
# appended.
if [ "$DISPATCH_N" -eq 0 ]; then
	KEY_PLAN=install
elif [ "$KEY_SOURCE" = supplied ] && [ "$DISPATCH_N" -eq 1 ] \
	&& grep -qxF "$DD_CTL_PREFIX$DD_CTL_PUBKEY" "$AUTHKEYS"; then
	KEY_PLAN=present
elif [ -n "${DD_CTL_ROTATE:-}" ]; then
	KEY_PLAN=rotate
else
	KEY_PLAN=keep
fi
case "$KEY_PLAN" in
	install)
		[ -z "${DD_CTL_ROTATE:-}" ] || warn "DD_CTL_ROTATE is set, but no dispatch key is installed — installing one"
		ok "no dd-ctl dispatch key installed; §5 will install one ($KEY_SOURCE)" ;;
	present)
		ok "the key in DD_CTL_PUBKEY is already the installed dispatch key; §5 has nothing to do" ;;
	keep)
		ok "a dd-ctl dispatch key is already installed; §5 will leave it alone (DD_CTL_ROTATE=1 to replace)" ;;
	rotate)
		warn "DD_CTL_ROTATE=1 — §5 will REPLACE the $DISPATCH_N installed dispatch line(s)" ;;
esac
if [ "$DISPATCH_N" -gt 1 ]; then
	warn "$AUTHKEYS holds $DISPATCH_N dispatch lines — there should be exactly one"
	note "$AUTHKEYS holds $DISPATCH_N dd-ctl dispatch lines. Every one of them is a working
    deploy key, and nothing here can tell you which one is in use. Rotating
    (DD_CTL_ROTATE=1) collapses them to a single new key, which is the fix; removing the
    surplus by hand is the other. The census at the end of this run lists them all."
fi

# ---------------------------------------------------------------------------------
say "== 2/13  apk repositories"

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
say "== 3/13  packages"

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
#   shadow-subids         THE RENAME — and the name here is right for a reason this
#                         comment used to get wrong. On Alpine 3.23 the newuidmap/
#                         newgidmap binaries were in `shadow-uidmap`; on 3.24 they are in
#                         `shadow-subids`. What is NOT true, and was claimed here, is
#                         that `shadow-uidmap` "does not exist" on 3.24 and would abort
#                         the install: `shadow-subids` PROVIDES `shadow-uidmap=4.18.0-r1`
#                         and `apk add shadow-uidmap` resolves and installs it cleanly.
#                         The old name would have worked. `shadow-subids` is still the
#                         right thing to write — it is the real package, and it is what
#                         `apk info -e` answers with, which is what pkg_installed()
#                         compares against — but "the other name is fatal" was a fiction,
#                         and a fiction is what gets copied into the next box's script.
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
#                         THERE IS NO SEPARATE ip6tables DECISION. An earlier version of
#                         this comment said ip6tables was "deliberately not installed";
#                         there is no such package to not install — Alpine's `iptables`
#                         package PROVIDES `ip6tables` and ships /sbin/ip6tables and
#                         ip6tables-restore in the same apk. Whatever the box does about
#                         IPv6, that line is already installed by the line above.
#   ca-certificates       PINNED HERE FOR THE SAME REASON AS iptables, and it is just as
#                         load-bearing. It is on this box today only as a dependency —
#                         docker-engine pulls it — and §12's `apk del` reclaims orphaned
#                         auto-installed dependencies. Losing it takes the trust store
#                         with it, and the trust store is what cloudflared validates
#                         Cloudflare's edge against: the removal would cut the only way
#                         into the box, some minutes after reporting success. Naming it
#                         in this `apk add` makes it a world member that no reclaim can
#                         touch. Do not move it below §12 either.
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
say "== 4/13  install dd-ctl"

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

# THE DIRECTORY IS CHECKED BEFORE ANYTHING IS WRITTEN INTO IT, not after. A root-owned
# file in a group- or world-writable directory can be replaced wholesale by anyone who
# can write the directory: unlink-and-create is not a write to the file. Checking that
# after installing meant the script had already created a file — and, below, a temporary
# one — in a directory it had not yet established anyone could trust.
DD_CTL_DIR="$(dirname -- "$DD_CTL_PATH")"
DD_CTL_DIR_OWNER="$(stat -c '%U' "$DD_CTL_DIR")"
DD_CTL_DIR_MODE="$(stat -c '%a' "$DD_CTL_DIR")"
if [ "$DD_CTL_DIR_OWNER" != root ] || [ $(( 0$DD_CTL_DIR_MODE & 022 )) -ne 0 ]; then
	echo "refusing to continue: $DD_CTL_DIR is $DD_CTL_DIR_OWNER $DD_CTL_DIR_MODE — a" >&2
	echo "non-root or group/world-writable directory lets $DD_CTL_PATH be replaced." >&2
	exit 1
fi

if [ -f "$DD_CTL_PATH" ] && [ ! -L "$DD_CTL_PATH" ] && cmp -s "$DD_CTL_SRC" "$DD_CTL_PATH"; then
	ok "$DD_CTL_PATH already identical"
else
	backup "$DD_CTL_PATH"
	# INSTALL BESIDE, THEN RENAME. The previous form was `rm -f "$DD_CTL_PATH"` followed
	# by `install`, which opens a window in which the live dispatcher does not exist: if
	# `install` fails — a full SD card is the obvious way — the forced command points at
	# nothing and every `ssh two deploy-beacon` dies, on the box you reach through a
	# tunnel. `mv` within one directory is a rename(2): the replacement is atomic, and it
	# replaces a pre-existing SYMLINK at the destination rather than writing through it,
	# which is the property `rm -f` was there for. `install` copies CONTENT, so the result
	# is a real file even when the source was reached through a symlinked path.
	rm -f "$DD_CTL_PATH.new"
	install -o root -g root -m 0755 "$DD_CTL_SRC" "$DD_CTL_PATH.new"
	mv -f "$DD_CTL_PATH.new" "$DD_CTL_PATH"
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
ok "$DD_CTL_PATH: real file, root:root 0755, in $DD_CTL_DIR ($DD_CTL_DIR_OWNER $DD_CTL_DIR_MODE)"

# --- and the part everything above is not enough for -------------------------------
#
# SSHD DOES NOT EXEC A FORCED COMMAND. It runs `$SHELL -c "<command>"`. $DD_USER's login
# shell is fish, and fish reads /etc/fish/config.fish, ~/.config/fish/conf.d/*.fish and
# ~/.config/fish/config.fish on EVERY startup, including a non-interactive `-c` — only
# `fish -N` skips them. So the four files below run, as $DD_USER, before dd-ctl does, and
# any one of them can replace the dispatch entirely. `restrict` does not help: it implies
# `no-user-rc`, which is about ~/.ssh/rc, a different file.
#
# Three of the four are inside $DD_USER's own home and are therefore WRITABLE BY
# $DD_USER BY CONSTRUCTION — §8 of this script writes one of them. Nothing here can
# change that, and pretending otherwise is how the previous version of this file ended up
# claiming the forced command "bypasses gavin's fish login shell entirely", which is
# false. What CAN be established, and is:
#
#   * that no THIRD party can write them (no group or world write bit, owner is
#     $DD_USER or root),
#   * that /etc/fish/config.fish — the one file outside the home, which every fish on
#     the box reads — is root-owned and not writable by anyone else,
#   * and that conf.d/ holds nothing this script did not write, which the census at the
#     end of the run lists in full.
#
# The residual is stated rather than closed: the ambient login shell is inside the deploy
# key's trusted computing base, and the only thing that removes it is a dedicated deploy
# account with /bin/sh and an empty home. docs/decisions.md rejected that account — and
# did so WITHOUT this fact in front of it. It is restated there with the fact included.
FISH_STARTUP_FILES="/etc/fish/config.fish $DD_HOME/.profile $DD_HOME/.config/fish/config.fish"
FISH_CONFD="$DD_HOME/.config/fish/conf.d"
check_startup_file() {  # check_startup_file <path>
	[ -e "$1" ] || { ok "$1 absent"; return 0; }
	if [ -L "$1" ]; then
		warn "$1 is a SYMLINK — it runs before dd-ctl does, and points somewhere else"
		note "$1 is a symlink. It is executed by fish before the dd-ctl forced command runs.
    Resolve where it points and who owns that, by hand."
		return 0
	fi
	_o="$(stat -c '%U' "$1")"
	_m="$(stat -c '%a' "$1")"
	case "$1" in
		/etc/*) _want_owner=root ;;
		*)      _want_owner="$DD_USER" ;;
	esac
	if [ "$_o" != "$_want_owner" ] && [ "$_o" != root ]; then
		warn "$1 is owned by '$_o', expected $_want_owner or root"
		note "$1 runs as $DD_USER before dd-ctl does, and is owned by '$_o' — a third account
    controls the deploy path. Fix the ownership by hand."
	elif [ $(( 0$_m & 022 )) -ne 0 ]; then
		warn "$1 is mode $_m — group- or world-writable"
		note "$1 is mode $_m. fish executes it before the dd-ctl forced command, so any account
    that can write it controls what the deploy key runs. chmod it to 644 (or 600)."
	else
		ok "$1: $_o, mode $_m"
	fi
}
# THE DIRECTORIES, NOT JUST THE FILES. Checking a file's mode while the directory
# holding it is group- or world-writable is a check that passes for the wrong reason:
# anyone who can write the directory can unlink the file and create their own — that is
# not a write to the file, and no amount of `stat` on the file sees it coming. It is the
# same reasoning that makes §4 check $DD_CTL_DIR before installing into it, applied to
# the four startup files. The chain stops at $DD_HOME; /home and / are the distribution's
# to get right, and if they are wrong this box has larger problems than a deploy key.
check_startup_dir() {  # check_startup_dir <path> <what-lives-here>
	[ -d "$1" ] || { ok "$1 absent"; return 0; }
	_o="$(stat -c '%U' "$1")"
	_m="$(stat -c '%a' "$1")"
	if [ "$_o" != "$DD_USER" ] && [ "$_o" != root ]; then
		warn "$1 is owned by '$_o' — it holds $2"
		note "$1 is owned by '$_o', and it holds $2. Whoever owns a directory can replace the
    files in it wholesale — unlink and create is not a write, so the file's own mode
    says nothing. Fix the ownership by hand."
	elif [ $(( 0$_m & 022 )) -ne 0 ]; then
		warn "$1 is mode $_m — group- or world-writable, and it holds $2"
		note "$1 is mode $_m, so any account that can write it can REPLACE $2 — unlink and
    create, which the file's own mode does not prevent. Every one of those files runs
    as $DD_USER before the dd-ctl forced command does. chmod it to 755 or tighter."
	else
		ok "$1: $_o, mode $_m"
	fi
}
for f in $FISH_STARTUP_FILES; do check_startup_file "$f"; done
check_startup_dir /etc/fish "config.fish, which every fish on this box reads"
check_startup_dir "$DD_HOME" ".profile"
check_startup_dir "$DD_HOME/.config" "the fish configuration tree"
check_startup_dir "$DD_HOME/.config/fish" "config.fish and conf.d/"
if [ -d "$FISH_CONFD" ]; then
	check_startup_dir "$FISH_CONFD" "every .fish file fish runs at startup"
	# podman.fish is the only file §8 writes. Anything else here is unaccounted for.
	for f in "$FISH_CONFD"/*.fish; do
		[ -e "$f" ] || continue
		case "$f" in
			"$FISH_CONFD/podman.fish") : ;;
			*)
				warn "UNEXPECTED fish startup file: $f"
				note "$f is in $DD_USER's fish conf.d and was NOT written by this script. fish runs it
    before the dd-ctl forced command, as $DD_USER. Read it before the next deploy."
				;;
		esac
	done
else
	ok "$FISH_CONFD absent (§8 creates it)"
fi

# ---------------------------------------------------------------------------------
say "== 5/13  the dd-ctl dispatch key for $DD_USER — plan: $KEY_PLAN"

mkdir -p "$DD_HOME/.ssh"
touch "$AUTHKEYS"
chown -R "$DD_USER:$DD_GROUP" "$DD_HOME/.ssh"
chmod 700 "$DD_HOME/.ssh"
chmod 600 "$AUTHKEYS"

# `restrict` is the allow-nothing baseline (no pty, no agent/port/X11 forwarding, no
# ~/.ssh/rc); `command=` replaces whatever the client asked for with dd-ctl and hands the
# client's string over in SSH_ORIGINAL_COMMAND. dd-ctl treats that as hostile — see its
# header.
#
# IT DOES NOT BYPASS $DD_USER'S LOGIN SHELL. This comment used to say that it did — "the
# forced command bypasses gavin's fish login shell entirely, which is one less thing to
# get wrong" — and that was simply false. sshd runs a forced command as
# `$SHELL -c "<command>"`, so fish starts first and reads /etc/fish/config.fish,
# ~/.config/fish/conf.d/*.fish and ~/.config/fish/config.fish on the way, including for a
# non-interactive `-c`. `restrict` does not help; it implies `no-user-rc`, which governs
# ~/.ssh/rc, an unrelated file. §4 checks those four paths' ownership and modes, dd-ctl
# re-execs itself under `env -i` so that nothing fish exported survives into podman's
# environment, and the part neither of those fixes — that $DD_USER can always write
# $DD_USER's own dotfiles — is recorded as a residual in docs/decisions.md rather than
# papered over here.
case "$KEY_PLAN" in
present)
	ok "this exact dispatch line is already present — nothing written"
	;;
keep)
	# THE CASE THIS SECTION EXISTS TO GET RIGHT. Doing nothing is the correct action, and
	# it has to be loud, because "the script ran and said ok" must not be mistaken for
	# "the key I hold is the key that is installed". The fingerprint is what settles that.
	ok "a dd-ctl dispatch key is already installed — NOT generating another"
	say "       installed dispatch key(s):"
	dispatch_fingerprints "$AUTHKEYS" | sed 's/^/            /'
	say "       to replace it: DD_CTL_ROTATE=1 sh $0"
	note "A dd-ctl dispatch key was already installed, so this run generated nothing and
    appended nothing. Its fingerprint is printed in §5 — check it against the key your
    environment block holds. If they do not match, the key you have is not the key that
    works, and DD_CTL_ROTATE=1 issues a fresh one."
	;;
install|rotate)
	# THE KEY MATERIAL. Generated here unless the operator brought their own.
	if [ "$KEY_SOURCE" = generate ]; then
		make_keydir
		# -N '' — no passphrase, because nothing interactive is there to type one at the
		# far end: the SessionStart hook writes this key into a container and ssh uses it
		# unattended. The protection is the forced command, not a passphrase.
		# The comment carries this run's timestamp, so a key found in authorized_keys or in
		# a backup can be dated to the run that issued it without consulting anything else.
		ssh-keygen -q -t ed25519 -N '' -C "dd-ctl-dispatch-$STAMP" -f "$KEYDIR/id_ddctl"
		DD_CTL_PUBKEY="$(cat "$KEYDIR/id_ddctl.pub")"
		check_pubkey "$DD_CTL_PUBKEY" "the generated public key" || exit 1
		KEY_FPR="$(ssh-keygen -lf "$KEYDIR/id_ddctl.pub")"
		ok "generated an ed25519 keypair in $KEYDIR (tmpfs, removed before this script exits)"
	else
		KEY_FPR="$(printf '%s\n' "$DD_CTL_PUBKEY" | ssh-keygen -lf - 2>/dev/null || echo 'unknown')"
	fi
	LINE="$DD_CTL_PREFIX$DD_CTL_PUBKEY"

	# BACKED UP BEFORE EITHER PATH, not just before the rewrite. An append is recoverable
	# by hand and a rewrite is not, but the backup costs one file copy and the run where
	# it is wanted is the run nobody predicted.
	backup "$AUTHKEYS"
	if [ "$KEY_PLAN" = rotate ]; then
		# THE ONE DELIBERATE EXCEPTION to append-never-rewrite. Announced before it
		# happens and in the terms that matter: the old line stops working the moment
		# this returns, so anyone still holding it is locked out of deploying.
		say "       ROTATING. The $DISPATCH_N dispatch line(s) below are being REPLACED —"
		say "       the key(s) they hold stop working now:"
		dispatch_fingerprints "$AUTHKEYS" | sed 's/^/            /'
		replace_dispatch_line "$AUTHKEYS" "$LINE" || exit 1
		chown "$DD_USER:$DD_GROUP" "$AUTHKEYS"
		chmod 600 "$AUTHKEYS"
		changed "REPLACED $DISPATCH_N dd-ctl dispatch line(s) in $AUTHKEYS with a new key ($KEY_SOURCE)"
		say "       replaced; $AUTHKEYS now holds exactly $(dispatch_count "$AUTHKEYS") dispatch line"
		note "THE PREVIOUS DISPATCH KEY NO LONGER WORKS. Anything still holding it — another
    workstation, a second environment block, a CI secret — is now locked out of
    deploying and will fail with 'Permission denied (publickey)'. The backup of the
    old $AUTHKEYS is in $BACKUP_DIR."
	else
		# APPENDED, never replacing the file: gavin's own unrestricted key lives here too,
		# and rewriting authorized_keys from a setup script is how you lock yourself out of
		# a box reachable only through a Cloudflare tunnel. No sshd restart is needed or
		# done.
		append_dispatch_line "$AUTHKEYS" "$LINE"
		chown "$DD_USER:$DD_GROUP" "$AUTHKEYS"
		chmod 600 "$AUTHKEYS"
		changed "appended a dd-ctl dispatch key to $AUTHKEYS ($KEY_SOURCE)"
		say "       appended the dispatch entry"
	fi
	# VERIFIED AFTER THE WRITE, both paths. Exactly one dispatch line, and it is ours.
	if [ "$(dispatch_count "$AUTHKEYS")" != 1 ] || ! grep -qxF "$LINE" "$AUTHKEYS"; then
		echo "refusing to continue: $AUTHKEYS does not hold exactly one dispatch line," >&2
		echo "or the line just written is not in it. Restore from $BACKUP_DIR." >&2
		exit 1
	fi
	ok "$AUTHKEYS holds exactly one dd-ctl dispatch line"
	say "       $KEY_FPR"

	if [ "$KEY_SOURCE" = generate ]; then
		# THE ONE MOMENT THE PRIVATE HALF IS EXPOSED. Printed here, once, and then the
		# directory holding it is shredded by the EXIT trap.
		#
		# NOTHING BELOW ASSIGNS THE KEY TO A VARIABLE. `base64` reads the file and writes
		# to stdout, and that is the whole path: no shell variable holds it, so it cannot
		# reach CHANGED, NOTES, the backup directory or any file this run leaves behind.
		# That is a property worth keeping — a summary that helpfully echoed "the key we
		# installed" would put it in the one place the operator is most likely to paste
		# somewhere else.
		#
		# `base64 -w0` — VERIFIED against the real busybox 1.37.0-r31 armhf binary from
		# Alpine v3.24 (`base64 [-d] [-w COL]`, `-w 0` disables wrapping) and against GNU
		# coreutils 9.4, byte-identical output. Both matter here: coreutils is on this box
		# today only because k3s pulled it in, and §12's `apk del` reclaims it, so the same
		# line has to work under either implementation. Neither emits a trailing newline
		# at -w0, hence the explicit printf.
		#
		# The base64 line itself is printed FLUSH LEFT while everything around it is
		# indented, and that is not an oversight: a leading space is copied along with the
		# line, and `base64 -d` on a value with a stray space in front of it fails in a way
		# that reads as a corrupt key rather than as a copy-paste artefact.
		say ""
		say "  ======================================================================"
		say "  THE PRIVATE HALF, PRINTED ONCE. Nothing on this box keeps a copy."
		say "  ======================================================================"
		say ""
		say "  Paste the line between the markers into your Claude Code cloud"
		say "  environment variable block, as:"
		say ""
		say "      DD_CTL_KEY_B64=<that line>"
		say ""
		say "  The SessionStart hook in the destiny-director repo decodes it to"
		say "  ~/.ssh/id_ed25519_ddctl (mode 600) at the start of every agent session."
		say ""
		say "  -----BEGIN DD_CTL_KEY_B64-----"
		base64 -w0 < "$KEYDIR/id_ddctl"
		printf '\n'
		say "  ------END DD_CTL_KEY_B64------"
		say ""
		say "  fingerprint: $KEY_FPR"
		say "  public half, as installed:"
		say "      $LINE"
		say ""
		say "  THIS IS NOW IN YOUR TERMINAL SCROLLBACK, and in anything recording this"
		say "  session — tmux history, an SSH client's log, a screen recording, a CI job's"
		say "  output. That is the one exposure this design has, and it is unavoidable:"
		say "  the key has to reach you somehow. Once it is pasted into the environment"
		say "  block, clear it: close the terminal, or clear the scrollback buffer"
		say "  (tmux: 'clear-history'). Do not paste this run's output anywhere."
		say ""
		say "  It cannot be printed again. The directory holding it is shredded when this"
		say "  script exits. If you lose it, re-run with DD_CTL_ROTATE=1 for a new one."
		say ""
		note "THE PRIVATE KEY WAS PRINTED IN §5 — scroll up for it. It is not repeated here, and
    deliberately: nothing in this summary, in $BACKUP_DIR, or in any file this run
    leaves behind holds key material. Paste it into the cloud environment block as
    DD_CTL_KEY_B64, then clear your scrollback. Note that the environment block's
    values are NOT masked, which is why only this restricted dispatch key belongs in
    it — never a key that gets a shell."
	fi
	;;
esac

# ---------------------------------------------------------------------------------
say "== 6/13  subuid/subgid ranges for $DD_USER"

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
say "== 7/13  cgroups — VERIFY ONLY"

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
say "== 8/13  XDG_RUNTIME_DIR for interactive sessions"

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
	# `-p` as well as `-m 700`, matching what dd-ctl already does. Without it, losing the
	# race against anything else that creates this directory between the test above and
	# the mkdir is a non-zero exit, and under `set -e` that aborts the whole run — after
	# §1-§7 have applied and before §9-§12 have. The verification immediately below is
	# what actually decides whether the directory is acceptable, so `-p` costs nothing:
	# a directory created by somebody else still fails the ownership and mode check.
	# shellcheck disable=SC2174  # -m applies to the deepest dir only; that is the only one
	mkdir -m 700 -p "$RUNTIME_DIR"
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

# THE VALUE, NOT THE NAME. Both checks below used to ask only whether the file mentioned
# `XDG_RUNTIME_DIR` at all. A file already setting it to something else — /run/user/1000
# is the obvious wrong answer, and the one anybody transplanting a systemd box's dotfiles
# would bring with them — was reported `ok` and left in place. That produces EXACTLY the
# symptom the comments above exist to warn about: an empty `podman ps` standing next to a
# running bot, with the setup script's own output saying the file was fine.
#
# $RUNTIME_DIR is /tmp/podman-run-<uid> and contains no regular-expression metacharacter,
# so it is safe to interpolate into these patterns; the anchor at the end is what stops
# /tmp/podman-run-1000x passing as /tmp/podman-run-1000.
#
# A WRONG VALUE IS NOT OVERWRITTEN. Appending a second, correct export would leave a file
# that contradicts itself and works only because of ordering, and this script's doctrine
# everywhere else is that it appends and never edits. It warns instead, loudly, and the
# NOTES block carries the fix.
has_runtime_dir_value() {  # has_runtime_dir_value <file>
	grep -Eq "XDG_RUNTIME_DIR[= ]\"?$RUNTIME_DIR\"?[[:space:]]*\$" "$1"
}

PROFILE="$DD_HOME/.profile"
if [ -f "$PROFILE" ] && has_runtime_dir_value "$PROFILE"; then
	ok "$PROFILE already sets XDG_RUNTIME_DIR=$RUNTIME_DIR"
elif [ -f "$PROFILE" ] && grep -q 'XDG_RUNTIME_DIR' "$PROFILE"; then
	warn "$PROFILE sets XDG_RUNTIME_DIR to something OTHER than $RUNTIME_DIR"
	note "$PROFILE sets XDG_RUNTIME_DIR to a value that is not $RUNTIME_DIR. Containers
    started by dd-ctl will be INVISIBLE to podman in an interactive sh/ash/bash session —
    an empty \`podman ps\` beside a running bot. Nothing was written; fix it by hand:
      export XDG_RUNTIME_DIR=$RUNTIME_DIR
    Current line(s):
      $(grep -n 'XDG_RUNTIME_DIR' "$PROFILE" | tr '\n' ' ')"
else
	printf 'export XDG_RUNTIME_DIR=%s\n' "$RUNTIME_DIR" >> "$PROFILE"
	chown "$DD_USER:$DD_GROUP" "$PROFILE"
	changed "added XDG_RUNTIME_DIR to $PROFILE (sh/ash/bash sessions)"
	say "       wrote $PROFILE"
fi

FISHCONF="$DD_HOME/.config/fish/conf.d/podman.fish"
if [ -f "$FISHCONF" ] && has_runtime_dir_value "$FISHCONF"; then
	ok "$FISHCONF already sets XDG_RUNTIME_DIR=$RUNTIME_DIR"
elif [ -f "$FISHCONF" ] && grep -q 'XDG_RUNTIME_DIR' "$FISHCONF"; then
	warn "$FISHCONF sets XDG_RUNTIME_DIR to something OTHER than $RUNTIME_DIR"
	note "$FISHCONF sets XDG_RUNTIME_DIR to a value that is not $RUNTIME_DIR, and fish is
    $DD_USER's login shell — so this is the file that decides what an interactive
    \`podman ps\` looks at. Nothing was written; fix it by hand:
      set -gx XDG_RUNTIME_DIR $RUNTIME_DIR
    Current line(s):
      $(grep -n 'XDG_RUNTIME_DIR' "$FISHCONF" | tr '\n' ' ')"
else
	mkdir -p "$DD_HOME/.config/fish/conf.d"
	# THE ONLY FILE THIS SCRIPT TRUNCATES, so it is the only one that needed a backup and
	# was the only one without. `cat > file` destroys what was there before cat runs —
	# CLAUDE.md's first shell trap — and reaching this branch means the file either does
	# not exist or does not mention XDG_RUNTIME_DIR at all, i.e. it holds something else
	# somebody wrote. backup() no-ops on a file that is not there.
	backup "$FISHCONF"
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
say "== 9/13  zram swap"

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
	# NO `-s 1`. It was here to mean "one compression stream, because there is one core",
	# and it does not exist: `-s` is not in the getopts string of Alpine's zram-init
	# 13.0.1-r2. The real armhf binary answers `Illegal option -s` and exits, so every
	# invocation this script and docs/host-setup.md documented would have failed — while
	# both files went on to describe zram as enabled. `-d 0 -p 100 256` is what was
	# verified to parse and reach mkswap/swapon.
	#
	# No -a (compression algorithm) either: the kernel default (lzo-rle on 6.x) is the
	# right pick on a CPU with no NEON, and hardcoding an algorithm this kernel may not
	# have compiled in turns a cushion into an error.
	if zram-init -d 0 -p 100 "$ZRAM_SIZE_MB"; then
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
say "== 10/13  /boot — VERIFY ONLY, nothing written"

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
say "== 11/13  root filesystem mount options — VERIFY ONLY"

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
say "== 12/13  docker / containerd / k3s removal"

# Docker 29.5.3 and containerd are installed and running on this box, and containerd
# alone holds ~34 MB RSS out of 475 MB. The owner has approved removing all of it: this
# deployment is rootless podman, gavin is not in the docker group and is not going to
# be, and running two container runtimes on this board is paying twice for one job.
#
# DESTRUCTIVE, so it is OPT-IN, AND IN TWO STAGES:
#
#   (no variable)                 report the installed packages only.
#   DD_REMOVE_DOCKER=1            additionally run `apk del --simulate` and STOP.
#   …=1 DD_REMOVE_DOCKER_CONFIRMED=1   actually remove.
#
# The middle stage exists because THE PACKAGE LIST BELOW IS NOT THE TRANSACTION. `apk
# del` also reclaims dependencies that nothing else in `world` needs, and on this box
# that turns ten named packages into roughly 36 — twenty-two of which appear nowhere in
# this file. One of them is `coreutils`, pulled in by k3s: losing it silently swaps GNU
# `stat` for busybox's, and §7's `stat -f -c %T /sys/fs/cgroup` then answers `UNKNOWN`
# instead of `cgroup2fs`, so a later re-run of this script warns about a cgroup setup
# that is in fact correct. `--simulate` is the only thing that shows that list before it
# happens, and a list printed after the fact is not an approval.
#
# ORDERING, and it matters:
#   1. iptables AND ca-certificates were already made explicit world members in §3.
#      `apk del` reclaims orphaned auto-installed dependencies, and both are on this box
#      today only as dependencies of docker-engine and/or k3s. Without §3 running first,
#      this section takes them with it — iptables silently breaks podman's networking
#      days later, and ca-certificates is worse: it is the trust store cloudflared
#      validates Cloudflare's edge against, so losing it cuts THE ONLY WAY INTO THIS BOX,
#      minutes after this section reports success. Naming them in §3's `apk add` is what
#      makes them unreclaimable. This ordering is load-bearing for both; an earlier
#      version of this comment justified only iptables, which reads as though
#      ca-certificates were incidental.
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

# The subpackages matter as much as the main ones: apk will not reclaim a completion or
# a -doc package that is in `world`, so one left behind keeps its parent's name alive in
# the package database and leaves `docker` on PATH as a shell completion nobody can run.
# `docker-fish-completion` is the plausible one here — $DD_USER's shell is fish.
# `docker` itself is on this list, and pkg_installed() is what makes that safe: it
# matches by NAME, not by `provides`, so a future `podman-docker` (which provides
# `docker`) is not swept up by it.
DOCKER_PKGS=''
for p in docker docker-engine docker-cli docker-cli-buildx docker-cli-compose \
         docker-openrc docker-rootless-extras docker-rootless-extras-openrc \
         docker-bash-completion docker-fish-completion docker-zsh-completion \
         docker-doc containerd containerd-openrc k3s k3s-openrc k3s-doc; do
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
#   2. EVERY running cloudflared's parent chain reaches pid 1 with no containerd,
#      dockerd, shim, conmon or runtime in it. A containerised process is reparented to a
#      shim, so this tells the two apart without trusting any name a container chose for
#      itself. Read from /proc/<pid>/status, not /proc/<pid>/stat — a comm containing
#      spaces or parentheses breaks field-numbered parsing of the latter.
#
# EVERY pid, not the first. The previous form took `pgrep -x cloudflared | head -n1`,
# i.e. the LOWEST pid, and pids are not ordered by anything that matters here — an
# OpenRC-supervised cloudflared started at boot has a low pid, so a SECOND, containerised
# cloudflared started later would never be looked at. The section would then confirm "the
# tunnel is the OpenRC service", stop docker, and cut the containerised tunnel that was
# actually carrying the session. Requiring all of them to pass turns that into a refusal.
cloudflared_parent_chain_is_clean() {  # <pid>
	_p="$1"
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
cloudflared_is_openrc_service() {
	command -v rc-service >/dev/null 2>&1 || return 1
	rc-service cloudflared status 2>/dev/null | grep -qi 'started' || return 1
	CF_PIDS="$(pgrep -x cloudflared 2>/dev/null | tr '\n' ' ')"
	[ -n "${CF_PIDS% }" ] || return 1
	for _cf in $CF_PIDS; do
		cloudflared_parent_chain_is_clean "$_cf" || return 1
	done
	return 0
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
		ok "cloudflared is the OpenRC service (pids ${CF_PIDS% }, every parent chain reaches init)"
	fi
fi

if [ -n "$DOCKER_PKGS" ] && [ -n "${DD_REMOVE_DOCKER:-}" ]; then
	if [ "${DOCKER_RUNNING:-0}" != 0 ] && [ -z "${DD_REMOVE_DOCKER_FORCE:-}" ]; then
		warn "$DOCKER_RUNNING container(s) are RUNNING — refusing"
		note "docker removal refused: containers are running. Look at what they are (listed
    above). If they are genuinely disposable, re-run with DD_REMOVE_DOCKER_FORCE=1."
	else
		# THE FULL TRANSACTION, BEFORE ANY OF IT HAPPENS — and before the services are
		# stopped, so a refusal here leaves the box exactly as it was found rather than
		# with docker stopped and its packages still installed. `--simulate` exists in the
		# apk on this box (3.0.7, verified) and prints every package the removal would
		# take, orphaned dependencies included. That is the list that matters: see the
		# section header on coreutils.
		say ""
		say "       apk del --simulate$DOCKER_PKGS"
		say "       ----------------------------------------------------------"
		# shellcheck disable=SC2086  # deliberate word splitting of our own built list
		apk del --simulate $DOCKER_PKGS 2>&1 | sed 's/^/       /' || {
			warn "apk del --simulate failed — refusing to run the real removal"
			note "docker removal refused: 'apk del --simulate' did not succeed, so the real
    transaction's contents are unknown. Nothing was stopped and nothing was removed."
			DOCKER_PKGS=''
		}
		say "       ----------------------------------------------------------"
		if [ -n "$DOCKER_PKGS" ] && [ -z "${DD_REMOVE_DOCKER_CONFIRMED:-}" ]; then
			say ""
			say "       STOPPING HERE. Read the simulation above — it is longer than the"
			say "       package list this script names, and losing coreutils is in it."
			say "       When you are satisfied:"
			say "         DD_REMOVE_DOCKER=1 DD_REMOVE_DOCKER_CONFIRMED=1 sh $0"
			note "docker removal NOT performed. 'apk del --simulate' was printed and the run
    stopped there, by design: the real transaction reclaims orphaned dependencies that
    this script does not name — coreutils among them, which changes what \`stat -f\`
    reports in §7. Nothing was stopped and nothing was removed. Re-run with
    DD_REMOVE_DOCKER_CONFIRMED=1 once you have read the list."
			DOCKER_PKGS=''
		fi
	fi
fi

if [ -n "$DOCKER_PKGS" ] && [ -n "${DD_REMOVE_DOCKER:-}" ] \
	&& [ -n "${DD_REMOVE_DOCKER_CONFIRMED:-}" ]; then
	if [ "${DOCKER_RUNNING:-0}" != 0 ] && [ -z "${DD_REMOVE_DOCKER_FORCE:-}" ]; then
		:  # already refused above
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
		say "       apk del$DOCKER_PKGS"
		# The directive attaches to the NEXT LINE, so it has to sit immediately above the
		# `apk del` and not above the `say`. It was above the `say` — which is quoted and
		# needs no exemption — leaving the one unquoted expansion in this file with no
		# directive at all, and shellcheck's SC2086 on it unsuppressed.
		# shellcheck disable=SC2086  # deliberate word splitting of our own built list
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
say "== 13/13  authorized_keys census — READ ONLY"

# WITHOUT THIS SECTION THE SCRIPT CANNOT SUBSTANTIATE ITS OWN CENTRAL CLAIM. Everything
# above is about the key this script installs: §1 counts dispatch lines, §5 installs or
# replaces one. Neither looks at the OTHER lines in the file. So a pre-existing
# unrestricted key — gavin's own, an old laptop's, one a colleague added in 2023 — is
# completely invisible to this run, and yet "the box is restricted" is what a reader
# takes away from a run that ends in `ok`. It is not restricted; ONE KEY is. The census
# is what makes the difference visible rather than assumed, and it is what §1's and §4's
# notes promise when they say "the census at the end of this run lists every key".
#
# IT ALSO MARKS THE DISPATCH LINES AND COUNTS THEM, which is the claim §5 now rests on:
# that this box has exactly one working deploy key, so the one in the operator's
# environment block is unambiguously the one that runs. Two dispatch lines is not an
# error sshd will ever report — both simply work — so the only place it can surface is
# here, at the end, in a count printed whether or not this run touched the file.
#
# READ ONLY. It prints and changes nothing, and it deliberately does not prune: removing
# somebody's key from a box reached through a tunnel is a decision, not a cleanup.
#
# THE PARSE IS FIELD-BASED, and its limits are stated rather than hidden. Options are
# whatever precedes the first field that IS a key type; the comment is whatever follows
# the base64. That reconstructs a normal line exactly, including options containing a
# quoted space. It is defeated by an option whose QUOTED VALUE contains a bare key-type
# word (`command="echo ssh-rsa"`), and by a line with no recognised key type at all —
# both of which are reported as UNPARSED and handed to a human rather than classified
# wrongly. A census that guesses is the same failure as a check that passes for the
# wrong reason.
if [ ! -f "$AUTHKEYS" ]; then
	warn "$AUTHKEYS does not exist — no keys to list"
else
	say "       $AUTHKEYS"
	say ""
	awk -v pfx="$DD_CTL_PREFIX" '
		/^[[:space:]]*($|#)/ { next }
		{
			ti = 0
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9-]+@openssh\.com)$/) { ti = i; break }
			}
			if (ti == 0) {
				printf "         line %-4d UNPARSED — no recognised key type. Read this line by hand.\n", FNR
				unparsed++
				next
			}
			opts = ""
			for (i = 1; i < ti; i++) opts = opts (i > 1 ? " " : "") $i
			cmt = ""
			for (i = ti + 2; i <= NF; i++) cmt = cmt (i > ti + 2 ? " " : "") $i
			has_cmd = (opts ~ /(^|,)command=/) ? "yes" : "NO "
			has_res = (opts ~ /(^|,)restrict(,|$)/) ? "yes" : "NO "
			is_disp = (index($0, pfx) == 1) ? "DISPATCH" : "        "
			if (has_cmd == "NO ") open_keys++
			if (is_disp == "DISPATCH") dispatch++
			printf "         line %-4d command= %s  restrict %s  %s  %-32s %s\n", \
				FNR, has_cmd, has_res, is_disp, $ti, (cmt == "" ? "(no comment)" : cmt)
			total++
		}
		END {
			printf "\n         %d key line(s); %d with no command= (a full shell); %d unparsed\n", \
				total + 0, open_keys + 0, unparsed + 0
			printf "         %d dd-ctl DISPATCH line(s) — there should be exactly one\n", \
				dispatch + 0
		}
	' "$AUTHKEYS"
	say ""
	# The count again, in the shell, because the NOTES block has to carry it and awk
	# cannot set a variable in this shell. A second pass over a handful of lines is free.
	AK_OPEN="$(awk '
		/^[[:space:]]*($|#)/ { next }
		{
			ti = 0
			for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9-]+@openssh\.com)$/) { ti = i; break }
			if (ti == 0) next
			opts = ""
			for (i = 1; i < ti; i++) opts = opts (i > 1 ? " " : "") $i
			if (opts !~ /(^|,)command=/) n++
		}
		END { print n + 0 }
	' "$AUTHKEYS")"
	if [ "$AK_OPEN" -gt 0 ]; then
		warn "$AK_OPEN key line(s) carry NO command= — each is a full shell as $DD_USER"
		note "$AK_OPEN key line(s) in $AUTHKEYS have no command= restriction. Each one is a full
    login shell as $DD_USER, who is in wheel with sudo — so the dd-ctl forced command
    restricts ONE KEY, not this box. That may be exactly right: gavin's own key belongs
    there, and removing it from a box reached only through a tunnel is how you lose the
    box. It is listed so it is a decision rather than an assumption. Nothing was pruned."
	else
		ok "every key line in $AUTHKEYS carries a command= restriction"
	fi

	# The dispatch lines, counted again in the shell for the same reason, and fingerprinted
	# so the operator can match what is installed against what they hold. Fingerprints are
	# public information — printing them here costs nothing and is the only way to answer
	# "is the key in my environment block the key on this box?" without trying a deploy.
	AK_DISPATCH="$(dispatch_count "$AUTHKEYS")"
	case "$AK_DISPATCH" in
		1)
			ok "exactly one dd-ctl dispatch line:"
			dispatch_fingerprints "$AUTHKEYS" | sed 's/^/            /' ;;
		0)
			warn "NO dd-ctl dispatch line — nothing can deploy"
			note "$AUTHKEYS holds no dd-ctl dispatch line, so no key can run dd-ctl. Re-run this
    script to install one." ;;
		*)
			warn "$AK_DISPATCH dd-ctl dispatch lines — every one of them is a working deploy key"
			dispatch_fingerprints "$AUTHKEYS" | sed 's/^/            /'
			note "$AUTHKEYS holds $AK_DISPATCH dd-ctl dispatch lines. Each is a working deploy key and
    nothing here can tell you which one is in use. DD_CTL_ROTATE=1 collapses them to a
    single new key; removing the surplus by hand is the other fix." ;;
	esac
fi

# ---------------------------------------------------------------------------------
# The summary is printed by the EXIT trap installed at the top of this file, so that a
# run which dies in §7 still reports what §1-§6 changed. All that is left to do here is
# record that the run reached the end, which is what unlocks the trap's "NEXT" block.
RUN_COMPLETED=yes
