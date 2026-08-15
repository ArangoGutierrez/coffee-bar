#!/bin/bash
# Acceptance check: does Preferences ACTIVATE the app and DISMISS the panel,
# both on a first click and on a click while the window is already open?
#
# WHY THIS EXISTS AS A SCRIPT AND NOT A UNIT TEST
# coffee-bar is LSUIElement. It has no Dock icon and no natural activation, so a
# Settings scene opened from a MenuBarExtra popover can render on screen while the
# app never becomes frontmost: the window draws, its title bar stays grey, keyboard
# input goes elsewhere, and the popover it was launched from does not dismiss.
# No unit test can observe any of that — M1 design §5.4 rules out asserting on
# rendered AppKit state, and the failure is in the window server's notion of which
# app is active.
#
# MEASURED ON 2026-08-06, before the #50 fix, at 0.1.1-31-g7949c51:
#     before=Finder | after=Finder | windows=[coffee-bar Settings]
# The window existed and Finder stayed frontmost. That is the defect.
#
# WHAT #50 FIXED AND WHAT IT LEFT (issue #63). `ba3ecbd` hung the fix off
# `PreferencesView.onAppear`, which fires when the window is CREATED. Measured
# back to back at that commit:
#     windows before = []                      -> after = coffee-bar   (fixed)
#     windows before = [coffee-bar Settings]   -> after = Finder       (NOT fixed)
# A second click re-presents a window that already exists, `onAppear` does not
# re-fire, and the original defect is back. That is why this script now runs the
# whole interaction TWICE, and the second pass is the one that matters: open
# Preferences, click away, click Preferences again is what a user does.
#
# HOW IT USED TO FIND THE BUTTON, AND WHY THAT WAS A HAZARD
# The first version of this script clicked a FIXED OFFSET below the status item —
# {+68, +493} — derived from one screenshot of one panel. The panel's height is
# content-dependent: it was measured at 260x524 and at 260x487 within one hour,
# because the number of live agent sessions changes the attention list, and
# removing the lid-closed paragraph (#56) takes another 117 points off it. At 487
# that offset lands on QUIT, so a missed run TERMINATED THE APP UNDER TEST. Twelve
# of twenty-four runs landed. A check that destroys its own subject half the time
# is worse than no check.
#
# It now resolves the button through the accessibility tree and clicks the frame
# the window server reports. NOTHING here is derived from a remembered coordinate.
# The panel measured 260x617 on 2026-08-15, a third height, which is the point.
#
# THE ALTERNATIVE THAT WAS CONSIDERED, recorded so nobody re-derives it. Anchoring
# on the popover own bottom edge fits every panel height measured:
#     35 + 524 - 497 = 62      35 + 487 - 460 = 62      35 + 383 - 355 = 63
# so `py = popoverBottom - 62` would land on Preferences at all three, and it is
# a real improvement on the status-item offset. It was not taken because 62 is
# still a remembered number: it encodes the bottom padding, the Quit button, the
# spacing and half a button, and it silently stops being true the first time a
# control is added below Preferences. Reading the button gives the same answer
# with nothing to remember.
#
# THE ONE THING AX CANNOT TELL US, and how that is handled. SwiftUI gives neither
# button a title: the Preferences control and `Button("Quit coffee-bar")` both
# come back as an untitled AXButton, so the tree can say WHERE the two buttons are
# but not WHICH is which. Position alone would put us back to guessing, with Quit
# as the cost of guessing wrong. So the order is read out of PanelView.swift — the
# file that decides it — and the click only happens when the source and the tree
# agree about the shape of the panel.
#
# THE SOURCE ANCHOR IS THE LABEL, NOT THE CONTROL TYPE. This used to grep for
# `SettingsLink`, which pinned the check to one implementation of the button: the
# #63 fix has to run code on every click, and a `SettingsLink` is a link, not a
# closure. `"Preferences…"` is the rendered label, it appears exactly once in
# PanelView.swift and never in a comment there, and it is what the user is
# actually looking for on screen. A check that breaks when the implementation
# changes but the product does not is a check that gets deleted.
#
# WHAT THE ACCESSIBILITY TREE DOES EXPOSE, corrected here on measurement. This
# script used to end by saying that popover dismissal could not be asserted
# because "no AX handle exists for a MenuBarExtra popover". That is FALSE, and
# this script own Phase 1 always contradicted it — it reads the popover to find
# the button. Measured 2026-08-15 with both open:
#     [1] name=[] sub=AXSystemDialog     size=260x617 btns=2
#     [2] name=[coffee-bar Settings] sub=AXStandardWindow size=420x560 btns=0
# The popover is an UNNAMED window and the Settings window is the named one, so
# the two are told apart BY NAME. Dismissal is therefore assertable, and it is
# asserted below rather than left to the reader eye.
#
# NEVER BY INDEX. `window 1` was the popover for as long as the popover was the
# only window, which is the only case the first version of this script allowed.
# With a Settings window already open — the whole point of Phase 2 — `window 1`
# is the SETTINGS window, and resolving the button through it returned
# `nobuttons`. Everything below finds the popover by name.
#
# WHY A BUSY DESKTOP IS A REFUSAL AND NOT A FAILURE. A MenuBarExtra popover
# dismisses itself the moment its app resigns active, and that was measured here
# rather than assumed:
#     +01s  Finder    n=2 { 260x617} {coffee-bar Settings 420x793}
#     +02s  WhatsApp  n=1 {coffee-bar Settings 420x793}
# Somebody switching to another app one second after the panel opens takes the
# panel with it. Every reading after that is about a panel that is not there, and
# a click aimed at a resolved point would land in whatever window now occupies it
# — in someone else application, not this one. So the foreground is checked for
# STABILITY before anything opens, and re-checked immediately before the click,
# and either check failing is exit 2. This script needs a machine nobody is
# using; it now says so instead of producing a wrong answer.
#
# EXIT CODES, and the distinction is the point of this rewrite:
#     0  the acceptance criterion held, on BOTH invocations
#     1  the criterion FAILED — the click landed and the result was wrong
#     2  REFUSED — the panel did not look the way this script knows how to read,
#        or the desktop was in use, so it clicked NOTHING. Never a pass, never a
#        destroyed app.
#
# Requires Accessibility permission for the invoking terminal.
# Usage: scripts/preferences-activation-acceptance.sh
set -uo pipefail

