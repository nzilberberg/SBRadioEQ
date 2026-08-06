#!/bin/sh
# SBRadioEQ -- record what the Radio ACTUALLY puts out, not what we designed.
#
#   RADIO=root@<ip> sh tools/listen.sh <seconds> [outfile.wav]
#
# ⛔ NEEDS A CABLE. 3.5 mm male-male from the Radio's HEADPHONE OUT to its LINE
# IN. Without it this records the line-in's noise floor and proves nothing --
# which is why the analysis below reports the captured level unconditionally
# instead of only complaining when it finds something. A silent capture must be
# distinguishable from a capture that was never connected.
#
# WHY THIS EXISTS
#
# The applet's black box (_check in SBRadioEQApplet) records the DESIGN when a
# threshold is crossed: "this curve would realise above 0 dB". That is a
# statement about arithmetic. It is NOT evidence that the chip did anything, and
# when the owner reported a loud crack and a half-second high-pitched burst the
# most that could honestly be said was "a clipping setting was loaded around
# then". Inference, not observation.
#
# There is no way to ask the codec. Measured on-device 2026-08-05: no mixer
# control reports overflow, saturation or clipping (77 controls, none of them);
# there is no /dev/i2c*, no i2c-tools, and no debugfs, so the AIC3104's own
# registers are unreachable. The chip cannot be interrogated.
#
# What IS available is the Radio's ADC. It records at 44.1k/16/stereo (verified).
# Loop the output back into it and the output becomes observable -- the only
# instrument on this device that can see an artefact rather than predict one.
#
# THE MEASUREMENT THAT SETTLES IT
#
# Play a single steady sine into the EQ and capture the analogue output. The
# source contains ONE frequency. Anything else in the recording was added by the
# device: a crack is a broadband transient, a squee is a tone that is not the one
# being played. Neither can be confused with programme material, because there is
# no programme material -- just one tone whose frequency you chose.
#
# That is a stronger test than recording music and comparing, and it needs no
# reference copy of the stream.
#
# ⛔ AUDIO SAFETY. This script does NOT play anything and does NOT touch the
# volume, deliberately. Starting playback or raising a level on a device someone
# may be wearing headphones on is not a thing a tool should do by itself. Set the
# level by hand, at the Radio, before running this.

set -e

RADIO="${RADIO:?set RADIO=root@<your-radio-ip> -- no default}"
SECS="${1:?usage: RADIO=root@<ip> sh tools/listen.sh <seconds> [outfile.wav]}"
OUT="${2:-capture.wav}"

case "$SECS" in
	''|*[!0-9]*) echo "FAIL: <seconds> must be a whole number"; exit 2 ;;
esac
if [ "$SECS" -gt 60 ]; then
	echo "FAIL: $SECS s is more than this is for. The Radio writes into /tmp, which"
	echo "      is RAM on a 62 MB box -- 60 s of 44.1k stereo is already 10 MB."
	exit 2
fi

SSHOPT="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
SSH="timeout ${SSH_TIMEOUT:-120} ssh $SSHOPT"
SCP="timeout ${SSH_TIMEOUT:-120} scp -O $SSHOPT"
REMOTE=/tmp/sbradioeq-listen.wav

# The device is single-core. A capture competing with a bench sweep drops frames
# and the dropouts look exactly like the artefact being hunted.
jives=$($SSH -n "$RADIO" "pidof jive | wc -w" 2>/dev/null || echo "?")
if [ "$jives" != "1" ]; then
	echo "REFUSING: $jives jive processes are running (expected 1, SqueezePlay)."
	echo "  A capture taken while this box is loaded drops frames, and a dropout"
	echo "  is indistinguishable from the click this tool exists to find."
	exit 3
fi

echo "recording ${SECS}s from the Radio's line-in..."
$SSH -n "$RADIO" "rm -f $REMOTE; arecord -D hw:0,0 -f S16_LE -r 44100 -c 2 -d $SECS $REMOTE" \
	>/dev/null 2>&1 || { echo "FAIL: arecord did not complete"; exit 2; }

$SCP "$RADIO:$REMOTE" "$OUT" >/dev/null || { echo "FAIL: could not retrieve the capture"; exit 2; }
$SSH -n "$RADIO" "rm -f $REMOTE" >/dev/null 2>&1 || true

bytes=$(wc -c < "$OUT")
echo "captured $bytes bytes -> $OUT"

# 44 bytes of WAV header; 4 bytes per stereo frame.
frames=$(( (bytes - 44) / 4 ))
want=$(( SECS * 44100 ))
if [ "$frames" -lt $(( want * 9 / 10 )) ]; then
	echo "WARNING: got $frames frames, expected about $want -- the capture is SHORT."
	echo "  Short captures mean dropped frames. Do not read artefacts out of this file."
fi

echo ""
echo "next: analyse it with"
echo "  sh tools/listen-analyse.sh $OUT"
echo ""
echo "⛔ If the level comes back at the noise floor, the CABLE is not connected --"
echo "   that is not a clean result, it is no result."
