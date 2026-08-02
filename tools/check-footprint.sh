#!/bin/sh
# SBRadioEQ -- assert the SHIPPED applet leaves nothing behind after uninstall.
#
#   sh tools/check-footprint.sh
#
# WHY THIS EXISTS.
#
# The Applet Installer has NO uninstall hook. Removal is a raw filesystem delete
# (SetupAppletInstallerApplet.lua:420-445 -- _remove -> _removedir -> os.remove +
# lfs.rmdir); the applet's own code is never loaded and never called. There is no
# opportunity, ever, to run cleanup at removal time.
#
# So "uninstall is clean" cannot be enforced by a teardown routine. It holds for
# exactly one reason: EVERY PERSISTENT EFFECT THE APPLET PRODUCES IS EITHER
# VOLATILE OR ON A SHORT APPROVED LIST. Removal is followed by a forced reboot
# (_finished -> callService("reboot"), taken whenever /bin/busybox exists, which
# on a Radio it does), and the reboot clears the volatile part.
#
# MEASURED 2026-08-02 on the device, applet removed, after reboot:
#
#     numid=21 (effects enable)   10 -> 0      filter OFF
#     numids 22..31 (coefficients)  all reset to driver defaults
#
# There is nothing on the device that would put them back: no /etc/asound.state,
# no /var/lib/alsa/asound.state, no /mnt/storage/etc/asound.state, and alsactl is
# not installed at all. The only writer at boot is the applet's own
# configureApplet, which removal deletes.
#
# That proof is about the code as it was that day. This gate is what keeps it
# true: it fails the moment the shipped code grows a way to persist something the
# reboot will not undo.
#
# THE APPROVED PERSISTENT FOOTPRINT -- the complete list:
#
#   1. The framework settings file, written only through getSettings/storeSettings.
#      Orphaned by removal; inert. It is data, not an effect on the device.
#   2. The player volume, moved via player:volume(). PERSISTS ACROSS UNINSTALL and
#      is the one known remnant -- accepted deliberately, because a user can turn
#      a knob. See check-uninstall-clean.sh for the residual note.
#
# Everything else the applet touches must be volatile. Anything that is not on
# that list, is not caught here, and is not cleared by the reboot, ships a defect
# to every user who ever removes the applet.
#
# THE COMPANION. This is a static gate: it proves no NEW persistence mechanism was
# introduced. It cannot prove the codec registers are still volatile -- only the
# device can, and tools/check-uninstall-clean.sh is that measurement. Run both.
#
# NOTE ON SCOPE. This scans ONLY the files that actually ship, derived from
# package.sh. Docs, tests, and this script discuss alsactl and /etc/init.d freely;
# scanning them would make the gate trip on its own vocabulary.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)

fail=0
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
ok()  { echo "  ok    $1"; }

# ---- what ships -----------------------------------------------------------
# Derived from package.sh, never re-typed. A hand-kept second copy drifts, and a
# gate that inspects a set which is not what ships is worse than none: it reports
# clean about files nobody installs.
# `|| true` is load-bearing under `set -e`: when the block cannot be parsed the
# trailing grep matches nothing, exits 1, and takes the whole script down with
# exit 1 BEFORE the guard below can say why. The failure looked like a gate
# verdict and was a dead script. Caught by the fixture, not by reading this.
RUNTIME=$(sed -n '/^RUNTIME="/,/^"$/p' "$HERE/tools/package.sh" | sed '1d;$d' | grep -v '^[[:space:]]*$' || true)

if [ -z "$RUNTIME" ]; then
	echo "FAIL: could not read the RUNTIME list out of tools/package.sh"
	echo "      (its format changed -- this gate would otherwise scan nothing"
	echo "       and report clean)"
	exit 2
fi

n=0
for f in $RUNTIME; do
	[ -f "$HERE/$f" ] || { echo "FAIL: package.sh ships $f which does not exist"; exit 2; }
	n=$((n + 1))
done
ok "scanning the $n files package.sh actually ships"

SHIPPED=""
for f in $RUNTIME; do SHIPPED="$SHIPPED $HERE/$f"; done

# ---- the literal surface --------------------------------------------------
# Checks 1 and 3 look for paths and shell fragments. Those only DO anything
# inside a string literal, so that is what gets scanned -- not the whole file.
#
# This is not fussiness. The first run of this gate failed on the word "touch"
# in the English sentence "advance the cache and touch the ...". A gate that
# fires on its own prose gets switched off, and then it defends nothing. Scan
# where the defect can actually live.
LITERALS=$(mktemp)
trap 'rm -f "$LITERALS"' EXIT
for f in $RUNTIME; do
	grep -noE "\"[^\"]*\"|'[^']*'" "$HERE/$f" 2>/dev/null | sed "s|^|$f:|" || true
done > "$LITERALS"
ok "extracted $(grep -c . "$LITERALS") string literals from the shipped code"

# ---- 1. no boot-time or system-level persistence -------------------------
# Any of these would survive the forced reboot and therefore survive uninstall.
# grep -q and branch on the exit code: `grep -c` prints 0 AND exits 1 on no
# match, which makes the absence branch unreachable and the gate always green.
echo ""
echo "persistence mechanisms:"
before=$fail
for tok in 'alsactl' 'asound\.state' '/etc/' '/var/' '/mnt/' 'crontab' 'inittab' 'rc\.local'; do
	if grep -qE "$tok" "$LITERALS"; then
		bad "a shipped string literal references '$tok' -- this can outlive uninstall"
		grep -nE "$tok" "$LITERALS" | sed 's/^/          /'
	fi
