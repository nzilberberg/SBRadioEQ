#!/bin/sh
# Lint for tools/deploy.sh -- guards the ways it can brick or reboot the Radio.
#
#   sh tools/check-deploy.sh [script-to-check]
#
# These are not style rules. Each one is a failure that actually happened.

set -e

TARGET="${1:-$(cd "$(dirname "$0")" && pwd)/deploy.sh}"
[ -f "$TARGET" ] || { echo "FAIL: no such file: $TARGET"; exit 2; }

fail=0
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
ok()  { echo "  ok    $1"; }

# Strip comments so the prose explaining a hazard does not read as the hazard.
CODE=$(sed 's/#.*$//' "$TARGET")

# --- 1. `squeezeplay stop` reboots the device -----------------------------
#
# stop DELETES /var/run/squeezeplay.pid. The watchdog polls that file every 5 s
# (interval=5 in /etc/watchdog.conf) and treats a missing pidfile as a failure:
# it runs repair.sh and lets the hardware watchdog reboot. Any deploy that holds
# the process down longer than 5 s -- which this one does, swapping a directory
# -- reboots the Radio. stopwdog parks a `sleep 1h` pid instead.
if echo "$CODE" | grep -qE 'squeezeplay[[:space:]]+stop([^w]|$)'; then
	bad "uses 'squeezeplay stop' -- deletes the pidfile and the watchdog reboots the Radio; use stopwdog"
else
	ok "uses stopwdog, not stop"
fi

# --- 2. the placeholder must be cleared before start ----------------------
#
# stopwdog leaves a live `sleep 1h` in the pidfile, and `start` refuses to run
# when the pidfile holds a LIVING pid ("SqueezePlay is already running"). Using
# stopwdog without clearing it means the device never comes back.
if echo "$CODE" | grep -q 'stopwdog'; then
	if echo "$CODE" | grep -q 'rm -f /var/run/squeezeplay.pid'; then
		ok "clears the watchdog placeholder before starting"
	else
		bad "uses stopwdog but never clears /var/run/squeezeplay.pid -- start will refuse"
	fi
fi

# --- 3. no hardcoded device address --------------------------------------
# Any IPv4 literal in CODE (comments are stripped above, so the usage example in
# the header is fine). An earlier pattern matched only `RADIO=<ip>` and missed
# `RADIO="${RADIO:-root@<ip>}"` -- the exact form that was actually there.
hit=$(echo "$CODE" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
if [ -n "$hit" ]; then
	bad "hardcodes a device address in code: $hit"
else
	ok "no hardcoded device address"
fi

# --- 4. host identity must not be disabled -------------------------------
#
# This writes executable Lua as root. StrictHostKeyChecking=no lets anything
# answering on that address receive it.
if echo "$CODE" | grep -q 'StrictHostKeyChecking=no'; then
	bad "disables host key checking on a root deploy target"
else
	ok "host key checking not disabled"
fi

# --- 5. one manifest, used everywhere ------------------------------------
#
# An earlier version globbed the install list but parse-checked four hardcoded
# names, so uistate.lua shipped unparsed and strings.txt never shipped at all.
if echo "$CODE" | grep -q 'MANIFEST'; then
	ok "builds a manifest"
else
	bad "no manifest -- staging, parsing and installing can drift apart"
fi

# --- 6. a failed deploy must not consume a build number ------------------
if echo "$CODE" | grep -q 'rollback_build'; then
	ok "rolls the build number back on failure"
else
	bad "no build-number rollback -- a failed deploy leaves holes in the sequence"
fi

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-deploy: $fail problem(s)"
	exit 1
fi
echo "check-deploy: clean"
