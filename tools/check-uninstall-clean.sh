#!/bin/sh
# SBRadioEQ -- prove on the DEVICE that removing the applet leaves no tone
# modification behind.
#
#   RADIO=root@192.168.50.174 EQ_UNINSTALL_TEST_ACK=1 sh tools/check-uninstall-clean.sh
#
# ⚠️  SAFETY -- READ BEFORE RUNNING. TURN THE RADIO'S VOLUME DOWN FIRST.
#
# The PASSING outcome is the loud one. A boost is realised as cut-elsewhere plus
# make-up gain folded into the player volume, so while the EQ is active the
# player volume is sitting up to ~15 dB above where the user set it. This test
# removes the applet and reboots. If the codec resets as it should, the cut
# disappears and that elevated volume is left over unattenuated audio.
#
# Turn the volume down, stop playback, and only then run this. The script refuses
# to start without EQ_UNINSTALL_TEST_ACK=1 to make that a deliberate act.
#
# WHAT THIS PROVES, AND WHY NOTHING CHEAPER DOES.
#
# The Applet Installer has no uninstall hook -- removal is a raw filesystem
# delete (SetupAppletInstallerApplet.lua:420-445) and the applet's code is never
# called. Cleanup at removal time is not merely unimplemented, it is impossible.
# "Uninstall is clean" therefore rests entirely on the codec registers being
# volatile and the installer's forced reboot clearing them.
#
# That is an achievement claim about hardware. tools/check-footprint.sh is a
# static guard: it proves no NEW persistence mechanism was added to the source.
# It cannot prove the chip still resets. Only removing the applet, rebooting, and
# reading the registers back proves that -- which is what this does.
#
# It reboots the device twice and restores the applet afterwards, including on
# failure or interrupt.

set -e

RADIO="${RADIO:?set RADIO, e.g. RADIO=root@192.168.50.174 -- no default: a wrong
       default reboots somebody else's device}"

if [ "$EQ_UNINSTALL_TEST_ACK" != "1" ]; then
	cat <<'WARN'
REFUSING TO RUN.

This removes the EQ applet and reboots the Radio. If the codec resets as
expected, the make-up gain folded into the player volume is left applied to
unattenuated audio -- the device gets LOUD.

TURN THE RADIO'S VOLUME DOWN AND STOP PLAYBACK. Then re-run with:

    EQ_UNINSTALL_TEST_ACK=1
WARN
	exit 2
fi

# ⛔ EVERY ssh GETS A HARD TIMEOUT, and ConnectTimeout is not one.
#
# ConnectTimeout bounds the TCP connect only. An ssh that connects and then
# blocks waiting for a password hangs forever -- which is exactly what happens
# when the askpass helper is not reachable, e.g. when this script runs detached
# from a terminal. Observed: this script sat for ten minutes at "waiting for
# boot" while the Radio was up and answering a separate connection normally.
# Without the wrapper below, the failure mode is an invisible stall that leaves
# the device stripped of its applet.
SSH="timeout ${SSH_TIMEOUT:-60} ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $SSH_EXTRA"

APPLETDIR=/usr/share/jive/applets/SBRadioEQ
PARKED=/root/SBRadioEQ.uninstalltest

# Every register the applet can touch: the enable bit, both biquads, and the
# mute control. All must come back at driver defaults.
NUMIDS="1 21 22 23 24 25 26 27 28 29 30 31"

read_regs() {
	$SSH -n "$RADIO" "for n in $NUMIDS; do printf 'numid=%s %s\n' \$n \"\$(amixer -c 0 cget numid=\$n 2>/dev/null | tail -1 | tr -d ' ')\"; done"
}

wait_for_boot() {
	i=0
	while [ "$i" -lt 30 ]; do
		# Its own shorter hard timeout: 30 probes at the 60 s default would be
		# half an hour of silence before this loop admitted defeat.
		if timeout 15 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
			$SSH_EXTRA -n "$RADIO" "true" 2>/dev/null; then return 0; fi
		i=$((i + 1))
	done
	echo "FAIL: the Radio did not come back after $i attempts"
	return 1
}