done
[ "$fail" -eq "$before" ] && ok "no boot hooks, init scripts, or saved ALSA state"

# ---- 2. no filesystem writes outside the framework settings API ----------
echo ""
echo "filesystem writes:"
before=$fail
if grep -qE 'io\.open[[:space:]]*\(' $SHIPPED 2>/dev/null; then
	bad "io.open in shipped code -- settings go through getSettings/storeSettings"
	grep -nE 'io\.open[[:space:]]*\(' $SHIPPED | sed 's/^/          /'
fi
for tok in 'os\.remove' 'os\.rename' 'lfs\.mkdir' 'lfs\.rmdir'; do
	if grep -qE "$tok" $SHIPPED 2>/dev/null; then
		bad "shipped code calls $tok -- it writes the filesystem directly"
		grep -nE "$tok" $SHIPPED | sed 's/^/          /'
	fi
done
[ "$fail" -eq "$before" ] && ok "no direct filesystem writes"

# ---- 3. every spawned command is amixer ----------------------------------
# os.execute and io.popen are legitimate here (the shell fallback and readRaw),
# but only for amixer. A shell string that redirects to a path, copies, or moves
# is how a persistent artifact gets created without any Lua file API.
echo ""
echo "spawned commands:"
before=$fail
for tok in '>>' '[^0-9a-zA-Z_]cp[[:space:]]' '[^0-9a-zA-Z_]mv[[:space:]]' '[^0-9a-zA-Z_]rm[[:space:]]' 'mkdir' '[^0-9a-zA-Z_]touch[[:space:]]'; do
	if grep -qE "$tok" "$LITERALS"; then
		bad "a shipped shell string contains '$tok' -- it can create a persistent file"
		grep -nE "$tok" "$LITERALS" | sed 's/^/          /'
	fi
done
[ "$fail" -eq "$before" ] && ok "no shell redirection or file manipulation"

# ---- 4. the ALSA control allowlist ---------------------------------------
# The exact set of hardware controls the applet is allowed to write, bound to the
# file that declares them. Every one of these was measured to reset at boot.
#
# A NEW control appearing here is not automatically wrong -- it is UNPROVEN. The
# gate fails so the question gets asked: does this control survive a reboot? Add
# it below only after check-uninstall-clean.sh says it resets.
echo ""
echo "hardware controls:"
EQAPPLY="$HERE/lua/eqapply.lua"

APPROVED=$(printf '%s\n' \
	"Audio Codec Digital Filter Control" \
	"Audio Effects Filter D1 Coefficient" \
	"Audio Effects Filter D2 Coefficient" \
	"Audio Effects Filter D4 Coefficient" \
	"Audio Effects Filter D5 Coefficient" \
	"Audio Effects Filter N0 Coefficient" \
	"Audio Effects Filter N1 Coefficient" \
	"Audio Effects Filter N2 Coefficient" \
	"Audio Effects Filter N3 Coefficient" \
	"Audio Effects Filter N4 Coefficient" \
	"Audio Effects Filter N5 Coefficient" \
	"PCM Playback Volume" \
	| sort)

# Any quoted literal shaped like an ALSA control name on this driver.
FOUND=$(grep -oE '"[^"]* (Coefficient|Control|Volume|Switch|Mux)"' "$EQAPPLY" \
	| tr -d '"' | sort -u)

if [ "$FOUND" = "$APPROVED" ]; then
	ok "writes exactly the $(printf '%s\n' "$APPROVED" | grep -c .) approved controls, all proven volatile"
else
	bad "the set of hardware controls changed"
	echo "        added (UNPROVEN -- does it survive a reboot?):"
	printf '%s\n' "$FOUND" | comm -23 - <(printf '%s\n' "$APPROVED") | sed 's/^/          + /'
	echo "        removed:"
	printf '%s\n' "$FOUND" | comm -13 - <(printf '%s\n' "$APPROVED") | sed 's/^/          - /'
	echo "        run tools/check-uninstall-clean.sh, then update APPROVED here."
fi

# ---- 5. the numids match the names ---------------------------------------
echo ""
echo "numids:"
NUMIDS=$(sed -n '/^M\.NUMID = {/,/^}/p' "$EQAPPLY" | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | sort -n -u | tr '\n' ' ')
EXPECT="1 21 22 23 24 25 26 27 28 29 30 31 "
if [ "$NUMIDS" = "$EXPECT" ]; then
	ok "numids {1, 21..31} -- the volatile effects block plus the mute control"
else
	bad "M.NUMID changed"
	echo "        found:    $NUMIDS"
	echo "        approved: $EXPECT"
	echo "        a numid outside the effects block is unproven -- measure it first."
fi

echo ""
if [ "$fail" -gt 0 ]; then
	echo "check-footprint: $fail problem(s) -- the applet may now outlive its own uninstall"
	exit 1
fi
echo "check-footprint: the shipped footprint is confined to the approved set"