APP_NAME="coffee-bar"
WINDOW_NAME="coffee-bar Settings"

# The panel two buttons: Preferences then Quit. A third control at the foot of
# the panel is not a disaster — it is a reason to stop and re-read this script,
# because the topmost-of-two rule below stops being the right rule.
EXPECTED_PANEL_BUTTONS=2

# The smallest vertical gap between the two buttons that this script will treat as
# two distinct rows. They sit 36 points apart in the shipped panel. Anything under
# a button own height means the tree is reporting something this script does not
# understand, and clicking into that is how the old version killed the app.
MINIMUM_BUTTON_GAP=20

# How long to wait for the popover to register in the accessibility tree, in
# one-second polls. NOT a fixed delay: the old `delay 2` was enough on an idle
# machine and not enough on a loaded one, and a resolve that runs one turn early
# reports `nopanel` on a panel that is about to appear. Polling turns that from a
# flake into a wait.
PANEL_POLL_SECONDS=8

# How many consecutive one-second samples must agree that the same foreign app
# holds the foreground before this script will open anything.
FOREGROUND_STABLE_SAMPLES=3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PANEL_SOURCE="${REPO_ROOT}/Sources/CoffeeBarUI/PanelView.swift"

fail()   { echo "FAIL: $*"; exit 1; }
refuse() { echo "REFUSED: $*"; echo "        Nothing was clicked."; exit 2; }

# A FAILING CRITERION IS RECORDED AND THE RUN CONTINUES; only a refusal stops
# early. Issue #63 is two defects, and fail-fast can only ever show the first:
# on an unfixed tree the panel does not dismiss, so a script that exited there
# would never reach the second invocation — the one that measures whether
# re-opening an existing window activates. The whole point of this rewrite is to
# put BOTH residuals in one run of output, so the report of it is a measurement
# rather than a to-do list.
#
# A REFUSAL still exits immediately, and the distinction is the same one the exit
# codes draw: a failure is an answer, a refusal is the absence of one.
FAILURES=()
note_failure() {
    FAILURES+=("$*")
    echo "FAIL: $*"
}

