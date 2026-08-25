#!/usr/bin/env bash
# offload-idle-claude.sh — baked into gsrpi-dev-base at /home/dev, started in the
# background by entrypoint.sh, and safe to run by hand:
#
#   bash /home/dev/offload-idle-claude.sh --dry-run   what it would do, and why, right now
#   bash /home/dev/offload-idle-claude.sh --once      one pass, for real
#   bash /home/dev/offload-idle-claude.sh             the daemon (what the entrypoint runs)
#
# WHAT IT IS FOR. The way into these containers is `ssh -t <name> abduco -A claude claude`,
# and the point of abduco is that the session survives the link — so a claude nobody is
# talking to stays resident for days. Measured on infra-dev, 2026-08-25: ONE idle session's
# process tree held 1,146 MB RSS (the session itself 208 MB, its transient daemon 145 MB,
# and 819 MB across four bg-pty-host/bg-spare helpers). Four dev containers on a 4 GB Pi
# cannot each hold a gigabyte for a conversation that ended on Tuesday.
#
# A claude's conversation is on disk in ~/.claude/projects, and `claude --resume` picks it
# up. So the memory is the only thing lost by stopping an idle one, and it is the only
# thing worth reclaiming. This offloads; it does not close anything.
#
# THE THRESHOLD IS NOT A GUESS. A claude can schedule its own wake-up — /loop's dynamic
# mode, and ScheduleWakeup generally — and the runtime CLAMPS that delay to at most one
# hour. So an hour of silence is the longest gap a session can be *expecting*: past it,
# nothing inside that process is going to bring it back, and only a person will. The
# default is 90 minutes, which is that hour plus a margin for a wake-up that fires late
# and then thinks. Below 3600s the daemon refuses to start, because a shorter limit can
# kill a session that was going to wake itself up, and that failure looks like a claude
# that silently forgot what it was doing.
#
# WHAT IT WILL NOT DO, and each of these is a way it could be wrong:
#   - It never offloads an ATTACHED session. Somebody is at that terminal; their claude
#     going away mid-thought is worse than the RAM.
#   - It never offloads a session with WORK IN FLIGHT. A Bash tool call, a background
#     command, a subagent — each is a live descendant process, and any descendant outside
#     claude's own idle machinery counts as work. This is the check that covers the
#     ordinary case the transcript clock cannot see: a session waiting on a long build
#     writes nothing to its transcript for the whole build.
#   - It never offloads without a transcript to judge by. No conversation file, no clock,
#     no opinion — it says so and leaves the process alone.
#
# It also never runs `claude` itself, reads a conversation, or writes anything into
# ~/.claude/projects. It reads mtimes and sends signals.
set -u

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS="$CFG/projects"
LOG="${DEV_IDLE_OFFLOAD_LOG:-$HOME/.local/share/claude-offload.log}"

# The idle limit, in seconds, and the floor it may not go under. See the header.
LIMIT="${DEV_IDLE_OFFLOAD_SECONDS:-5400}"
LIMIT_FLOOR=3600

# How often the daemon looks. Cheap — it reads /proc and some mtimes — so this is about
# how promptly memory comes back, not about load.
POLL="${DEV_IDLE_POLL_SECONDS:-300}"

# Seconds between the polite signal and the impolite one. claude writes its transcript as
# it goes rather than at exit, so this is about letting it close files, not about saving
# the conversation, which is already saved.
GRACE="${DEV_IDLE_OFFLOAD_GRACE:-20}"

MODE=daemon
case "${1:-}" in
    --dry-run) MODE=dry ;;
    --once)    MODE=once ;;
    "")        MODE=daemon ;;
    *) echo "usage: $0 [--dry-run|--once]" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$LOG")"

log() {
    # Every line carries the time, because the interesting question about this log is
    # always "when did that container lose the session I left running".
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"
}
say() { printf '%s\n' "$*"; }

# ── the /proc reading ───────────────────────────────────────────────────────
# comm rather than argv: argv for these processes is long, quoted JSON in places, and the
# thing being asked is only ever "what program is this".
comm_of() { cat "/proc/$1/comm" 2>/dev/null; }
ppid_of() { awk '{print $4}' "/proc/$1/stat" 2>/dev/null; }

# Field 22 of /proc/<pid>/stat is the process's start time in clock ticks since boot. It
# is what makes a pid safe to hold on to across a wait: a pid can be reused, a pid plus a
# start time cannot. Everything that kills below re-checks it.
starttime_of() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }

rss_kb_of() { awk '/^VmRSS:/{print $2}' "/proc/$1/status" 2>/dev/null; }

