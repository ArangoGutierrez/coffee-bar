#!/bin/bash
# t8-crashed-agent-hold-release.sh — acceptance for v0.1 step 7, "a crashed
# agent does not pin the machine forever" (issue #8).
#
# WHAT ISSUE #8 SAYS, AND WHAT CHANGED. The issue argues the step cannot be
# automated because "the app exposes no programmatic state" — `defaults read`
# fails and `/state`, `/sessions`, `/health` all answer 400. That was true when
# it was written. Issue #9 then shipped a read route, and this harness is what
# it made possible:
#
#     curl --fail-with-body --unix-socket <socket> \
#          -H 'Content-Length: 0' http://localhost/status
#
# `Content-Length: 0` is REQUIRED and is not decoration. `HTTPRequestFramer`
# demands a declared length on every request because the read route is framed by
# the same framer as the hook channel rather than by a lenient second one, so a
# bare `curl` GET is refused with 400 like any other unframeable request. See
# `UnixSocketIngestListener.readEndpoint`. Do not "fix" that by making a bare
# curl work; frame the request.
#
# THE OBSERVER PROBLEM DISSOLVES, and that is why a shell script can do this.
# #8's deeper objection was that an agent must make tool calls to observe, and
# every tool call fires hook events that keep the session alive — the observer
# was the confound. The two channels are separate at the routing line:
# `readEndpoint` resolves to no `AgentTool`, "so a read can never fall through
# into the path that mints sessions". Polling `/status` therefore creates
# nothing. Check 1 below MEASURES that rather than trusting it.
#
# WHAT "CRASHED" MEANS HERE. Nothing is killed. The harness posts hook events
# for synthetic sessions and then STOPS POSTING, which is byte-for-byte what the
# app sees when an agent dies: the observed hook set carries no reliable
# session-end signal, so a crash IS silence. `StalePolicy`'s comment says it —
# the timeout "is the only thing that retires it". Simulating the crash by
# killing something would test the killing, not the timeout.
#
# WHY SEVERAL SESSIONS, STAGGERED. `/status` reports COUNTS, not sessions, and
# `grep -rn 'Logger(|os_log' Sources/` finds nothing, so there is no per-session
# observable anywhere: the aggregate count is all there is. On a machine with
# real agents running, a count that falls by one is ambiguous — a real session
# going `.awaitingInput` looks identical. Injecting N sessions `--stagger`
# seconds apart makes the expected signature N separate falls spaced by exactly
# that interval, each one `workingTimeout` after its own last post. Noise does
# not reproduce that, and it measures the timeout N times in one run.
#
# ON A QUIET MACHINE the same defaults give the unambiguous result: the count
# rises from 0, falls back to 0, and `holding` goes false. Nothing needs
# changing to run it that way — that is the half this file exists to make
# runnable unattended.
#
# WHAT IT DELIBERATELY DOES NOT DO. It never quits, kills, kickstarts or
# reinstalls the app, and it holds no assertion of its own. Every session it
# creates retires by itself on the app's own timeout. The payloads name a
# synthetic path under /tmp and a synthetic tool, so nothing it posts can be
# mistaken for a real user's work.
#
# EXIT CODES:
#   0  FULL     — the count returned to zero AND the hold was released.
#   2  usage / preflight error (no socket, no source to derive from).
#   3  FAIL     — a check failed, or nothing was ever retired.
#   4  PARTIAL  — the retirement was measured, the release was not observable
#                 because other sessions kept the count above zero. This is NOT
#                 a pass: issue #8's acceptance is the RELEASE.
set -uo pipefail

# ── Pure helpers. Sourced and checked by the sibling _test.sh ────────────────

