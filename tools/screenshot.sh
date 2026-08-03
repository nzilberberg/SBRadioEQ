#!/bin/sh
# SBRadioEQ -- capture the Radio's screen, and drive its UI, over ssh.
#
#   RADIO=root@<ip> sh tools/screenshot.sh                 # just capture
#   RADIO=root@<ip> sh tools/screenshot.sh down down select # drive, then capture
#
# Writes dist/screen.raw and, on Windows, dist/screen.png via tools/fb2png.ps1.
#
# WHY THIS EXISTS. "Show me the new screen" looked impossible: the device is
# headless from here, the Screenshot applet needs a physical two-button combo,
# and the only input tool on the Radio (evtest) reads events, it does not send
# them. That reasoning was wrong, and the mistake was checking for a TOOL instead
# of testing the MECHANISM. Two mechanisms were available the whole time:
#
#   CAPTURE  /dev/fb0 is readable. 240x640 virtual, 16bpp RGB565, stride 480 --
#            a 240x320 portrait panel, double-buffered, which the UI drives
#            rotated 90 degrees CW to 320x240. pan=0,0 so the visible frame is
#            the first 153600 bytes. No applet, no key combo, no cooperation
#            from SqueezePlay at all.
#
#   INPUT    Writing a struct input_event to /dev/input/eventN injects it. On
#            32-bit ARM that struct is 16 bytes: sec(4) usec(4) type(2) code(2)
#            value(4), time left zero for the kernel to stamp.
#
# ⛔ A press and its release written in the SAME INSTANT are delivered to the
# input layer correctly -- verified by reading the events back off the node --
# and ignored by SqueezePlay. The press needs a real duration; 150 ms works.
# This cost an hour of believing injection did not work.
#
# ⛔ Capture AFTER the slide transition settles, or the frame catches two screens
# side by side mid-animation.
#
# ⛔ NEVER inject keycode 116 (KEY_POWER) or 113 (KEY_MUTE), both on event1.
#
# ⚠️  DRIVING A LIVE UI EDITS LIVE STATE. A stray scroll delivered to the EQ
# while a cell is in edit mode changes that cell -- this silently moved a saved
# bassGain by 2.5 dB (five 0.5 dB steps). Back up
# /etc/squeezeplay/userpath/settings/SBRadioEQ.lua before driving, and diff it
# after.

set -e

RADIO="${RADIO:?set RADIO=root@<your-radio-ip> -- no default}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/dist"
mkdir -p "$OUT"

SSH="timeout ${SSH_TIMEOUT:-90} ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $SSH_EXTRA"
SCP="timeout ${SSH_TIMEOUT:-90} scp -O -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $SSH_EXTRA"

# ---- the injector, written to the device ---------------------------------
$SSH "$RADIO" "cat > /tmp/inject.sh" <<'REMOTE'
#!/bin/sh
Z='\000\000\000\000\000\000\000\000'
SYN="$Z\000\000\000\000\000\000\000\000"
key() {
	printf "$Z\001\000$1\000\001\000\000\000$SYN" > "$2"
	usleep 150000
	printf "$Z\001\000$1\000\000\000\000\000$SYN" > "$2"
	usleep 250000
}
wheel() { printf "$Z\002\000\010\000$1$SYN" > /dev/input/event2; usleep 120000; }
case "$1" in
  down)   wheel '\377\377\377\377' ;;
  up)     wheel '\001\000\000\000' ;;
  select) key '\152' /dev/input/event1 ;;   # 106 KEY_RIGHT
  back)   key '\151' /dev/input/event0 ;;   # 105 KEY_LEFT
  home)   key '\146' /dev/input/event0 ;;   # 102 KEY_HOME
  *) echo "usage: inject.sh down|up|select|back|home" >&2; exit 2 ;;
esac
REMOTE

seq=""
for c in "$@"; do
	case "$c" in
		down|up|select|back|home) seq="$seq sh /tmp/inject.sh $c;" ;;
		*) echo "FAIL: unknown command '$c' (down|up|select|back|home)"; exit 2 ;;
	esac
done

SETTINGS=/etc/squeezeplay/userpath/settings/SBRadioEQ.lua

# ---- snapshot the settings BEFORE driving ---------------------------------
# Automatic, not a step anyone has to remember. The one time this was left to
# judgement, a stray scroll moved a saved bassGain by 2.5 dB and it was caught
# only because an unrelated backup happened to exist.
if [ -n "$seq" ]; then
	$SCP "$RADIO:$SETTINGS" "$OUT/settings.before.lua" >/dev/null 2>&1 || true
fi

# sleep 2 is the transition settle, not padding.
$SSH "$RADIO" "chmod +x /tmp/inject.sh; $seq sleep 2; dd if=/dev/fb0 of=/tmp/fb.raw bs=1024 count=300 2>/dev/null"
$SCP "$RADIO:/tmp/fb.raw" "$OUT/screen.raw" >/dev/null

echo "captured $OUT/screen.raw ($(wc -c < "$OUT/screen.raw") bytes)"

# ---- and prove driving did not change them --------------------------------
# Runs BEFORE the PNG is written, so a mutation cannot be buried under a
# cheerful "wrote screen.png". The exit code is deliberately propagated: a
# driving run that edited the user's tuning is a failed run.
DIRTY=0
if [ -n "$seq" ] && [ -f "$OUT/settings.before.lua" ]; then
	$SCP "$RADIO:$SETTINGS" "$OUT/settings.after.lua" >/dev/null 2>&1 || true
	echo ""
	sh "$HERE/tools/check-settings-unchanged.sh" \
		"$OUT/settings.before.lua" "$OUT/settings.after.lua" || DIRTY=$?
	echo ""
fi

if command -v powershell.exe >/dev/null 2>&1; then
	powershell.exe -NoProfile -ExecutionPolicy Bypass \
		-File "$(cygpath -w "$HERE/tools/fb2png.ps1")" \
		-Raw "$(cygpath -w "$OUT/screen.raw")" \
		-Out "$(cygpath -w "$OUT/screen.png")" >/dev/null
	echo "wrote    $OUT/screen.png"
else
	echo "(no powershell.exe -- raw only; decode RGB565 240x320, rotate 90 CW)"
fi

exit $DIRTY
