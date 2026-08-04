#!/bin/sh
# SBRadioEQ -- prove check-apply-checked.sh can pass, fail, and refuse.
#
#   sh tools/test-check-apply-checked.sh
#
# The gate it tests is KNOWN RED on the real applet right now, which makes its
# fixtures more important than usual, not less: a gate that only ever fails is as
# unproven as one that only ever passes. Both directions are exercised here on
# synthetic applets, so the gate's verdict on the real file means something.
#
# Deliberately NOT asserted here: the real applet's exact violation count. That
# number is supposed to fall to zero as the transaction work lands, and a test
# that pins it would have to be edited by the same change it is meant to witness.
# The real tree is reported at the end as information, not as a fixture.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
GATE=tools/check-apply-checked.sh

pass=0
fail=0

# $1 label   $2 expected exit   $3 applet body (heredoc content on stdin)
fixture() {
	label=$1; want=$2
	tmp=$(mktemp -d)
	mkdir -p "$tmp/tools" "$tmp/applet"
	cp "$HERE/$GATE" "$tmp/tools/"
	cat > "$tmp/applet/SBRadioEQApplet.lua"

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

echo "the gate must PASS on code that checks the result:"

fixture "guarded persist passes" 0 <<'LUA'
function saveIt(self)
	local res = self:_flushApply()
	if res and res.ok then
		self:storeSettings()
	end
end
LUA

fixture "guard and persist on one line passes" 0 <<'LUA'
function saveIt(self)
	local res = self:_applyNow()
	if res and res.ok then self:storeSettings() end
end
LUA

fixture "an apply with no persist near it passes" 0 <<'LUA'
function _flushApply(self)
	self:_applyNow()
end
LUA

echo ""
echo "the gate must FAIL on the shapes that lose the failure:"

fixture "bare call then persist is caught" 1 <<'LUA'
function saveIt(self)
	self:_applyNow()
	self:storeSettings()
end
LUA

fixture "bare call then success log is caught" 1 <<'LUA'
function resetToDefaults(self)
	self:_applyNow()
	self:storeSettings()
	log:info("SBEQ-RESET to defaults")
end
LUA

# The one a laxer gate would wave through: the result IS captured, so it looks
# handled, but nothing ever reads it. Binding a value is not checking it.
fixture "bound-but-never-read is caught" 1 <<'LUA'
function saveIt(self)
	local res = self:_flushApply()
	self:storeSettings()
end
LUA

echo ""
echo "the gate must REFUSE rather than report clean:"

# If the calls are renamed, a scan-for-a-pattern gate finds nothing and would
# otherwise announce success about a file it did not understand.
fixture "renamed apply calls abort (do not pass)" 2 <<'LUA'
function saveIt(self)
	self:_commitToHardware()
	self:storeSettings()
end
LUA

tmp=$(mktemp -d)
mkdir -p "$tmp/tools"
cp "$HERE/$GATE" "$tmp/tools/"
got=0
( cd "$tmp" && sh "$GATE" >"$tmp/out.txt" 2>&1 ) || got=$?
if [ "$got" -eq 2 ]; then
	echo "  ok       missing applet aborts (exit 2)"
	pass=$((pass + 1))
else
	echo "  FAIL     missing applet -- expected exit 2, got $got"
	fail=$((fail + 1))
fi
rm -rf "$tmp"

echo ""
echo "test-check-apply-checked: $pass passed, $fail failed"

echo ""
real=0
( cd "$HERE" && sh "$GATE" >/dev/null 2>&1 ) || real=$?
case "$real" in
	0) echo "the real applet: CLEAN -- the transaction work has landed." ;;
	1) echo "the real applet: RED, as expected at build 42 (run the gate for the sites)." ;;
	*) echo "the real applet: gate could not run (exit $real) -- that is a harness fault." ;;
esac

[ "$fail" -eq 0 ] || exit 1
