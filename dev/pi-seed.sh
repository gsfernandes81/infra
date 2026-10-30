# shellcheck shell=bash
# pi's agent dir, seeded and linked at every start. Sourced by entrypoint.sh, never run:
# shell functions only, nothing at the top level, so dev/test_entrypoint_pi.sh can source the
# same file and call each function against a temp directory. They print through the caller's
# `say`, which entrypoint.sh defines before it sources this.
#
# WHY AT EVERY START: pi's agent dir (PI_CODING_AGENT_DIR) is on the ~/.local/share volume, and
# a volume hides whatever the image put at that path. So the image bakes its config into
# /opt/pi/seed (root-owned, read-only to dev: Dockerfile.base says why) and these restore it.
# What pi writes to is COPIED, never linked, because a link would point a write at a
# read-only file. What pi only reads (the package tree, the policy, the hub's skills and
# extension) is LINKED, so a new image or a new hub release is live at the next start.
#
# Every link is made with `rm` first, never `ln -f` onto whatever is there: a real directory
# left by an earlier start would have the link made INSIDE it, and `rm -rf` on a symlink
# removes the link, never what it points at.

# pi_seed_settings <seed.json> <target.json>
# Three seed keys win every time. `packages` is the list of what the image installed, and a
# package the volume's list names but the image lacks, or the reverse, is a pi that will not
# start the way the image meant (the gate is one of them). `powerline` is the footer's, where
# infra turns the welcome card off: the card is a prompt at every start, and a fresh slot reads
# as waiting on the owner while it is up. `defaultProjectTrust` is `never` because a trusted
# repo's .pi/ could carry a gate config that loosens infra's, so a volume that says otherwise is
# put back. (A decision saved with /trust, in trust.json, still beats the default; the gate
# denies writes under the agent dir wherever it can resolve the path, and judges the rest.) Every
# other seed key is written only where the volume has none, so the owner's theme or model
# survives a restart. A target that is not a JSON object is replaced with the seed and said,
# as one line. Written to a temp file opened
# exclusively and renamed over the target, at 0600, so neither a crash nor a link at either
# path is written through.
pi_seed_settings() {
    local msg
    if msg="$(python3 -I - "$1" "$2" <<'PY'
import json, os, sys

seed_path, path = sys.argv[1], sys.argv[2]
with open(seed_path) as f:
    seed = json.load(f)

note = None
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError
except FileNotFoundError:
    cfg, note = {}, "seeded from the image"
except (ValueError, OSError):
    cfg, note = {}, "was not valid JSON — replaced with the image's seed"

SEED_WINS = {
    "packages": "package list restored",
    "powerline": "powerline restored",
    "defaultProjectTrust": "defaultProjectTrust restored",
}
changed = []
for key, value in seed.items():
    if key in SEED_WINS:
        if cfg.get(key) != value:
            if key in cfg:
                changed.append(SEED_WINS[key])
            else:
                changed.append(key)
            cfg[key] = value
    elif key not in cfg:
        cfg[key] = value
        changed.append(key)

if note or changed:
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
print(note or ("updated from the image: " + ", ".join(changed) if changed else "current"))
PY
)"; then
        say "pi settings.json: $msg"
    else
        say "pi settings.json: could not seed it from $1 — pi starts with what the volume holds"
    fi
}

# pi_copy <seed file> <target file>
# Through a temp file and a rename, the temp path cleared first, as the .claude.json block in
# entrypoint.sh does and for its reason: a redirection follows a link. `rm -rf`, because a
# directory at the temp path would have cp write into it and the rename fail.
pi_copy() {
    mkdir -p "$(dirname "$2")" && rm -rf "$2.tmp" && cp "$1" "$2.tmp" \
        && chmod 600 "$2.tmp" && mv -fT "$2.tmp" "$2"
}

# pi_copy_absent <seed file> <target file> <name for the log>
pi_copy_absent() {
    if [ -e "$2" ]; then
        say "pi $3: the volume's own, kept"
    elif rm -f "$2" && pi_copy "$1" "$2"; then
        say "pi $3: copied from the image"
    else
        say "pi $3: could not copy it from $1"
    fi
}

