#!/bin/bash
# Acceptance check: does the Preferences window ACTIVATE when opened from the panel?
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
# MEASURED ON 2026-08-06, before the fix, at 0.1.1-31-g7949c51:
#     before=Finder | after=Finder | windows=[coffee-bar Settings]
# The window existed and Finder stayed frontmost. That is the defect.
#
# EXPECTED AFTER THE FIX:
#     before=Finder | after=coffee-bar | windows=[coffee-bar Settings]
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
#
# THE ALTERNATIVE THAT WAS CONSIDERED, recorded so nobody re-derives it. Anchoring
# on the popover's own bottom edge fits every panel height measured:
#     35 + 524 - 497 = 62      35 + 487 - 460 = 62      35 + 383 - 355 = 63
# so `py = popoverBottom - 62` would land on Preferences… at all three, and it is
# a real improvement on the status-item offset. It was not taken because 62 is
# still a remembered number: it encodes the bottom padding, the Quit button, the
# spacing and half a button, and it silently stops being true the first time a
# control is added below Preferences…. Reading the button gives the same answer
# with nothing to remember.
#
# THE ONE THING AX CANNOT TELL US, and how that is handled. SwiftUI gives neither
# button a title: both `SettingsLink { Text("Preferences…") }` and
# `Button("Quit coffee-bar")` come back as an untitled AXButton, so the tree can
# say WHERE the two buttons are but not WHICH is which. Position alone would put
# us back to guessing, with Quit as the cost of guessing wrong. So the order is
# read out of PanelView.swift — the file that decides it — and the click only
# happens when the source and the tree agree about the shape of the panel.
#
# EXIT CODES, and the distinction is the point of this rewrite:
#     0  the acceptance criterion held
#     1  the criterion FAILED — the click landed and the result was wrong
#     2  REFUSED — the panel did not look the way this script knows how to read,
#        so it clicked NOTHING. Never a pass, never a destroyed app.
#
# Requires Accessibility permission for the invoking terminal.
# Usage: scripts/preferences-activation-acceptance.sh
set -uo pipefail

APP_NAME="coffee-bar"
WINDOW_NAME="coffee-bar Settings"

# The panel's two buttons: Preferences… then Quit. A third control at the foot of
# the panel is not a disaster — it is a reason to stop and re-read this script,
# because the topmost-of-two rule below stops being the right rule.
EXPECTED_PANEL_BUTTONS=2

# The smallest vertical gap between the two buttons that this script will treat as
# two distinct rows. They sit 36 points apart in the shipped panel. Anything under
# a button's own height means the tree is reporting something this script does not
# understand, and clicking into that is how the old version killed the app.
MINIMUM_BUTTON_GAP=20

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PANEL_SOURCE="${REPO_ROOT}/Sources/CoffeeBarUI/PanelView.swift"

fail()   { echo "FAIL: $*"; exit 1; }
refuse() { echo "REFUSED: $*"; echo "        Nothing was clicked."; exit 2; }

