#!/bin/sh
# SBRadioEQ -- prove check-footprint.sh can actually fail.
#
#   sh tools/test-check-footprint.sh
#
# A gate that has only ever been seen passing has not been tested. This injects
# one defect per check into a throwaway copy of the tree and asserts the gate
# catches it, then asserts the untouched copy still passes (the control).
#
# Each fixture is a REAL way the applet could come to outlive its own uninstall:
# an init script, a file write, a shell redirect, an unproven hardware control, a
# numid outside the volatile block, and -- the quiet one -- package.sh changing
# shape so the gate scans nothing and reports clean about it.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
GATE=tools/check-footprint.sh
APPLET=applet/SBRadioEQApplet.lua
EQAPPLY=lua/eqapply.lua

pass=0
fail=0

# Run the gate in a fresh copy of the tree, after applying a mutation.
#   $1 label   $2 expected exit code   $3 shell snippet run inside the copy
fixture() {
	label=$1; want=$2; mutate=$3
	tmp=$(mktemp -d)
	mkdir -p "$tmp/tools" "$tmp/lua" "$tmp/applet"
	cp "$HERE/tools/check-footprint.sh" "$tmp/tools/"
	cp "$HERE/tools/package.sh"         "$tmp/tools/"
	cp "$HERE"/lua/*.lua                "$tmp/lua/"
	cp "$HERE"/applet/*                 "$tmp/applet/"

	( cd "$tmp" && eval "$mutate" )

	got=0
	( cd "$tmp" && sh "$GATE" >"$tmp/out.txt" 2>&1 ) || got=$?

	if [ "$got" -eq 127 ]; then
		echo "  HARNESS  $label -- exit 127 is 'command not found', not a verdict"
		fail=$((fail + 1))
	elif [ "$got" -eq "$want" ]; then
		echo "  ok       $label (exit $got)"
		pass=$((pass + 1))
	else
		echo "  FAIL     $label -- expected exit $want, got $got"
		sed 's/^/             /' "$tmp/out.txt"
		fail=$((fail + 1))
	fi
	rm -rf "$tmp"
}

echo "control -- the real tree must pass:"
fixture "unmutated tree passes" 0 "true"

echo ""
echo "each check must catch its defect:"

# 1. persistence mechanism: an init script the reboot would then run forever.
fixture "init-script path is caught" 1 \
	"printf '\nlocal BOOT = \"/etc/init.d/sbradioeq\"\n' >> $APPLET"

# 1b. saved ALSA state -- the exact thing whose ABSENCE makes uninstall clean.
fixture "alsactl invocation is caught" 1 \
	"printf '\nlocal SAVE = \"alsactl store\"\n' >> $APPLET"

# 2. a direct file write, bypassing the framework settings API.
fixture "io.open write is caught" 1 \
	"printf '\nlocal fh = io.open(\"x\", \"w\")\n' >> $APPLET"

# 3. a shell redirect that creates a file with no Lua file API involved.
fixture "shell append redirect is caught" 1 \
	"printf '\nlocal C = \"amixer >> /tmp/eq.state\"\n' >> $APPLET"

# 4. a hardware control nobody has proven resets at boot.
fixture "unproven ALSA control is caught" 1 \
	"printf '\nM.EXTRA = \"Headphone Playback Volume\"\n' >> $EQAPPLY"

# 5. a numid outside the volatile effects block.
fixture "numid outside 1,21..31 is caught" 1 \
	"sed -i 's/^\tenable = 21,/\tenable = 21,\n\tstash = 44,/' $EQAPPLY"

# 6. THE QUIET ONE. If package.sh's RUNTIME block changes shape, a naive gate
#    scans an empty file list and reports clean. It must refuse to run instead.
fixture "unreadable package.sh RUNTIME aborts (does not pass)" 2 \
	"sed -i 's/^RUNTIME=\"/RUNTIME_FILES=(/' tools/package.sh"

echo ""
echo "test-check-footprint: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
