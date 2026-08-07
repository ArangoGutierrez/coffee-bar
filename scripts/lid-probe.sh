#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Lid-closed probe. Proves, every 5 seconds for 5 minutes, that the machine still has
# NETWORK and DISK while the lid is shut — and records whether the lid actually was shut.
#
# WHY THE SERVER'S CLOCK. Fetching a page proves nothing: a cached response, a captive
# portal, or a stale DNS answer all look like success. The `Date:` RESPONSE HEADER is the
# SERVER's clock, so a fresh one can only exist if a real round trip completed at that
# moment. Two independent hosts, because one host being down is not the same as the
# network being down.
#
# WHY CLAMSHELL STATE. Without it the log proves the machine kept working, not that it
# kept working WHILE CLOSED. AppleClamshellState flips to Yes when the lid shuts.
# AppleClamshellCausesSleep is the setting `coffee-bar-probe arm` changes — logging it
# proves arming took effect, rather than assuming it did.
#
# Usage:  bash scripts/lid-probe.sh [seconds]     (default 300)
set -uo pipefail

LOG=/tmp/coffee-bar-lid-probe.log
DURATION=${1:-300}
INTERVAL=5

lid_state()  { ioreg -r -k AppleClamshellState -d 4 2>/dev/null | awk -F'= ' '/AppleClamshellState/{print $2; exit}'; }
lid_sleeps() { ioreg -r -k AppleClamshellState -d 4 2>/dev/null | awk -F'= ' '/AppleClamshellCausesSleep/{print $2; exit}'; }
# Cache-bust every request. Measured while writing this: api.github.com returned an
# IDENTICAL Date header on two samples six seconds apart — a cached response. A cached
# date is worse than no probe, because it looks like a successful round trip while the
# network is down. The query string forces a fresh one, and `-H 'Cache-Control: no-cache'`
# covers an intermediate proxy.
server_date() {
    curl -sI --max-time 4 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$1?cb=$(date +%s)-$RANDOM" 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^date:/{sub(/^[Dd]ate: /,""); print; exit}'
}

: > "$LOG"
{
  echo "# coffee-bar lid probe"
  echo "# started      $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# duration     ${DURATION}s, every ${INTERVAL}s"
  echo "# columns      local | lid_closed | lid_causes_sleep | google_server_time | github_server_time | disk"
  echo "# lid_causes_sleep=No means coffee-bar-probe arm took effect"
} >> "$LOG"

END=$(( $(date +%s) + DURATION ))
n=0
while [ "$(date +%s)" -lt "$END" ]; do
    n=$(( n + 1 ))
    LOCAL=$(date '+%H:%M:%S')
    CLOSED=$(lid_state)
    SLEEPS=$(lid_sleeps)
    G=$(server_date https://www.google.com); [ -n "$G" ] || G="NETWORK-FAIL"
    H=$(server_date https://api.github.com); [ -n "$H" ] || H="NETWORK-FAIL"

    # Prove DISK by writing a marker file and reading it back, not by assuming the
    # append below succeeded.
    MARK="/tmp/coffee-bar-lid-probe.mark"
    printf '%s' "$n" > "$MARK" 2>/dev/null
    if [ "$(cat "$MARK" 2>/dev/null)" = "$n" ]; then DISK="ok"; else DISK="DISK-FAIL"; fi

    printf '%-9s | %-10s | %-16s | %-31s | %-31s | %s\n' \
        "$LOCAL" "${CLOSED:-?}" "${SLEEPS:-?}" "$G" "$H" "$DISK" >> "$LOG"
    sleep "$INTERVAL"
done

{
  echo "# finished     $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# samples      $n"
  echo "# net failures $(grep -c NETWORK-FAIL "$LOG")"
  echo "# disk failures $(grep -c DISK-FAIL "$LOG")"
  echo "# closed samples $(awk -F'|' '$2 ~ /Yes/' "$LOG" | wc -l | tr -d ' ')"
} >> "$LOG"