# pi_copy_seed <seed file> <target file> <name for the log>
# The seed's copy wins: whatever the volume holds at <target> is replaced when it differs,
# a directory or a link included, so an edit made during a session lasts until the next start.
pi_copy_seed() {
    if [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"; then
        say "pi $3: current"
    elif rm -rf "$2" && pi_copy "$1" "$2"; then
        say "pi $3: restored from the image"
    else
        say "pi $3: could not restore it from $1 — the gate runs on what the volume holds"
    fi
}

# pi_link <source> <link>: make <link> point at <source>, whatever was there.
pi_link() {
    if [ -e "$2" ] && [ ! -L "$2" ]; then rm -rf "$2"; fi
    [ "$(readlink "$2" 2>/dev/null)" = "$1" ] && return 0
    mkdir -p "$(dirname "$2")" && rm -f "$2" && ln -s "$1" "$2"
}

# pi_seed <seed dir> <agent dir>
# The settings merge, then models.json copied where absent, since the owner may edit it on the
# volume and a deleted one comes back at the next start. The gate's config and the classifier's
# are infra's policy, not the owner's settings, so the seed's copy replaces the volume's at every
# start: an agent, or /permission-model, may write either during a session, and a policy that
# drifted on one volume would be a policy nobody reviewed. To change them, change the seed files
# in dev/ and rebuild. Any other extension file is copied where absent. Then the package tree,
# linked where LAYOUT says pi looks for it.
pi_seed() {
    local seed="$1" dir="$2" rel pkgs
    mkdir -p "$dir" || { say "pi: could not create $dir — its agent dir is not seeded"; return 1; }
    pi_seed_settings "$seed/settings.json" "$dir/settings.json"
    pi_copy_absent "$seed/models.json" "$dir/models.json" models.json
    while IFS= read -r rel; do
        case "$rel" in
            extensions/pi-permission-system/config.json | extensions/pi-permission-classifier/config.json)
                pi_copy_seed "$seed/$rel" "$dir/$rel" "$rel" ;;
            *) pi_copy_absent "$seed/$rel" "$dir/$rel" "$rel" ;;
        esac
    done < <(cd "$seed" && find extensions -type f | sort)
    # LAYOUT is the build's word on where `pi install` put the packages (pi 1.4.0: <agent
    # dir>/npm). A single plain name or nothing, because this name goes to `rm -rf` in pi_link.
    pkgs="$(sed -n 's/^packages_dir=//p' "$seed/LAYOUT" 2>/dev/null)"
    case "$pkgs" in
        '' | . | .. | */* | *[!A-Za-z0-9._-]*)
            say "pi packages: $seed/LAYOUT names no packages_dir — pi starts without its packages" ;;
        *)
            if pi_link "$seed/$pkgs" "$dir/$pkgs"; then
                say "pi packages: $dir/$pkgs -> $seed/$pkgs"
            else
                say "pi packages: could not link $dir/$pkgs — pi starts without its packages"
            fi ;;
    esac
}

# pi_link_skill <hub volume> <agent dir> <skill>
# The twin of the Claude Code skill links in entrypoint.sh, called from the same loop and with
# the same rule: linked while the hub's volume carries the skill, removed here when it does not
# (a rollback), because a stale skill tells pi to run a command that is not there.
pi_link_skill() {
    local src="$1/skills/$3" link="$2/skills/$3"
    if [ -s "$src/SKILL.md" ]; then
        if pi_link "$src" "$link"; then
            say "pi skill $3: $link -> $src"
        else
            say "pi skill $3: could not link $link"
        fi
    else
        rm -rf "$link"
        say "pi skill $3 NOT in the hub's volume — removed here"
    fi
}

# pi_link_extension <hub volume> <agent dir>
# claude-sessions.js is pi's hook into claude-sessions, which `claude-sessions install` writes
# beside the skills from 0.10.0; a pi slot without it is never offloaded. A link left by a later
# release is removed when the volume rolls back past it.
pi_link_extension() {
    local src="$1/extensions/claude-sessions.js" link="$2/extensions/claude-sessions.js"
    if [ -s "$src" ]; then
        if pi_link "$src" "$link"; then
            say "pi extension claude-sessions.js: $link -> $src"
        else
            say "pi extension claude-sessions.js: could not link $link"
        fi
    else
        rm -f "$link"
        say "pi extension claude-sessions.js NOT in the hub's volume (a release before 0.10.0) — pi slots will not be offloaded"
    fi
}