# Reads one top-level key out of a compact JSON object.
#
# The read route encodes with `.sortedKeys` and no pretty printing, so the
# answer is one flat line and this needs no JSON parser — which matters,
# because the harness must run on a machine with nothing installed on it.
#
# The `[,{]` anchor says TOP LEVEL, and it is belt-and-braces rather than a
# defence — measured, not assumed. The obvious hazard is `version` matching
# inside `schemaVersion`, and it cannot happen: the pattern needs a quote
# immediately before the name, and `schemaVersion` has an `a` there. Nor can a
# string VALUE carry a lookalike, because JSON escapes the quote that would
# open it — `"x\"working\":99"` does not match `"working":` at all, since a
# backslash sits where the pattern wants a quote. Removing the anchor leaves
# every check in the sibling test green. It stays because it states the intent
# for free; do not write a test claiming it catches something.
#
# An absent key returns 3 and prints nothing. Returning the empty string would
# be worse than useless: every later `-gt` comparison would silently compare
# nothing, and the harness would poll for half an hour observing "no change".
json_field() {
    local json=$1 key=$2 raw
    raw=$(printf '%s' "$json" | grep -oE "[,{]\"$key\":(\"[^\"]*\"|[^,}]*)" | head -1)
    [ -n "$raw" ] || return 3
    raw=${raw#*:}
    raw=${raw#\"}
    raw=${raw%\"}
    printf '%s\n' "$raw"
}

# Reads a timeout constant out of `StalePolicy.swift`.
#
# DERIVED, never a literal. The whole result of this harness is an elapsed time
# compared against a timeout, and a timeout copied into this file would go stale
# the day somebody tunes it — the run would then report a healthy app as broken,
# or worse, a broken one as healthy.
#
# The underscore strip is load-bearing: `blockedTimeout: 14_400` is a Swift
# underscore-separated literal, and a parse that stops at the underscore reports
# a four-hour timeout as fourteen seconds.
derive_timeout() {
    local file=$1 name=$2 raw
    raw=$(grep -oE "$name: [0-9_]+" "$file" | head -1)
    [ -n "$raw" ] || return 3
    raw=${raw##*: }
    printf '%s\n' "${raw//_/}"
}

# Prints every point in the timeline where a count CHANGED, and names what the
# change was: `<elapsed> working <a>-><b> attention <c>-><d> <joined|moved|left>`.
#
# WATCHING `working` ALONE IS NOT ENOUGH, and the 2026-08-18 run is what
# established it. That count falls for two unrelated reasons and they are
# indistinguishable in it:
#
#   - a session was RETIRED by the stale timeout, which is what this measures;
#   - a real session blocked on its human and moved to `.awaitingInput`, which
#     leaves the active set for a reason that has nothing to do with staleness.
#
# `attention` is where the second one lands and the first one does not, so
# `working + attention` separates them: `left` means that sum FELL, which is a
# session leaving the tracked set altogether, and `moved` means it held while
# the session changed state. On a quiet machine every line is ours; on a busy
# one, `left` is the only kind of line worth matching against a prediction.
#
# A reader watching `working` alone is also blind outright to a session leaving
# from an attention state, which moves no `working` count at all.
#
# Changes only. A plateau of forty identical polls says nothing and printing it
# would bury the three lines that matter.
transitions() {
    awk -F, 'NR > 1 {
        sum = $4 + $5
        if (seen && ($4 != pw || $5 != pa)) {
            delta = sum - psum
            label = (delta > 0) ? "joined" : ((delta < 0) ? "left" : "moved")
            printf "%s working %d->%d attention %d->%d %s\n", $3, pw, $4, pa, $5, label
        }
        pw = $4; pa = $5; psum = sum; seen = 1
    }' "$1"
}

# Reads the two counts either side of a revive post and says what they mean.
#
# THE PROBE THAT SETTLES WHAT COUNTING CANNOT. Re-posting a tool event for an
# already-injected session id raises `working` only if that session had LEFT the
# active set; one still `.working` is advanced to `.working` again and the count
# does not move. So the delta answers "was this session retired" directly,
# without needing to have caught the moment it happened.
#
# It is the answer to the one case the 2026-08-18 run could not attribute: a
# fall of one and two concurrent joins land in the same poll and net to a rise,
# so no `left` line appears for a session that did retire.
#
# `inconclusive` is not padding. A real session moving in the same instant is
# exactly what this cannot see through, and a delta that is neither 0 nor 1 has
# to say so rather than pick a side. A delta of 0 is the weaker of the two
# readings for the same reason: it is also what a revive plus a simultaneous
# departure looks like.
probe_verdict() {
    local before=$1 after=$2
    if [ "$after" -eq $((before + 1)) ]; then
        printf 'retired\n'
    elif [ "$after" -eq "$before" ]; then
        printf 'active\n'
    else
        printf 'inconclusive\n'
    fi
}

# FULL only when the count reached zero AND the hold was released.
#
# Both, never either. A count at zero with the assertion still held is the
# failure this acceptance step exists to catch, so it reads PARTIAL — and the
# caller exits non-zero on it.
verdict() {
    local reached_zero=$1 released=$2 observed_drop=$3
    if [ "$reached_zero" = yes ] && [ "$released" = yes ]; then
        printf 'FULL\n'
    elif [ "$observed_drop" = yes ]; then
        printf 'PARTIAL\n'
    else
        printf 'FAIL\n'
    fi
}

# ── Measurement ──────────────────────────────────────────────────────────────

SESSIONS=3
STAGGER=60
POLL=15
MAX_WAIT=1800
CONTROL_POLLS=20
PROBE=no
OUT=""
SOCKET=""

usage() {
    cat <<'USAGE'
usage: t8-crashed-agent-hold-release.sh [options]

  --sessions N        synthetic sessions to inject (default 3)
  --stagger S         seconds between injections (default 60)
  --poll P            seconds between /status reads (default 15)
  --max-wait W        seconds to observe after the last post (default 1800)
  --control-polls C   reads in the observer-effect control burst (default 20)
  --probe-retirement  after observing, re-post to each synthetic session to
                      settle whether it was retired. REVIVES them, so they
                      hold for one more timeout. For busy machines, where a
                      fall can be masked by concurrent joins.
  --out DIR           where the timeline goes (default under $TMPDIR)
  --socket PATH       ingest socket (default: derived from the source)

Run it on a QUIET machine — no agent sessions of your own — for the full
result. On a busy one it still measures the retirement and says so.
USAGE
}

fail() { printf 'FAIL: %s\n' "$*"; exit 3; }
note() { printf '%s\n' "$*"; }

main() {
    while [ $# -gt 0 ]; do
        case $1 in
            --sessions) SESSIONS=$2; shift 2 ;;
            --stagger) STAGGER=$2; shift 2 ;;
            --poll) POLL=$2; shift 2 ;;
            --max-wait) MAX_WAIT=$2; shift 2 ;;
            --control-polls) CONTROL_POLLS=$2; shift 2 ;;
            --probe-retirement) PROBE=yes; shift ;;
            --out) OUT=$2; shift 2 ;;
            --socket) SOCKET=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage; exit 2 ;;
        esac
    done

    local repo_root
    repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 2

    local policy="$repo_root/Sources/CoffeeBarCore/StalePolicy.swift"
    local listener="$repo_root/Sources/CoffeeBarIngest/IngestListener.swift"
    local agent="$repo_root/Sources/CoffeeBarCore/AgentSession.swift"
    for f in "$policy" "$listener" "$agent"; do
        [ -f "$f" ] || { echo "usage: run from the repo; $f not found"; exit 2; }
    done

    local working_timeout blocked_timeout read_endpoint event_endpoint sock_rel
    working_timeout=$(derive_timeout "$policy" workingTimeout) \
        || { echo "could not derive workingTimeout from $policy"; exit 2; }
    blocked_timeout=$(derive_timeout "$policy" blockedTimeout) \
        || { echo "could not derive blockedTimeout from $policy"; exit 2; }

    # Endpoints and the socket path are derived for the same reason the timeouts
    # are: a literal here would keep answering after the app moved.
    read_endpoint=$(grep -oE 'readEndpoint = "[^"]+"' "$listener" | head -1)
    read_endpoint=${read_endpoint#*\"}; read_endpoint=${read_endpoint%\"}
    [ -n "$read_endpoint" ] || { echo "could not derive readEndpoint"; exit 2; }

    event_endpoint=$(grep -oE 'case \.claudeCode: return "[^"]+"' "$agent" | head -1)
    event_endpoint=${event_endpoint#*\"}; event_endpoint=${event_endpoint%\"}
    [ -n "$event_endpoint" ] || { echo "could not derive the ingest endpoint"; exit 2; }

    if [ -z "$SOCKET" ]; then
        sock_rel=$(grep -oE 'Library/Application Support/[A-Za-z0-9./-]+\.sock' \
            "$listener" | head -1)
        [ -n "$sock_rel" ] || { echo "could not derive the socket path"; exit 2; }
        SOCKET="$HOME/$sock_rel"
    fi

    [ -S "$SOCKET" ] || { echo "no socket at $SOCKET; is coffee-bar running?"; exit 2; }

    local started; started=$(date +%s)
    [ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/t8-crashed-agent-$started-$$"
    mkdir -p "$OUT" || exit 2
    local csv="$OUT/timeline.csv"
    printf 'iso,epoch,elapsed,working,attention,holding\n' > "$csv"

    note "coffee-bar acceptance step 7 — crashed agent releases the hold (#8)"
    note "socket          $SOCKET"
    note "read endpoint   $read_endpoint"
    note "hook endpoint   $event_endpoint"
    note "workingTimeout  ${working_timeout}s   (derived from StalePolicy.swift)"
    note "blockedTimeout  ${blocked_timeout}s   (derived from StalePolicy.swift)"
    note "timeline        $csv"
    note ""

    # ── 0. Preflight ────────────────────────────────────────────────────────
    local status
    status=$(read_status) || fail "the read route did not answer 200 at $SOCKET"
    local version; version=$(json_field "$status" version) \
        || fail "the answer carried no version: $status"
    note "PASS preflight: $read_endpoint answers, version $version"
    note "     $status"

    # ── 1. CONTROL: reading creates no session ──────────────────────────────
    # The claim under test is that a read mints nothing. If it did mint, each
    # read would mint one, so C reads would raise the count by about C. Real
    # agents on a busy machine move it by one or two over the few seconds this
    # burst takes, so half the poll count discriminates the two outcomes
    # cleanly and does not depend on the machine being quiet.
    local first_working peak_working
    first_working=$(json_field "$status" working) || fail "no working count in $status"
    peak_working=$first_working
    local i
    for ((i = 0; i < CONTROL_POLLS; i++)); do
        status=$(read_status) || fail "read $i of the control burst failed"
        local w; w=$(json_field "$status" working) || fail "no working count in $status"
        [ "$w" -gt "$peak_working" ] && peak_working=$w
    done
    local growth=$((peak_working - first_working))
    local allowed=$((CONTROL_POLLS / 2))
    [ "$growth" -lt "$allowed" ] \
        || fail "working grew by $growth over $CONTROL_POLLS reads (limit $allowed): a read is minting sessions"
    note "PASS control: $CONTROL_POLLS reads of $read_endpoint grew working by $growth (< $allowed)"

    # ── 2. Baseline ─────────────────────────────────────────────────────────
    local baseline; baseline=$(json_field "$status" working) || fail "no working count"
    if [ "$baseline" -eq 0 ]; then
        note "PASS baseline: working=0 — quiet machine, the full result is reachable"
    else
        note "NOTE baseline: working=$baseline — other agent sessions are live on this"
        note "     machine, so the count cannot reach zero and the RELEASE half of"
        note "     issue #8 is not observable in this run. The retirement half is."
    fi

    # ── 3. Inject, then fall silent ─────────────────────────────────────────
    # A crash is silence. Nothing is killed here; the harness simply stops.
    local -a last_post=()
    local id
    for ((i = 1; i <= SESSIONS; i++)); do
        id="coffeebar-acceptance-t8-$started-$$-$i"
        local before after
        before=$(json_field "$(read_status)" working) || fail "no working count before injection $i"
        post_event "$id" SessionStart || fail "posting SessionStart for $id failed"
        post_event "$id" PreToolUse   || fail "posting PreToolUse for $id failed"
        post_event "$id" PostToolUse  || fail "posting PostToolUse for $id failed"
        last_post+=("$(date +%s)")
        after=$(json_field "$(read_status)" working) || fail "no working count after injection $i"
        [ "$after" -gt "$before" ] \
            || fail "working did not rise on injection $i ($before -> $after); the event was not ingested"
        note "PASS inject $i/$SESSIONS: $id — working $before -> $after"
        [ "$i" -lt "$SESSIONS" ] && /bin/sleep "$STAGGER"
    done

    local silence_from=${last_post[$((SESSIONS - 1))]}
    note ""
    note "SILENT from $(date -r "$silence_from" '+%H:%M:%S') — nothing else is posted."
    note "Expected retirements, one per session, at lastEvent + ${working_timeout}s:"
    for ((i = 0; i < SESSIONS; i++)); do
        note "  session $((i + 1)): $(date -r $((last_post[i] + working_timeout)) '+%H:%M:%S')"
    done
    note ""

    # ── 4. Observe ──────────────────────────────────────────────────────────
    # Polls to the budget even after the count has fallen, rather than stopping
    # at the first drop. On a busy machine a drop is ambiguous, and the evidence
    # that a fall was OURS is the spacing of the whole set — which only exists
    # if the observation outlives the last of them.
    local peak; peak=$(json_field "$(read_status)" working) || fail "no working count"
    local observed_drop=no reached_zero=no released=no
    local zero_at="" release_at="" min_seen=$peak
    local elapsed
    while :; do
        elapsed=$(( $(date +%s) - silence_from ))
        [ "$elapsed" -ge "$MAX_WAIT" ] && break
        status=$(read_status) || { /bin/sleep "$POLL"; continue; }
        local w a h
        w=$(json_field "$status" working)   || fail "no working count in $status"
        a=$(json_field "$status" attention) || fail "no attention count in $status"
        h=$(json_field "$status" holding)   || fail "no holding flag in $status"
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$(date '+%H:%M:%S')" "$(date +%s)" "$elapsed" "$w" "$a" "$h" >> "$csv"

        [ "$w" -lt "$min_seen" ] && { min_seen=$w; observed_drop=yes; }
        if [ "$w" -eq 0 ] && [ "$reached_zero" = no ]; then
            reached_zero=yes; zero_at=$elapsed
            note "     working reached 0 at +${elapsed}s"
        fi
        if [ "$h" = false ] && [ "$released" = no ]; then
            released=yes; release_at=$elapsed
            note "     holding went false at +${elapsed}s"
        fi
        # Both halves are in hand; nothing further can be learned by waiting.
        [ "$reached_zero" = yes ] && [ "$released" = yes ] && break
        /bin/sleep "$POLL"
    done

    # ── 5. Report ───────────────────────────────────────────────────────────
    note ""
    note "── timeline transitions (elapsed since the last post) ──"
    transitions "$csv"
    note "── end ──"
    note ""

    # ── 5b. Post-hoc probe, opt in ──────────────────────────────────────────
    # AFTER the observation, never during it: a revive puts the session back in
    # the active set and starts a fresh timeout, which would corrupt the very
    # measurement above.
    local probe_all_retired=yes
    if [ "$PROBE" = yes ]; then
        note "── retirement probe (revives each synthetic session) ──"
        local b a v
        for ((i = 1; i <= SESSIONS; i++)); do
            id="coffeebar-acceptance-t8-$started-$$-$i"
            b=$(json_field "$(read_status)" working) || fail "no count before probing $i"
            post_event "$id" PreToolUse || fail "probe post for $id failed"
            a=$(json_field "$(read_status)" working) || fail "no count after probing $i"
            v=$(probe_verdict "$b" "$a")
            note "  session $i: working $b -> $a  =>  $v"
            [ "$v" = active ] && probe_all_retired=no
        done
        note "  Those sessions are live again and retire once more on the same"
        note "  ${working_timeout}s timeout. Nothing further is posted to them."
        note ""
    fi
    note "baseline working      $baseline"
    note "peak working          $peak"
    note "lowest working seen   $min_seen"
    note "observed for          ${elapsed}s of a ${MAX_WAIT}s budget"
    [ -n "$zero_at" ] && note "working reached 0 at  +${zero_at}s after the last post"
    [ -n "$release_at" ] && note "hold released at      +${release_at}s after the last post"

    if [ "$probe_all_retired" = no ]; then
        note "FAIL: a synthetic session was STILL IN THE ACTIVE SET after"
        note "${elapsed}s of silence, and workingTimeout is ${working_timeout}s."
        note "A crashed agent is pinning this machine."
        exit 3
    fi

    local result; result=$(verdict "$reached_zero" "$released" "$observed_drop")
    note ""
    case $result in
        FULL)
            note "FULL: the count returned to zero and the hold was released."
            note "Acceptance step 7 is MET. Elapsed to release: ${release_at}s"
            note "(workingTimeout is ${working_timeout}s; the excess is the 30 s refresh"
            note " tick plus whatever App Nap added to it)."
            exit 0 ;;
        PARTIAL)
            note "PARTIAL: sessions were retired — see the falls above — but the"
            note "assertion was NOT observed to release, because other sessions kept"
            note "the count above zero. Issue #8's acceptance is the RELEASE, so this"
            note "does not meet it. Re-run on a quiet machine, unchanged."
            exit 4 ;;
        *)
            note "FAIL: nothing was retired within ${MAX_WAIT}s of silence, and"
            note "workingTimeout is ${working_timeout}s. A crashed agent is pinning"
            note "this machine."
            exit 3 ;;
    esac
}

# One framed read. `Content-Length: 0` is what makes it framable at all.
read_status() {
    curl -sS --fail-with-body --max-time 5 --unix-socket "$SOCKET" \
        -H 'Content-Length: 0' "http://localhost$read_endpoint"
}

# One hook post, shaped exactly as `HookSnippet.command(for:)` shapes it.
#
# `-o /dev/null` and `--fail-with-body` travel together there and travel
# together here, for the reason that function gives: `--fail-with-body` prints
# the server's error body to standard output, and on this channel standard
# output is read as a decision.
#
# The payload carries a synthetic cwd and a synthetic tool name. Nothing here
# names a real repository or a real command, so no row this creates in the
# user's panel can be mistaken for their own work.
post_event() {
    local session=$1 event=$2
    printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","tool_name":"%s"}' \
        "$event" "$session" "/tmp/coffee-bar-acceptance-t8" "AcceptanceProbe" \
        | curl -sS -o /dev/null --fail-with-body --max-time 5 \
            --unix-socket "$SOCKET" \
            -X POST --data-binary @- "http://localhost$event_endpoint"
}

# Sourcing this file defines the helpers and measures nothing, so the sibling
# _test.sh can check them without a running app and without half an hour.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