# Descendants of a pid, breadth-first, using one snapshot of /proc rather than repeated
# pgrep calls — a tree that changes under a walk gives an answer that was never true.
descendants() {
    local root=$1 pid ppid
    local -a queue=("$root") found=()
    declare -A children=()
    for pid in $(cd /proc && ls -d [0-9]* 2>/dev/null); do
        ppid=$(ppid_of "$pid") || continue
        [ -n "$ppid" ] || continue
        children[$ppid]="${children[$ppid]:-} $pid"
    done
    while [ ${#queue[@]} -gt 0 ]; do
        pid=${queue[0]}; queue=("${queue[@]:1}")
        for child in ${children[$pid]:-}; do
            found+=("$child"); queue+=("$child")
        done
    done
    printf '%s\n' "${found[@]:-}"
}

# claude's own idle machinery, by comm. Anything else running under a session is work:
# a Bash tool call, a `git` a subagent started, a build. That is the signal the transcript
# clock cannot give, and the reason this script does not need to understand what claude is
# doing — only whether something is being done.
is_claude_machinery() {
    case "$1" in
        claude|claude.exe|node|abduco|"") return 0 ;;
        *) return 1 ;;
    esac
}

# ── the transcript clock ────────────────────────────────────────────────────
# claude names a project directory after the session's cwd with every character that is
# not a letter or a digit turned into a dash: /workspace -> -workspace. Measured against
# this container's own, not inferred from the docs.
slug_of() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# The NEWEST transcript in that directory, and deliberately not "this pid's transcript".
# Nothing holds the .jsonl open — checked with /proc/<pid>/fd — so there is no way to tie
# a file to a pid, and two claudes can share a cwd. Taking the newest means two sessions
# in one directory are judged by whichever spoke last: they are offloaded together or not
# at all, which errs towards keeping a live one rather than towards killing it.
newest_transcript() {
    local dir=$1
    [ -d "$dir" ] || return 1
    local newest
    newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$newest" ] || return 1
    printf '%s' "$newest"
}

# ── abduco ──────────────────────────────────────────────────────────────────
# `abduco` with no arguments lists sessions; column one is `*` when a client is attached
# and a space when none is. The name is the last tab-separated field. Measured against
# abduco 0.6, which is what the base builds.
attached_sessions() {
    abduco 2>/dev/null | awk -F'\t' '/^\*/ {print $NF}'
}

# The session process is abduco's own child: `abduco -A claude claude` forks a server that
# holds the pty and runs the command under it.
session_child_of() {
    local abduco_pid=$1 pid
    for pid in $(cd /proc && ls -d [0-9]* 2>/dev/null); do
        [ "$(ppid_of "$pid")" = "$abduco_pid" ] && { printf '%s' "$pid"; return 0; }
    done
    return 1
}

# The name abduco was given, out of its own argv: the last NUL-separated word, since every
# spelling of the command puts the session name before the program to run... except that
# it does not, so this takes the argument after -A/-a/-c/-n rather than guessing by
# position.
abduco_session_name() {
    local pid=$1
    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk '
        /^-[Aacn]$/ { want=1; next }
        want { print; exit }'
}

# ── one pass ────────────────────────────────────────────────────────────────
consider() {
    local abduco_pid=$1 now=$2 dry=$3
    local name child cwd slug transcript idle rss_kb pid tree_pids

    name=$(abduco_session_name "$abduco_pid")
    [ -n "$name" ] || name="(unnamed)"

    child=$(session_child_of "$abduco_pid") || {
        say "$name: no process under abduco — nothing to offload"; return; }

    local child_comm; child_comm=$(comm_of "$child")
    case "$child_comm" in
        claude|claude.exe) : ;;
        *) say "$name: runs '$child_comm', not claude — left alone"; return ;;
    esac

    if attached_sessions | grep -qxF "$name"; then
        say "$name: ATTACHED — somebody is there, left alone"
        return
    fi

    cwd=$(readlink "/proc/$child/cwd" 2>/dev/null) || cwd=""
    if [ -z "$cwd" ]; then
        say "$name: cannot read its cwd — left alone"; return
    fi
    slug=$(slug_of "$cwd")
    transcript=$(newest_transcript "$PROJECTS/$slug") || {
        say "$name: no transcript under $PROJECTS/$slug — no clock, left alone"; return; }

    idle=$(( now - $(stat -c %Y "$transcript") ))
    local idle_min=$(( idle / 60 ))

    if [ "$idle" -lt "$LIMIT" ]; then
        say "$name: idle ${idle_min}m of $(( LIMIT / 60 ))m — left alone"
        return
    fi

    # Work in flight beats the clock. Checked after the clock because it is the more
    # expensive test and the clock rules most passes out.
    tree_pids=$(descendants "$child")
    local busy=""
    for pid in $tree_pids; do
        local c; c=$(comm_of "$pid")
        is_claude_machinery "$c" || busy="${busy}${busy:+, }$c($pid)"
    done
    if [ -n "$busy" ]; then
        say "$name: idle ${idle_min}m BUT work is running — $busy — left alone"
        return
    fi

    rss_kb=0
    for pid in $child $tree_pids; do
        local r; r=$(rss_kb_of "$pid"); rss_kb=$(( rss_kb + ${r:-0} ))
    done
    local rss_mb=$(( rss_kb / 1024 ))
    local session_id; session_id=$(basename "$transcript" .jsonl)

    if [ "$dry" = 1 ]; then
        say "$name: WOULD OFFLOAD — idle ${idle_min}m, ${rss_mb} MB, resume: (cd $cwd && claude --resume $session_id)"
        return
    fi

    offload "$name" "$child" "$tree_pids" "$rss_mb" "$idle_min" "$cwd" "$session_id" "$abduco_pid"
}