open_window_count() {
    osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to count of windows" 2>/dev/null
}

frontmost_app() {
    osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null
}

# frontmost|hasSettings|hasPanel|names — everything an assertion below needs, read
# in ONE pass so the three cannot disagree with each other about a moving target.
snapshot() {
    osascript <<OSA 2>/dev/null
tell application "System Events"
	set fm to name of first process whose frontmost is true
	set hasSettings to 0
	set hasPanel to 0
	set names to ""
	tell process "${APP_NAME}"
		repeat with w in (every window)
			set nm to ""
			try
				set nm to (name of w) as string
			end try
			if nm is "${WINDOW_NAME}" then
				set hasSettings to 1
			else
				set hasPanel to 1
			end if
			set names to names & "<" & nm & ">"
		end repeat
	end tell
	return fm & "|" & hasSettings & "|" & hasPanel & "|" & names
end tell
OSA
}

# Put the app back to no windows open, whatever it was showing.
#
# ESCAPE DOES NOT DISMISS THE POPOVER, and that was measured here: the first
# draft of this rewrite pressed key code 53 between runs, and every run after the
# first refused with a window still open. A MenuBarExtra popover closes by
# clicking the status item again, and the Settings window closes by its own close
# button. Two windows, two mechanisms, and neither is Escape.
#
# This is also what makes the script RE-RUNNABLE. It opens a Settings window
# every time it passes, so a version that did not clean up could only ever be run
# once between manual closes.
reset_windows() {
    local attempt n
    for attempt in 1 2 3 4 5; do
        n=$(open_window_count)
        [ "${n}" = "0" ] && return 0
        osascript >/dev/null 2>&1 <<OSA
tell application "System Events"
	tell process "${APP_NAME}"
		set w to window 1
		if (name of w) is "${WINDOW_NAME}" then
			click (first button of w whose subrole is "AXCloseButton")
		else
			click menu bar item 1 of menu bar 2
		end if
	end tell
end tell
OSA
        sleep 1
    done
    [ "$(open_window_count)" = "0" ]
}

click_status_item() {
    osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to click menu bar item 1 of menu bar 2" >/dev/null 2>&1
}

# Close a popover the previous invocation left open.
#
# This is TEST SETUP, not part of the criterion, and the distinction matters: the
# panel staying open IS one of the two defects, and it is recorded as a failure
# before this runs. Without this the second invocation would find a panel already
# up, refuse as ambiguous, and the second residual would be invisible behind the
# first on exactly the tree that has both.
dismiss_panel_if_open() {
    local snap panel attempt
    snap="$(snapshot)"
    panel=$(printf '%s' "${snap}" | cut -d'|' -f3)
    [ "${panel}" = "0" ] && return 0
    echo "  (test setup: dismissing the panel this invocation left open)"
    for ((attempt = 1; attempt <= 4; attempt++)); do
        click_status_item
        sleep 1
        snap="$(snapshot)"
        panel=$(printf '%s' "${snap}" | cut -d'|' -f3)
        [ "${panel}" = "0" ] && return 0
    done
    return 1
}