# The applet MUST be put back, whatever happens from here -- including Ctrl-C.
# A test that leaves the device stripped is worse than no test.
restore() {
	echo ""
	echo "restoring the applet..."
	$SSH -n "$RADIO" "[ -d $PARKED ] && mv $PARKED $APPLETDIR && echo '  restored' || echo '  nothing parked -- already in place'" || \
		echo "  ⛔ RESTORE FAILED -- the applet is at $PARKED on the device; move it back by hand"
	$SSH -n "$RADIO" "sync; (sleep 1; reboot) >/dev/null 2>&1 &" >/dev/null 2>&1 || true
	echo "  rebooting so configureApplet re-applies the saved curve"
}
trap restore EXIT INT TERM

fail=0
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
ok()  { echo "  ok    $1"; }

echo "=== 1. the EQ must be ACTIVE, or the test proves nothing ==="
enable=$($SSH -n "$RADIO" "amixer -c 0 cget numid=21 | tail -1 | tr -dc '0-9'")
if [ "$enable" = "0" ]; then
	echo "FAIL: the effects filter is already bypassed (numid=21=0)."
	echo "      Set a curve with some gain first -- removing an applet that is"
	echo "      not filtering anything cannot show that removal clears filtering."
	exit 2
fi
ok "effects filter is on (numid=21=$enable)"

echo ""
echo "=== 2. snapshot the active state ==="
BEFORE=$(mktemp); AFTER=$(mktemp)
read_regs > "$BEFORE"
sed 's/^/  /' "$BEFORE"

echo ""
echo "=== 3. remove the applet exactly as the installer does ==="
$SSH -n "$RADIO" "mv $APPLETDIR $PARKED && echo '  moved aside'"
$SSH -n "$RADIO" "ls -d $APPLETDIR 2>/dev/null && echo '  ⛔ still present' || echo '  confirmed absent'"

echo ""
echo "=== 4. reboot (the installer reboots too) ==="
$SSH -n "$RADIO" "sync; (sleep 1; reboot) >/dev/null 2>&1 &" >/dev/null 2>&1 || true
wait_for_boot
ok "device is back"

echo ""
echo "=== 5. read the registers with the applet gone ==="
read_regs > "$AFTER"
sed 's/^/  /' "$AFTER"

echo ""
echo "=== 6. verdict ==="

# THE assertion. Everything else is supporting detail: with the enable bit clear
# the filter is out of the signal path whatever the coefficients hold.
after_enable=$(grep '^numid=21 ' "$AFTER" | tr -dc '0-9' | sed 's/^21//')
if [ "$after_enable" = "0" ]; then
	ok "effects filter is OFF after removal (numid=21: $enable -> 0)"
else
	bad "effects filter is STILL ON after removal (numid=21=$after_enable)"
	echo "        the applet is gone and the device is still filtering audio,"
	echo "        with nothing left on it to change that. DO NOT DISTRIBUTE."
fi

if diff -q "$BEFORE" "$AFTER" >/dev/null 2>&1; then
	bad "every register survived the reboot unchanged"
else
	ok "registers reset (differ from the active-EQ snapshot)"
fi

# The applet must not have been resurrected by something we did not know about.
$SSH -n "$RADIO" "ls -d $APPLETDIR >/dev/null 2>&1" && \
	bad "the applet directory came back on its own -- something reinstalls it" || \
	ok "applet still absent after the reboot"

rm -f "$BEFORE" "$AFTER"

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-uninstall-clean: $fail problem(s) -- removal does NOT leave the device clean"
	exit 1
fi
cat <<'DONE'
check-uninstall-clean: removal leaves no tone modification

RESIDUAL, deliberately accepted and NOT tested here:
  * the player volume keeps whatever make-up gain was folded into it. The user
    can turn it down; they cannot undo a filter with no app left to control it,
    which is why that one is the gate and this one is a note.
  * /etc/squeezeplay/userpath/settings/SBRadioEQ.lua is orphaned. Inert data.
DONE
