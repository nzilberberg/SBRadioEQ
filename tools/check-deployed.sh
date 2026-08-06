#!/bin/sh
# SBRadioEQ -- is the fix actually ON the device, or only in git?
#
#   RADIO=root@<ip> sh tools/check-deployed.sh
#
# ⛔⛔ A FIX THAT IS COMMITTED BUT NOT DEPLOYED PROTECTS NOBODY.
#
# WHAT THIS COST. The owner reported the Radio shrieking while adjusting the EQ.
# Over the following hours the cause was found, fixed, gated, measured and
# committed SIX TIMES -- and the Radio ran the original build the entire time.
# Then they edited a setting and got a loud beep. The defect had been understood
# for hours and was still live on the only device that had it, because every
# report ended at "committed" and nothing checked the last step.
#
# Worse, the log was silent for that event: the old build's alarm only fires above
# 0.5 dB and only 3 of 269 clipping settings cross that. So "nothing in the log"
# read like "nothing happened" when it meant "the alarm is calibrated wrong AND
# the fix is not installed".
#
# THE RULE. When work is finished, the number on the DEVICE is what counts. git
# log is not evidence about a device.
#
# ⛔ THIS IS NOT A PRE-COMMIT GATE and must not become one -- committing without
# deploying is normal and fine mid-work. It is an AM-I-DONE gate: run it before
# telling anyone a device-affecting defect is fixed.

set -e

RADIO="${RADIO:?set RADIO=root@<your-radio-ip> -- no default, a wrong one reports about somebody else's device}"

HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"
DEST=/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua

SSHOPT="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
SSH="timeout ${SSH_TIMEOUT:-90} ssh $SSHOPT"

tree=$(grep -o '^local BUILD *= *[0-9]*' "$APPLET" | grep -o '[0-9]*$')
if [ -z "$tree" ]; then
	echo "FAIL: could not read BUILD from $APPLET -- the gate is broken, not the tree"
	exit 2
fi

dev=$($SSH -n "$RADIO" "grep -o '^local BUILD *= *[0-9]*' $DEST 2>/dev/null | grep -o '[0-9]*$'" 2>/dev/null || true)

# ⛔ UNREACHABLE IS NOT PASS. A gate that cannot see the device knows nothing about
# it, and "no answer" must never read as "up to date" -- that is the exact shape of
# the failure this exists to prevent.
if [ -z "$dev" ]; then
	echo "FAIL: could not read the installed BUILD from $RADIO."
	echo "  The device may be off, on its VPN address, or the applet is not installed."
	echo "  This is NOT a pass -- an unreachable device tells you nothing about what"
	echo "  is running on it. Ask LMS for the current address rather than guessing."
	exit 2
fi

# Digest comparison too: BUILD is bumped by deploy.sh, so a hand-edited applet can
# carry a build number that was never installed with THIS content.
lwant=$(md5sum "$APPLET" 2>/dev/null | cut -d' ' -f1)
lgot=$($SSH -n "$RADIO" "md5sum $DEST 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)

if [ "$tree" != "$dev" ]; then
	echo "FAIL: the device is running build $dev; the tree is build $tree."
	echo ""
	echo "  Whatever you just fixed is NOT on the device. Deploy it:"
	echo "    RADIO=$RADIO sh tools/deploy.sh"
	exit 1
fi

if [ -n "$lgot" ] && [ "$lwant" != "$lgot" ]; then
	echo "FAIL: build numbers agree ($tree) but the FILES DIFFER."
	echo "  local  : $lwant"
	echo "  device : $lgot"
	echo "  The applet was edited after it was deployed. The build number is stale,"
	echo "  which is worse than a mismatch -- it reads as up to date."
	exit 1
fi

echo "check-deployed: ok (device and tree are both build $tree, files identical)"