# ── the offload itself ──────────────────────────────────────────────────────
# TERM the session, then TERM whatever of its tree outlived it, then KILL what is left,
# then take abduco itself down.
#
# THAT LAST STEP IS NOT TIDYING, and leaving it out was this script's first real bug,
# found by running it rather than by reading it. abduco outlives the command it ran: the
# session stays in `abduco`'s listing with a `+`, its socket keeps the name (the finished
# state is the socket's execute bit), and `abduco -A claude claude` — the documented way
# into every one of these containers — ATTACHES TO THAT CORPSE instead of starting a new
# claude. You would ssh in, get a dead screen, and have no reason to suspect the reason.
# So the session that was offloaded is closed, and only that one: a finished session
# somebody else left is theirs to look at, and abduco keeps it for exactly that.
#
# The pid list is taken BEFORE anything is signalled: children reparent to init the moment
# their parent dies, so a tree walked afterwards is a different tree. Every signal
# re-checks the start time first, so a pid recycled during the grace window is not a pid
# this script will shoot.
offload() {
    local name=$1 child=$2 tree=$3 rss_mb=$4 idle_min=$5 cwd=$6 session_id=$7 abduco_pid=$8
    local pid start

    declare -A starts=()
    for pid in $child $tree $abduco_pid; do
        start=$(starttime_of "$pid") && [ -n "$start" ] && starts[$pid]=$start
    done

    sig() {
        local signal=$1 p=$2
        [ -n "${starts[$p]:-}" ] || return 0
        [ "$(starttime_of "$p")" = "${starts[$p]}" ] || return 0   # pid reused; not ours
        kill "-$signal" "$p" 2>/dev/null || true
    }

    sig TERM "$child"
    local waited=0
    while [ "$waited" -lt "$GRACE" ] && kill -0 "$child" 2>/dev/null; do
        sleep 1; waited=$(( waited + 1 ))
    done

    for pid in $tree; do sig TERM "$pid"; done
    sleep 2
    local survivors=0
    for pid in $child $tree; do
        if [ -n "${starts[$pid]:-}" ] && kill -0 "$pid" 2>/dev/null \
           && [ "$(starttime_of "$pid")" = "${starts[$pid]}" ]; then
            sig KILL "$pid"; survivors=$(( survivors + 1 ))
        fi
    done

    # abduco last, once its command is gone, so the name is free and the next
    # `abduco -A claude claude` creates rather than attaches.
    sig TERM "$abduco_pid"
    sleep 1
    if kill -0 "$abduco_pid" 2>/dev/null \
       && [ "$(starttime_of "$abduco_pid")" = "${starts[$abduco_pid]:-}" ]; then
        sig KILL "$abduco_pid"
    fi

    log "offloaded '$name' after ${idle_min}m idle — freed ~${rss_mb} MB${survivors:+ (${survivors} needed SIGKILL)}"
    log "    resume it with:  cd $cwd && claude --resume $session_id"
    say "$name: OFFLOADED — ${idle_min}m idle, ~${rss_mb} MB freed. Resume: (cd $cwd && claude --resume $session_id)"
}

pass() {
    local dry=$1 now abduco_pid found=0
    now=$(date +%s)
    for abduco_pid in $(pgrep -x -u "$(id -u)" abduco 2>/dev/null); do
        found=1
        consider "$abduco_pid" "$now" "$dry"
    done
    [ "$found" = 1 ] || say "no abduco sessions"
}

# ── modes ───────────────────────────────────────────────────────────────────
if [ "$LIMIT" -lt "$LIMIT_FLOOR" ]; then
    # Refused rather than clamped: a number somebody typed and a number this script chose
    # instead should never look the same from outside. See the header for why an hour is
    # the floor.
    say "DEV_IDLE_OFFLOAD_SECONDS=$LIMIT is below the ${LIMIT_FLOOR}s floor — refusing."
    say "    A claude can schedule its own wake-up up to an hour out; a limit under that"
    say "    offloads sessions that were coming back."
    exit 2
fi

case "$MODE" in
    dry)  pass 1 ;;
    once) pass 0 ;;
    daemon)
        log "watching: offload after $(( LIMIT / 60 ))m idle, checking every $(( POLL / 60 ))m"
        while :; do
            sleep "$POLL"
            pass 0 >/dev/null 2>&1
        done
        ;;
esac