# Find the popover — the window that is NOT the Settings window — and resolve the
# topmost of its buttons. Never `window 1`; see the header.
probe_panel() {
    osascript <<OSA 2>/dev/null
tell application "System Events"
	tell process "${APP_NAME}"
		set panel to missing value
		repeat with w in (every window)
			set nm to ""
			try
				set nm to (name of w) as string
			end try
			if nm is not "${WINDOW_NAME}" then
				set panel to w
				exit repeat
			end if
		end repeat
		if panel is missing value then return "nopanel|"
		set {panelW, panelH} to size of panel
		set {panelX, panelY} to position of panel
		set btns to (every UI element of UI element 1 of panel whose role is "AXButton")
		set n to count of btns
		if n is 0 then return "nobuttons|" & panelW & "x" & panelH

		-- Topmost first, and every reading comes from the tree. Nothing below is
		-- a remembered coordinate: AXActivationPoint is what the window server
		-- itself answers to "where would a click on this land", which is the
		-- question the old fixed offset was guessing at.
		--
		-- NO APOSTROPHE AND NO BACKTICK MAY APPEAR IN THIS HEREDOC, and both
		-- were measured here rather than assumed. The heredoc is unquoted and
		-- sits inside a $( ), so bash still reads it: a lone apostrophe makes
		-- bash -n report "unexpected EOF while looking for matching quote"
		-- against the END of the file, nowhere near the cause, and a backtick
		-- runs what it encloses as a command.
		set topY to 0
		set topPoint to {0, 0}
		set otherY to 0
		set seen to 0
		-- btnY, and never the two-letter name AppleScript reserves for a
		-- preposition. Using that one as a variable is a syntax error reported
		-- against a line number in generated source, nowhere near this file.
		repeat with b in btns
			set {btnX, btnY} to position of b
			set btnY to btnY as integer
			if seen is 0 then
				set topY to btnY
				set otherY to btnY
				set topPoint to (value of attribute "AXActivationPoint" of b)
			else if btnY < topY then
				set otherY to topY
				set topY to btnY
				set topPoint to (value of attribute "AXActivationPoint" of b)
			else if btnY > otherY then
				set otherY to btnY
			end if
			set seen to seen + 1
		end repeat

		return "ok|" & n & "|" & ((item 1 of topPoint) as integer) ¬
			& "|" & ((item 2 of topPoint) as integer) & "|" & topY & "|" & otherY ¬
			& "|" & (panelW as integer) & "|" & (panelH as integer) ¬
			& "|" & (panelY as integer)
	end tell
end tell
OSA
}

# Open the panel and resolve the button, polling rather than trusting a delay.
# Echoes the probe result; the caller decides what a refusal means.
open_panel_and_resolve() {
    local attempt result
    click_status_item
    for ((attempt = 1; attempt <= PANEL_POLL_SECONDS; attempt++)); do
        sleep 1
        result="$(probe_panel)"
        case "${result}" in
            ok\|*) printf '%s' "${result}"; return 0 ;;
        esac
    done
    printf '%s' "${result}"
    return 1
}

# --- 0. Preflight -------------------------------------------------------------

pgrep -f "CoffeeBar.app/Contents/MacOS/coffee-bar" >/dev/null 2>&1 \
    || fail "coffee-bar is not running. Launch the build under test first."

# --- Which button is Preferences, according to the file that decides ---------
#
# Read BEFORE anything is opened, so a source tree that disagrees with this
# script costs nothing at all. `grep -n | head | cut` cannot be gated on its own
# exit code — a pipeline reports the LAST command status — so both results are
# gated on being non-empty instead.
#
# Comment lines are stripped first. The label literal appears once in code today,
# but a future comment quoting it must not be able to move the answer.
PREFS_LINE=$(grep -n '"Preferences…"' "${PANEL_SOURCE}" | grep -vE '^[0-9]+:[[:space:]]*//' | head -1 | cut -d: -f1)
QUIT_LINE=$(grep -n 'Button("Quit' "${PANEL_SOURCE}" | grep -vE '^[0-9]+:[[:space:]]*//' | head -1 | cut -d: -f1)

[ -n "${PREFS_LINE}" ] \
    || refuse "cannot locate Preferences safely: no \"Preferences…\" label in ${PANEL_SOURCE}"
[ -n "${QUIT_LINE}" ] \
    || refuse "cannot locate Preferences safely: no Quit button in ${PANEL_SOURCE}"
[ "${PREFS_LINE}" -lt "${QUIT_LINE}" ] \
    || refuse "cannot locate Preferences safely: PanelView.swift puts Quit (line ${QUIT_LINE}) above Preferences (line ${PREFS_LINE}), so the topmost button is no longer the one to click"

# --- Start from no windows open ----------------------------------------------
#
# Every reading in Phase 1 is ambiguous otherwise: with a window already up this
# script cannot tell a leftover from the one it is about to ask for, and the
# whole criterion is that a window APPEARS.
reset_windows \
    || refuse "cannot get ${APP_NAME} back to no open windows — $(open_window_count) remain. Close them and run again."

# A foreign app must own the foreground, or "did it come forward" is unaskable.
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
sleep 1