open_window_count() {
    osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to count of windows" 2>/dev/null
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
    for attempt in 1 2 3; do
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

pgrep -f "CoffeeBar.app/Contents/MacOS/coffee-bar" >/dev/null 2>&1 \
    || fail "coffee-bar is not running. Launch the build under test first."

# --- Which button is Preferences…, according to the file that decides ---------
#
# Read BEFORE anything is opened, so a source tree that disagrees with this
# script costs nothing at all. `grep -n | head | cut` cannot be gated on its own
# exit code — a pipeline reports the LAST command's status — so both results are
# gated on being non-empty instead.
SETTINGS_LINE=$(grep -n 'SettingsLink' "${PANEL_SOURCE}" | grep -v '//' | head -1 | cut -d: -f1)
QUIT_LINE=$(grep -n 'Button("Quit' "${PANEL_SOURCE}" | head -1 | cut -d: -f1)

[ -n "${SETTINGS_LINE}" ] \
    || refuse "cannot locate Preferences… safely: no SettingsLink in ${PANEL_SOURCE}"
[ -n "${QUIT_LINE}" ] \
    || refuse "cannot locate Preferences… safely: no Quit button in ${PANEL_SOURCE}"
[ "${SETTINGS_LINE}" -lt "${QUIT_LINE}" ] \
    || refuse "cannot locate Preferences… safely: PanelView.swift puts Quit (line ${QUIT_LINE}) above Preferences… (line ${SETTINGS_LINE}), so the topmost button is no longer the one to click"

# --- Start from no windows open ----------------------------------------------
#
# Every reading below is ambiguous otherwise: with a window already up this
# script cannot tell a leftover from the one it is about to ask for, and the
# whole criterion is that a window APPEARS.
reset_windows \
    || refuse "cannot get ${APP_NAME} back to no open windows — $(open_window_count) remain. Close them and run again."

# A foreign app must own the foreground, or "did it come forward" is unaskable.
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
sleep 1

# --- Phase 1: open the panel and MEASURE it. No click but the status item. ----
PROBE=$(osascript <<OSA
tell application "System Events"
	set beforeName to name of first process whose frontmost is true

	tell process "${APP_NAME}"
		-- A window already open makes every reading below ambiguous: this
		-- script cannot tell a leftover Settings window from the one it is
		-- about to ask for.
		if (count of windows) is not 0 then
			return beforeName & "|stale|" & ((name of every window) as string)
		end if
		click menu bar item 1 of menu bar 2
	end tell
	delay 2

	tell process "${APP_NAME}"
		if (count of windows) is 0 then return beforeName & "|nopanel|"
		set panel to window 1
		set {panelW, panelH} to size of panel
		set {panelX, panelY} to position of panel
		set btns to (every UI element of UI element 1 of panel whose role is "AXButton")
		set n to count of btns
		if n is 0 then return beforeName & "|nobuttons|" & panelW & "x" & panelH

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
		-- runs what it encloses as a command — this comment previously quoted a
		-- variable name that way and every run printed "by: command not found"
		-- twice before going on to pass.
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

		return beforeName & "|ok|" & n & "|" & ((item 1 of topPoint) as integer) ¬
			& "|" & ((item 2 of topPoint) as integer) & "|" & topY & "|" & otherY ¬
			& "|" & (panelW as integer) & "|" & (panelH as integer) ¬
			& "|" & (panelY as integer)
	end tell
end tell
OSA
)
OSA_RC=$?
[ ${OSA_RC} -eq 0 ] \
    || refuse "AppleScript did not run (rc=${OSA_RC}). Accessibility permission missing?"

BEFORE=$(printf '%s' "$PROBE" | cut -d'|' -f1)
STATUS=$(printf '%s' "$PROBE" | cut -d'|' -f2)

case "$STATUS" in
    stale)
        refuse "a window of ${APP_NAME} is already open [$(printf '%s' "$PROBE" | cut -d'|' -f3)]. Close it and run again." ;;
    nopanel)
        refuse "cannot locate Preferences… safely: clicking the status item opened no panel" ;;
    nobuttons)
        reset_windows
        refuse "cannot locate Preferences… safely: the panel exposes no buttons in the accessibility tree" ;;
    ok) ;;
    *)
        refuse "cannot locate Preferences… safely: unreadable probe [${PROBE}]" ;;
esac

BUTTONS=$(printf '%s' "$PROBE" | cut -d'|' -f3)
CLICK_X=$(printf '%s' "$PROBE" | cut -d'|' -f4)
CLICK_Y=$(printf '%s' "$PROBE" | cut -d'|' -f5)
TOP_Y=$(printf '%s' "$PROBE" | cut -d'|' -f6)
OTHER_Y=$(printf '%s' "$PROBE" | cut -d'|' -f7)
PANEL_W=$(printf '%s' "$PROBE" | cut -d'|' -f8)
PANEL_H=$(printf '%s' "$PROBE" | cut -d'|' -f9)
PANEL_Y=$(printf '%s' "$PROBE" | cut -d'|' -f10)

echo "panel=${PANEL_W}x${PANEL_H}@y${PANEL_Y} buttons=${BUTTONS} preferences@${CLICK_X},${CLICK_Y}"

# --- The refusals. Every one of them happens BEFORE any click. ----------------

[ "${BUTTONS}" = "${EXPECTED_PANEL_BUTTONS}" ] || {
    reset_windows
    refuse "cannot locate Preferences… safely: the panel has ${BUTTONS} buttons and this script knows how to read ${EXPECTED_PANEL_BUTTONS}. Topmost-of-two is no longer a rule that identifies Preferences…"
}

