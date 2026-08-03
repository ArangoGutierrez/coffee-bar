#!/bin/bash
# t2-panel-version.sh — acceptance for "the panel shows the running version".
#
# WHY. Measured 2026-08-03 on main at 0985ea8: AppVersion.swift is present and
# AppVersion.display(from:) works, but PanelView.swift references it 0 times.
# The value exists and nothing renders it. The maintainer's own report was "I
# still don't see the version on the current installed coffee-bar".
#
# THIS SCRIPT LEARNS FROM TWO REVIEWS. The T3 and T4 acceptance scripts were
# each shown to accept wrong fixes. Every lesson is applied and named here:
#   - No `2>&1` on a command whose EMPTINESS is the signal. A failure writes
#     stderr into the file and makes a dead check look alive.
#   - Never `grep -q X && fail`: under `set -o pipefail` that PASSES when the
#     line is deleted outright. Assert presence positively instead.
#   - A "before" control must come from the GATE BASE, never from HEAD. After
#     the worker commits, HEAD is the candidate and the comparison is a
#     self-comparison that always says "no change".
#   - Anchoring on indentation alone does not bind the ENCLOSING scope.
#
# The strongest check here is check 4: it MUTATES the wiring and requires the
# suite to go red. A test that stays green when its subject is removed is
# theater, and this script refuses to accept one.
#
# EXIT CODES: 0 pass, 2 usage error, 3 check failed.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 2
cd "$REPO_ROOT" || exit 2

PANEL="Sources/CoffeeBarUI/PanelView.swift"
[ -f "$PANEL" ] || { echo "usage: run from the repo; $PANEL not found"; exit 2; }

BASELINE_TESTS=454   # measured on main at 0985ea8, sandbox disabled

fail() { echo "FAIL: $*"; exit 3; }
pass() { echo "PASS: $*"; }

# Run the suite; echo the count; return the suite's real exit code.
# NOTE: a pipe would eat the exit code, so the output goes to a file first.
run_suite() { # $1 = label, sets SUITE_RC and SUITE_COUNT
    local out="$TMP/suite-$1.log"
    swift test > "$out" 2>&1
    SUITE_RC=$?
    # "Executed 0 tests" is printed by the empty XCTest runner on every run and
    # must be ignored. The real line is "Test run with N tests ... passed".
    SUITE_COUNT=$(grep -oE 'Test run with [0-9]+ tests' "$out" | grep -oE '[0-9]+' | head -1)
    SUITE_COUNT=${SUITE_COUNT:-0}
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t2-acceptance.XXXXXX") || exit 2
BACKUP="$TMP/PanelView.swift.orig"
cp "$PANEL" "$BACKUP" || exit 2
# Restore on ANY exit path, including a failed check or an interrupt. Leaving a
# mutated source behind would corrupt the worker's tree.
restore() {
    if [ -f "$BACKUP" ]; then
        cat "$BACKUP" > "$PANEL"
    fi
    rm -rf "$TMP"
}
trap restore EXIT INT TERM

# ── 1. PanelView renders the version ─────────────────────────────────────────
# Positive assertion, never `grep && fail`.
grep -q "AppVersion" "$PANEL" \
    || fail "$PANEL does not reference AppVersion; the value is still unread"
pass "PanelView references AppVersion"

grep -qE "AppVersion\.display" "$PANEL" \
    || fail "PanelView references AppVersion but never calls display(from:)"
pass "PanelView calls AppVersion.display"

# ── 2. The suite is green ────────────────────────────────────────────────────
run_suite green
[ "$SUITE_RC" -eq 0 ] || {
    echo "--- suite tail ---"; tail -25 "$TMP/suite-green.log"
    fail "swift test exited $SUITE_RC, expected 0"
}
pass "swift test passes (exit 0)"

# ── 3. New tests were actually added ─────────────────────────────────────────
# A wiring change with no new test would otherwise sail through check 2.
[ "$SUITE_COUNT" -gt "$BASELINE_TESTS" ] \
    || fail "test count is $SUITE_COUNT, not greater than the baseline $BASELINE_TESTS; no new test guards this wiring"
pass "test count grew: $BASELINE_TESTS -> $SUITE_COUNT"

# ── 4. MUTATION: removing the wiring must turn the suite RED ─────────────────
# This is the check that makes theater impossible. Replace the AppVersion call
# with a literal, then require the suite to fail. Either a failing test or a
# compile error counts as caught: both prove the wiring is load-bearing. A suite
# that stays GREEN proves the new test asserts nothing about the version.
python3 - "$PANEL" "$TMP/mutant.swift" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Replace the whole AppVersion.display(...) call, balanced to one nesting level,
# with a literal. Non-greedy so it cannot swallow the rest of the file.
mutated, n = re.subn(r'AppVersion\.display\((?:[^()]|\([^()]*\))*\)', '"MUTANT-VERSION"', src)
open(sys.argv[2], 'w').write(mutated)
print(f"replacements={n}")
PY
REPL=$(python3 - "$PANEL" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
print(len(re.findall(r'AppVersion\.display\((?:[^()]|\([^()]*\))*\)', src)))
PY
)
[ "${REPL:-0}" -ge 1 ] || fail "could not locate an AppVersion.display(...) call to mutate"

# Prove the mutant differs, and differs NARROWLY. A mutation that rewrites half
# the file gives a confounded red.
cmp -s "$PANEL" "$TMP/mutant.swift" && fail "mutation produced an identical file; it did not apply"
DIFFLINES=$(diff "$PANEL" "$TMP/mutant.swift" | grep -cE '^[<>]')
[ "$DIFFLINES" -le 6 ] \
    || fail "mutation changed $DIFFLINES lines, too wide to attribute a red to the wiring"
echo "     (mutation applied, $REPL call(s), $DIFFLINES changed line(s))"

cat "$TMP/mutant.swift" > "$PANEL"
run_suite mutant
cat "$BACKUP" > "$PANEL"
cmp -s "$PANEL" "$BACKUP" || fail "INTERNAL: failed to restore $PANEL after mutation"

[ "$SUITE_RC" -ne 0 ] || {
    echo "--- the mutated suite stayed GREEN ---"; tail -10 "$TMP/suite-mutant.log"
    fail "removing the version wiring left the suite green; the new test is theater"
}
pass "mutation check: removing the wiring turns the suite red (exit $SUITE_RC)"

# ── 5. The tree is byte-identical to where it started ────────────────────────
cmp -s "$PANEL" "$BACKUP" || fail "INTERNAL: $PANEL differs from its backup at exit"
pass "PanelView restored byte-identical"

echo "ALL CHECKS PASS"
exit 0