# ...and it must KEEP it. See the header: a popover dismisses itself when its app
# resigns active, so somebody using this Mac makes every reading below a reading
# of a panel that is no longer there.
STABLE_REF=""
for ((sample = 1; sample <= FOREGROUND_STABLE_SAMPLES; sample++)); do
    SEEN_APP="$(frontmost_app)"
    if [ -z "${STABLE_REF}" ]; then
        STABLE_REF="${SEEN_APP}"
    elif [ "${SEEN_APP}" != "${STABLE_REF}" ]; then
        refuse "the desktop is in use — the foreground moved from '${STABLE_REF}' to '${SEEN_APP}' while this script was starting up. A MenuBarExtra popover dismisses itself when coffee-bar resigns active, so nothing measured here would be about the panel. Run this on a Mac nobody is touching."
    fi
    sleep 1
done

# ANY foreign app will do, and requiring Finder specifically was measured wrong.
# The criterion is "coffee-bar was not frontmost and then was", so what it needs
# is that somebody else owns the foreground — not that it is Finder. On a machine
# whose terminal reclaims focus a second after Finder is activated, insisting on
# Finder refuses a run that could have been measured perfectly well: observed
# here as `expected Finder frontmost before this invocation, got 'cmux'` on a
# desktop that was otherwise idle. Finder is still ASKED for above, because a
# known foreign app is the tidiest state to start from; it is simply not required
# to have stuck.
[ "${STABLE_REF}" != "${APP_NAME}" ] \
    || refuse "${APP_NAME} already holds the foreground, so 'did it come forward' has no content. Click something else and run again."

