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
# Requires Accessibility permission for the invoking terminal.
# Usage: scripts/preferences-activation-acceptance.sh
set -uo pipefail

APP_NAME="coffee-bar"
WINDOW_NAME="coffee-bar Settings"

fail() { echo "FAIL: $*"; exit 1; }

pgrep -f "CoffeeBar.app/Contents/MacOS/coffee-bar" >/dev/null 2>&1 \
    || fail "coffee-bar is not running. Launch the build under test first."

# A foreign app must own the foreground, or "did it come forward" is unaskable.
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
sleep 1

RESULT=$(osascript <<OSA
tell application "System Events"
	set beforeName to name of first process whose frontmost is true

	tell process "${APP_NAME}"
		set itm to menu bar item 1 of menu bar 2
		set p to position of itm
		click itm
	end tell
	delay 2

	-- Preferences… sits near the foot of the panel, which is anchored under the
	-- status item. Offset measured from a screenshot on 2026-08-06: the control
	-- sat at {997, 497} while the status item sat at {929, 4}.
	set px to (item 1 of p) + 68
	set py to (item 2 of p) + 493
	click at {px, py}
	delay 3

	set afterName to name of first process whose frontmost is true

	set winList to ""
	try
		tell process "${APP_NAME}"
			set winList to (name of every window) as string
		end tell
	end try

	return beforeName & "|" & afterName & "|" & winList
end tell
OSA
)

[ $? -eq 0 ] || fail "AppleScript did not run. Accessibility permission missing?"

BEFORE=$(printf '%s' "$RESULT" | cut -d'|' -f1)
AFTER=$(printf '%s' "$RESULT" | cut -d'|' -f2)
WINS=$(printf '%s' "$RESULT" | cut -d'|' -f3)

echo "before=$BEFORE"
echo "after =$AFTER"
echo "windows=[$WINS]"

# The check would be vacuous if something else already held the foreground.
[ "$BEFORE" = "Finder" ] || fail "expected Finder frontmost before the click, got '$BEFORE'"

case "$WINS" in
    *"$WINDOW_NAME"*) ;;
    *) fail "no window named '$WINDOW_NAME' — Preferences did not open at all" ;;
esac

[ "$AFTER" = "$APP_NAME" ] \
    || fail "window opened but '$APP_NAME' is not frontmost (got '$AFTER'). The window is inactive: grey title bar, keyboard input goes elsewhere. Fix is NSApp.activate(ignoringOtherApps: true) on the SettingsLink path."

echo "PASS: Preferences opened AND took the foreground."
echo "NOTE: popover dismissal is not asserted here — no AX handle exists for a"
echo "      MenuBarExtra popover. Confirm by eye that the panel closes."
exit 0