GAP=$(( OTHER_Y - TOP_Y ))
[ "${GAP}" -ge "${MINIMUM_BUTTON_GAP}" ] || {
    reset_windows
    refuse "cannot locate Preferences… safely: the two buttons are ${GAP} points apart, under the ${MINIMUM_BUTTON_GAP} this script requires to tell them apart"
}

# The click has to land inside the panel the tree just described, and BOTH bounds
# come from that same reading rather than from a remembered menu-bar height. This
# is the check the fixed offset never had: it is what turns a panel of an
# unexpected size into a refusal instead of a click on whatever is there.
PANEL_BOTTOM=$(( PANEL_Y + PANEL_H ))
[ "${CLICK_Y}" -gt "${PANEL_Y}" ] && [ "${CLICK_Y}" -lt "${PANEL_BOTTOM}" ] || {
    reset_windows
    refuse "cannot locate Preferences… safely: the resolved point y=${CLICK_Y} is outside the panel, which runs from y=${PANEL_Y} to y=${PANEL_BOTTOM}"
}

# --- Phase 2: click the resolved point, and only now. -------------------------
RESULT=$(osascript <<OSA
tell application "System Events"
	click at {${CLICK_X}, ${CLICK_Y}}
	delay 3

	set afterName to name of first process whose frontmost is true

	set winList to ""
	try
		tell process "${APP_NAME}"
			set winList to (name of every window) as string
		end tell
	end try

	return afterName & "|" & winList
end tell
OSA
)
OSA_RC=$?
[ ${OSA_RC} -eq 0 ] || fail "AppleScript did not run after the click (rc=${OSA_RC})"

AFTER=$(printf '%s' "$RESULT" | cut -d'|' -f1)
WINS=$(printf '%s' "$RESULT" | cut -d'|' -f2)

echo "before=$BEFORE"
echo "after =$AFTER"
echo "windows=[$WINS]"

# The app surviving its own acceptance check is now an assertion rather than a
# hope. A click that reached Quit shows up here as a dead process, and the
# message says which defect that is.
pgrep -f "CoffeeBar.app/Contents/MacOS/coffee-bar" >/dev/null 2>&1 \
    || fail "coffee-bar is no longer running — the click reached Quit. The button resolution above is wrong; do not re-run until it is fixed."

# The check would be vacuous if something else already held the foreground.
[ "$BEFORE" = "Finder" ] || fail "expected Finder frontmost before the click, got '$BEFORE'"

case "$WINS" in
    *"$WINDOW_NAME"*) ;;
    *) fail "no window named '$WINDOW_NAME' — Preferences did not open at all" ;;
esac

# THE MESSAGE IS THE FIX INSTRUCTION, so it must not name a disproven one. This
# used to say the fix is NSApp.activate(ignoringOtherApps:) on the SettingsLink
# path. Task 6 measured that and it is WRONG: macOS 14 made activation
# cooperative, so an .accessory app asking for the foreground is declined — the
# call runs, returns, and nothing happens. Two other routes were measured dead
# too, and PreferencesView.swift records all three. Sending the next reader down
# the route that was already tried is worse than saying nothing.
[ "$AFTER" = "$APP_NAME" ] \
    || fail "window opened but '$APP_NAME' is not frontmost (got '$AFTER'). The window is inactive: grey title bar, keyboard input goes elsewhere. The fix is NSApp.setActivationPolicy(.regular) and THEN activate, on .onAppear of the Settings scene, reverting to .accessory in .onDisappear. activate(ignoringOtherApps:) alone does nothing under .accessory — measured, see PreferencesView.swift."

# Leave the app as it was found, so the next run starts from the state this one
# demanded. Deliberately AFTER the assertions: a failed run keeps its evidence on
# screen for whoever has to look at it.
reset_windows || echo "NOTE: could not close the windows this run opened."

echo "PASS: Preferences opened AND took the foreground."
echo "NOTE: popover dismissal is not asserted here — no AX handle exists for a"
echo "      MenuBarExtra popover. Confirm by eye that the panel closes."
exit 0
