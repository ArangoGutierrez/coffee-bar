#!/bin/bash
# t8-crashed-agent-hold-release_test.sh — unit tests for the harness's pure parts.
#
# WHY THIS EXISTS. The harness itself takes 15-30 minutes of wall clock to run
# once and its result is a MEASUREMENT, so a defect in how it reads `/status` or
# how it decides a verdict would be discovered only after the measurement was
# already spoiled. These are the parts that can be checked in a second, and each
# check below names a bug that is not hypothetical:
#
#   - `14_400` is a Swift underscore literal. A parse that stops at the
#     underscore reports the blocked timeout as 14 SECONDS.
#   - A field reader that returns the empty string for an absent key turns every
#     later arithmetic comparison into a silent no-op, and the harness polls for
#     half an hour observing nothing.
#   - A verdict that says PASS when the assertion was never released is the one
#     outcome issue #8 explicitly forbids.
#
# The subject is resolved SCRIPT_DIR-relative, never through $HOME: a sibling
# test that reaches for a deployed copy green-lights the wrong artifact.
#
# EXIT CODES: 0 all pass, 3 a check failed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 3
SUBJECT="$SCRIPT_DIR/t8-crashed-agent-hold-release.sh"

FAILURES=0
check() { # $1 = what, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

[ -f "$SUBJECT" ] || { echo "FAIL: subject not found at $SUBJECT"; exit 3; }

# Sourcing must define the functions and run NO measurement. A subject that
# starts polling when sourced would hang this test.
# shellcheck source=/dev/null
source "$SUBJECT" || { echo "FAIL: sourcing $SUBJECT failed"; exit 3; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t8-test.XXXXXX") || exit 3
trap 'rm -rf "$TMP"' EXIT INT TERM

# A real answer, captured from the running 0.3.0-rc2 build on 2026-08-18.
STATUS='{"attention":1,"holding":true,"hookHealth":"wired","intent":"auto","listening":true,"schemaVersion":1,"version":"0.3.0-rc2","working":4}'

# ── json_field ───────────────────────────────────────────────────────────────
check "json_field reads a number"          "4"     "$(json_field "$STATUS" working)"
check "json_field reads a small number"    "1"     "$(json_field "$STATUS" attention)"
check "json_field reads a bool"            "true"  "$(json_field "$STATUS" holding)"
check "json_field reads a string"          "auto"  "$(json_field "$STATUS" intent)"

# `version` is a SUFFIX of `schemaVersion`. A reader that matches the bare key
# name reports the schema version as the app version.
check "json_field does not match a suffix key" "0.3.0-rc2" "$(json_field "$STATUS" version)"

# An absent key must FAIL, not return empty. Empty is what makes the harness
# compare "" against "" for half an hour and call it stable.
json_field "$STATUS" sessions >/dev/null 2>&1
check "json_field fails on an absent key" "3" "$?"

# A false answer must not be mistaken for an absent one.
check "json_field reads false" "false" \
    "$(json_field '{"holding":false,"working":0}' holding)"

# ── derive_timeout ───────────────────────────────────────────────────────────
cat > "$TMP/StalePolicy.swift" <<'SWIFT'
public struct StalePolicy: Equatable, Sendable {
    public static let standard = StalePolicy(workingTimeout: 900,
                                             blockedTimeout: 14_400)
}
SWIFT
check "derive_timeout reads workingTimeout" "900" \
    "$(derive_timeout "$TMP/StalePolicy.swift" workingTimeout)"
# THE bug this file exists for: 14_400 is fourteen thousand four hundred.
check "derive_timeout expands a Swift underscore literal" "14400" \
    "$(derive_timeout "$TMP/StalePolicy.swift" blockedTimeout)"

derive_timeout "$TMP/StalePolicy.swift" napTimeout >/dev/null 2>&1
check "derive_timeout fails on a constant that is not there" "3" "$?"

# ── transitions ──────────────────────────────────────────────────────────────
# elapsed,working — a rise, a plateau, then two falls.
cat > "$TMP/timeline.csv" <<'CSV'
iso,epoch,elapsed,working,attention,holding
t,1,0,1,0,true
t,2,30,4,0,true
t,3,60,4,0,true
t,4,90,4,0,true
t,5,905,3,0,true
t,6,935,3,0,true
t,7,965,0,0,false
CSV
check "transitions ignores a plateau and signs each step" \
    "30 +3 1->4
905 -1 4->3
965 -3 3->0" \
    "$(transitions "$TMP/timeline.csv")"

# One row cannot contain a transition, and a header-only file must not emit the
# header as if it were data.
printf 'iso,epoch,elapsed,working,attention,holding\n' > "$TMP/empty.csv"
check "transitions on a header-only file prints nothing" "" \
    "$(transitions "$TMP/empty.csv")"

# ── verdict ──────────────────────────────────────────────────────────────────
# Arguments: reached_zero, holding_released, observed_drop.
check "verdict FULL needs the count at zero AND the hold released" \
    "FULL" "$(verdict yes yes yes)"
check "verdict is PARTIAL when the count dropped but never reached zero" \
    "PARTIAL" "$(verdict no no yes)"
# The forbidden outcome: sessions retired, machine still pinned. Issue #8's
# acceptance is the RELEASE, so this must never read FULL.
check "verdict is PARTIAL when zero was reached but the hold never went" \
    "PARTIAL" "$(verdict yes no yes)"
check "verdict is FAIL when nothing was ever retired" \
    "FAIL" "$(verdict no no no)"

echo "---"
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASS"
    exit 0
fi
echo "$FAILURES check(s) failed"
exit 3