# --- The two invocations ------------------------------------------------------
#
# `invocation` runs the whole interaction once and asserts the criterion. It is
# called twice, and the ONLY difference is what is already on screen: nothing the
# first time, a Settings window the second. That second call is issue #63 — the
# fix for #50 fired on window creation, so it did nothing when the window already
# existed.
invocation() {
    local label="$1" EXPECT_SETTINGS_BEFORE="$2"
    local FAILURES_AT_ENTRY=${#FAILURES[@]}
    echo
    echo "--- ${label} ---"

    # Hand the foreground to a foreign app, or "did coffee-bar come forward" has
    # no content. On the second pass coffee-bar is frontmost from the first one,
    # so this is what makes the second question askable at all.
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    sleep 1

    local BEFORE_SNAP BEFORE_FRONT BEFORE_SETTINGS BEFORE_PANEL
    BEFORE_SNAP="$(snapshot)"
    BEFORE_FRONT=$(printf '%s' "${BEFORE_SNAP}" | cut -d'|' -f1)
    BEFORE_SETTINGS=$(printf '%s' "${BEFORE_SNAP}" | cut -d'|' -f2)
    BEFORE_PANEL=$(printf '%s' "${BEFORE_SNAP}" | cut -d'|' -f3)
    echo "before: frontmost=${BEFORE_FRONT} settingsWindow=${BEFORE_SETTINGS} panel=${BEFORE_PANEL} windows=$(printf '%s' "${BEFORE_SNAP}" | cut -d'|' -f4)"

    # A FOREIGN app, not Finder specifically — see the preflight check.
    [ "${BEFORE_FRONT}" != "${APP_NAME}" ] \
        || refuse "${APP_NAME} is already frontmost before this invocation, so 'did it come forward' has no content"
    [ "${BEFORE_SETTINGS}" = "${EXPECT_SETTINGS_BEFORE}" ] \
        || refuse "expected settingsWindow=${EXPECT_SETTINGS_BEFORE} before this invocation, got ${BEFORE_SETTINGS}. The previous phase did not leave the state this one reads."
    [ "${BEFORE_PANEL}" = "0" ] \
        || refuse "a popover is already open before this invocation; every reading below would be ambiguous"

    local probe status
    probe="$(open_panel_and_resolve)"
    status=$(printf '%s' "${probe}" | cut -d'|' -f1)

    case "${status}" in
        nopanel)
            reset_windows
            refuse "cannot locate Preferences safely: clicking the status item opened no panel within ${PANEL_POLL_SECONDS}s" ;;
        nobuttons)
            reset_windows
            refuse "cannot locate Preferences safely: the panel exposes no buttons in the accessibility tree" ;;
        ok) ;;
        *)
            reset_windows
            refuse "cannot locate Preferences safely: unreadable probe [${probe}]" ;;
    esac

    local buttons CLICK_X CLICK_Y TOP_Y OTHER_Y PANEL_W PANEL_H PANEL_Y
    buttons=$(printf '%s' "${probe}" | cut -d'|' -f2)
    CLICK_X=$(printf '%s' "${probe}" | cut -d'|' -f3)
    CLICK_Y=$(printf '%s' "${probe}" | cut -d'|' -f4)
    TOP_Y=$(printf '%s' "${probe}" | cut -d'|' -f5)
    OTHER_Y=$(printf '%s' "${probe}" | cut -d'|' -f6)
    PANEL_W=$(printf '%s' "${probe}" | cut -d'|' -f7)
    PANEL_H=$(printf '%s' "${probe}" | cut -d'|' -f8)
    PANEL_Y=$(printf '%s' "${probe}" | cut -d'|' -f9)

    echo "panel=${PANEL_W}x${PANEL_H}@y${PANEL_Y} buttons=${buttons} preferences@${CLICK_X},${CLICK_Y}"

    # --- The refusals. Every one of them happens BEFORE any click. ------------

    [ "${buttons}" = "${EXPECTED_PANEL_BUTTONS}" ] || {
        reset_windows
        refuse "cannot locate Preferences safely: the panel has ${buttons} buttons and this script knows how to read ${EXPECTED_PANEL_BUTTONS}. Topmost-of-two is no longer a rule that identifies Preferences"
    }

    local gap=$(( OTHER_Y - TOP_Y ))
    [ "${gap}" -ge "${MINIMUM_BUTTON_GAP}" ] || {
        reset_windows
        refuse "cannot locate Preferences safely: the two buttons are ${gap} points apart, under the ${MINIMUM_BUTTON_GAP} this script requires to tell them apart"
    }

    # The click has to land inside the panel the tree just described, and BOTH
    # bounds come from that same reading rather than from a remembered menu-bar
    # height. This is the check the fixed offset never had: it is what turns a
    # panel of an unexpected size into a refusal instead of a click on whatever
    # is there.
    local PANEL_BOTTOM=$(( PANEL_Y + PANEL_H ))
    [ "${CLICK_Y}" -gt "${PANEL_Y}" ] && [ "${CLICK_Y}" -lt "${PANEL_BOTTOM}" ] || {
        reset_windows
        refuse "cannot locate Preferences safely: the resolved point y=${CLICK_Y} is outside the panel, which runs from y=${PANEL_Y} to y=${PANEL_BOTTOM}"
    }

    # LAST LOOK BEFORE THE CLICK. Everything above describes a panel that was
    # there when it was read. If the desktop moved in the meantime the panel is
    # gone and the resolved point now belongs to somebody else window — this is
    # the check that keeps a synthesised click out of it.
    local GUARD_SNAP GUARD_PANEL
    GUARD_SNAP="$(snapshot)"
    GUARD_PANEL=$(printf '%s' "${GUARD_SNAP}" | cut -d'|' -f3)
    [ "${GUARD_PANEL}" = "1" ] || {
        reset_windows
        refuse "the panel vanished between resolving it and clicking it — the desktop is in use. Nothing was clicked at ${CLICK_X},${CLICK_Y}."
    }

    # --- Click, and only now. -------------------------------------------------
    osascript -e "tell application \"System Events\" to click at {${CLICK_X}, ${CLICK_Y}}" >/dev/null 2>&1
    sleep 3

    local AFTER_SNAP AFTER_FRONT AFTER_SETTINGS AFTER_PANEL AFTER_NAMES
    AFTER_SNAP="$(snapshot)"
    AFTER_FRONT=$(printf '%s' "${AFTER_SNAP}" | cut -d'|' -f1)
    AFTER_SETTINGS=$(printf '%s' "${AFTER_SNAP}" | cut -d'|' -f2)
    AFTER_PANEL=$(printf '%s' "${AFTER_SNAP}" | cut -d'|' -f3)
    AFTER_NAMES=$(printf '%s' "${AFTER_SNAP}" | cut -d'|' -f4)

    echo "after : frontmost=${AFTER_FRONT} settingsWindow=${AFTER_SETTINGS} panel=${AFTER_PANEL} windows=${AFTER_NAMES}"

    # The app surviving its own acceptance check is an assertion rather than a
    # hope. A click that reached Quit shows up here as a dead process, and the
    # message says which defect that is.
    pgrep -f "CoffeeBar.app/Contents/MacOS/coffee-bar" >/dev/null 2>&1 \
        || fail "coffee-bar is no longer running — the click reached Quit. The button resolution above is wrong; do not re-run until it is fixed."

    # The one failure that stops the sequence. Everything after this reads a
    # window that is not there, and the second invocation premise — a Settings
    # window already open — cannot be set up at all.
    [ "${AFTER_SETTINGS}" = "1" ] || {
        note_failure "no window named '${WINDOW_NAME}' — Preferences did not open at all [${AFTER_NAMES}]"
        return 1
    }

    # RESIDUAL 1 (issue #63). The panel is drawn over the window it just opened
    # until something closes it. Asserted, not left to the eye: the popover is an
    # unnamed window in this process accessibility tree, which is the same
    # reading the button was resolved through.
    [ "${AFTER_PANEL}" = "0" ] \
        || note_failure "${label}: the Preferences window opened but THE PANEL IS STILL OPEN [${AFTER_NAMES}]. It draws over the window it just opened. Whatever opens the window has to dismiss the popover in the same action."

    # RESIDUAL 2 (issue #63) on the second invocation, and the original #50
    # defect on the first.
    #
    # THE MESSAGE IS THE FIX INSTRUCTION, so it must not name a disproven one.
    # This used to say the fix is NSApp.activate(ignoringOtherApps:) on the
    # SettingsLink path. Task 6 measured that and it is WRONG: macOS 14 made
    # activation cooperative, so an .accessory app asking for the foreground is
    # declined — the call runs, returns, and nothing happens. Two other routes
    # were measured dead too, and PreferencesView.swift records all three.
    # Sending the next reader down the route that was already tried is worse than
    # saying nothing.
    [ "${AFTER_FRONT}" = "${APP_NAME}" ] \
        || note_failure "${label}: window opened but '${APP_NAME}' is not frontmost (got '${AFTER_FRONT}'). The window is inactive: grey title bar, keyboard input goes elsewhere. setActivationPolicy(.regular) and THEN activate is what works under .accessory — but it has to run on THIS click. Hanging it off the Settings scene onAppear fixes only the invocation that CREATES the window, which is issue #63."

    # Leave the next invocation a state it can read. See dismiss_panel_if_open:
    # the panel staying open is already recorded above, so this hides nothing.
    dismiss_panel_if_open \
        || refuse "could not dismiss the panel left open by ${label}, so the next invocation cannot be read"

    [ ${#FAILURES[@]} -eq "${FAILURES_AT_ENTRY}" ] && echo "OK: ${label}"
    return 0
}

# FIRST: no window open. This is what #50 fixed and what the old script measured.
#
# A non-zero return means the window never opened, so the second invocation has
# no premise. Report what was collected rather than pressing on.
if invocation "invocation 1 of 2 — no Settings window open" 0; then
    # SECOND: the window from the first invocation is deliberately still open,
    # and this is the invocation issue #63 is about. Nothing is reset between
    # the two beyond dismissing a panel the first one should have closed itself.
    invocation "invocation 2 of 2 — Settings window ALREADY open" 1
else
    echo
    echo "NOTE: the second invocation was not run — the first never opened a window,"
    echo "      so there was nothing to re-open."
fi

# Leave the app as it was found, so the next run starts from the state this one
# demanded. Deliberately AFTER the assertions: a failed run keeps its evidence on
# screen for whoever has to look at it.
reset_windows || echo "NOTE: could not close the windows this run opened."

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo
    echo "FAILED: ${#FAILURES[@]} criteria did not hold."
    for failure in "${FAILURES[@]}"; do
        echo "  - ${failure}"
    done
    exit 1
fi

echo
echo "PASS: Preferences opened, took the foreground and dismissed the panel —"
echo "      on a first click AND on a click with the window already open."
exit 0
