#!/usr/bin/env bash
# pi's half of the entrypoint against temp directories, offline: bash dev/test_entrypoint_pi.sh
#
# Sources dev/pi-seed.sh, the functions entrypoint.sh calls to seed pi's agent dir and link it
# to the hub's volume, and runs each against a seed and a volume made up here, so no image,
# no Docker and no /opt are needed. Needs bash and python3. Not in the image: dev/.dockerignore
# leaves it out.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=pi-seed.sh
. "$HERE/pi-seed.sh" || { echo "FAIL: could not source $HERE/pi-seed.sh"; exit 1; }

# The entrypoint defines say before it sources pi-seed.sh; this is the same line.
say() { printf '[entrypoint] %s\n' "$*"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
check() { # check <name> <command...>
    local name="$1"; shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}
# json_true <python expression over s (the seed) and r (the result)> <seed> <result>
json_true() {
    python3 -I -c '
import json, sys
s = json.load(open(sys.argv[2])); r = json.load(open(sys.argv[3]))
sys.exit(0 if eval(sys.argv[1]) else 1)' "$@"
}

# A seed shaped like the image's /opt/pi/seed: settings with the packages `pi install`
# appended, models.json, the two extension configs, the package tree, and LAYOUT.
SEED="$T/opt/pi/seed"
mkdir -p "$SEED/extensions/pi-permission-system" "$SEED/extensions/pi-permission-classifier" \
    "$SEED/npm/node_modules/cc-safety-net"
cat > "$SEED/settings.json" <<'JSON'
{"defaultProvider": "openrouter", "defaultModel": "qwen/qwen3.8-flash",
 "enableInstallTelemetry": false, "theme": "dark",
 "packages": [{"source": "npm:pi-permission-classifier@1.0.0"},
              {"source": "npm:@gotgenes/pi-permission-system@2.0.0"},
              {"source": "npm:cc-safety-net@0.3.0"}]}
JSON
echo '{"providers": {"openrouter": {}}}' > "$SEED/models.json"
echo '{"*": "ask"}' > "$SEED/extensions/pi-permission-system/config.json"
echo '{}' > "$SEED/extensions/pi-permission-classifier/config.json"
echo 'packages_dir=npm' > "$SEED/LAYOUT"

# ── pi_seed_settings ────────────────────────────────────────────────────────
d="$T/s1"; mkdir -p "$d"
pi_seed_settings "$SEED/settings.json" "$d/settings.json" > "$T/out" 2>&1
check "an empty agent dir gets the seed's settings" json_true 's == r' "$SEED/settings.json" "$d/settings.json"
check "the seeded settings.json is mode 600" test "$(stat -c %a "$d/settings.json")" = 600
check "no temp file is left beside it" test ! -e "$d/settings.json.tmp"

d="$T/s2"; mkdir -p "$d"
echo '{"theme":"solarized","packages":[{"source":"npm:cc-safety-net"}],"defaultModel":"other"}' > "$d/settings.json"
pi_seed_settings "$SEED/settings.json" "$d/settings.json" > "$T/out" 2>&1
check "the volume's theme is kept" json_true 'r["theme"] == "solarized"' "$SEED/settings.json" "$d/settings.json"
check "the volume's defaultModel is kept" json_true 'r["defaultModel"] == "other"' "$SEED/settings.json" "$d/settings.json"
check "the package list is restored from the seed" json_true 'r["packages"] == s["packages"]' "$SEED/settings.json" "$d/settings.json"
check "a seed key the volume lacks is added" json_true 'r["enableInstallTelemetry"] is False' "$SEED/settings.json" "$d/settings.json"
check "nothing beyond the seed's keys is written" json_true 'set(r) == set(s)' "$SEED/settings.json" "$d/settings.json"

d="$T/s3"; mkdir -p "$d"
echo '{"theme": "solarized",' > "$d/settings.json"
pi_seed_settings "$SEED/settings.json" "$d/settings.json" > "$T/out" 2>&1
check "a malformed settings.json is replaced with the seed" json_true 's == r' "$SEED/settings.json" "$d/settings.json"
check "and says so in one [entrypoint] line" test "$(grep -c '^\[entrypoint\] .*not valid JSON' "$T/out")" = 1

d="$T/s4"; mkdir -p "$d"
echo '{}' > "$T/elsewhere.json"
ln -s "$T/elsewhere.json" "$d/settings.json.tmp"
pi_seed_settings "$SEED/settings.json" "$d/settings.json" > "$T/out" 2>&1
check "a link at the temp path is not written through" test "$(cat "$T/elsewhere.json")" = '{}'
check "and the settings are written anyway" json_true 's == r' "$SEED/settings.json" "$d/settings.json"

# ── pi_seed: the copies and the package link ────────────────────────────────
PI="$T/pi1"
pi_seed "$SEED" "$PI" > "$T/out" 2>&1
check "an absent models.json is copied from the seed" cmp -s "$SEED/models.json" "$PI/models.json"
check "the gate's config is copied" cmp -s "$SEED/extensions/pi-permission-system/config.json" "$PI/extensions/pi-permission-system/config.json"
check "the classifier's config is copied" cmp -s "$SEED/extensions/pi-permission-classifier/config.json" "$PI/extensions/pi-permission-classifier/config.json"
check "the package tree is a link to the seed's" test "$(readlink "$PI/npm")" = "$SEED/npm"

PI="$T/pi2"; mkdir -p "$PI/npm/node_modules/stale" "$PI/extensions/pi-permission-system"
echo '{"mine": true}' > "$PI/models.json"
echo '{"bash": "allow"}' > "$PI/extensions/pi-permission-system/config.json"
pi_seed "$SEED" "$PI" > "$T/out" 2>&1
check "a present models.json is untouched" test "$(cat "$PI/models.json")" = '{"mine": true}'
check "a present gate config is untouched" test "$(cat "$PI/extensions/pi-permission-system/config.json")" = '{"bash": "allow"}'
check "a real npm directory from an earlier start becomes the link" test "$(readlink "$PI/npm")" = "$SEED/npm"
check "and the seed's tree is intact" test -d "$SEED/npm/node_modules/cc-safety-net"

# ── the hub's volume: the skills and the extension ──────────────────────────
CS="$T/opt/claude-sessions"
mkdir -p "$CS/skills/keepalive"
echo '# keepalive' > "$CS/skills/keepalive/SKILL.md"
PI="$T/pi3"

pi_link_skill "$CS" "$PI" keepalive > "$T/out" 2>&1
check "a skill in the hub's volume is linked" test "$(readlink "$PI/skills/keepalive")" = "$CS/skills/keepalive"

mkdir -p "$PI/skills"; ln -s "$CS/skills/mail-send" "$PI/skills/mail-send"
pi_link_skill "$CS" "$PI" mail-send > "$T/out" 2>&1
check "a skill the hub's volume lacks is removed here" test ! -L "$PI/skills/mail-send"
check "and says so" grep -q '^\[entrypoint\] pi skill mail-send NOT in the hub.s volume — removed here$' "$T/out"

pi_link_extension "$CS" "$PI" > "$T/out" 2>&1
check "an extension the hub's volume lacks is not linked" test ! -L "$PI/extensions/claude-sessions.js"
check "and says pi slots will not be offloaded" grep -qx "\[entrypoint\] pi extension claude-sessions.js NOT in the hub's volume (a release before 0.10.0) — pi slots will not be offloaded" "$T/out"

mkdir -p "$CS/extensions"; echo 'export default () => {};' > "$CS/extensions/claude-sessions.js"
pi_link_extension "$CS" "$PI" > "$T/out" 2>&1
check "the extension in the hub's volume is linked" test "$(readlink "$PI/extensions/claude-sessions.js")" = "$CS/extensions/claude-sessions.js"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails FAILED"; exit 1; fi
