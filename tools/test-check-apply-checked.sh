#!/bin/sh
# SBRadioEQ -- prove check-apply-checked.sh bites on each property it claims.
#
#   sh tools/test-check-apply-checked.sh
#
# Fixtures mutate a COPY of the real applet, one property at a time. The control
# is the real tree, which must pass now that the transaction has landed.
#
# The fixture that matters most is "log-only read". That is the state the code
# was actually in, and the FIRST version of this gate passed it -- it counted the
# log:warn line as a consumer of self.hwError. A gate that would have green-lit
# the defect it was written for is worse than no gate, so that case is pinned
# here as a permanent negative control.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
GATE=tools/check-apply-checked.sh
APPLET=applet/SBRadioEQApplet.lua

pass=0
fail=0

# $1 label   $2 expected exit   $3 shell snippet run inside the copy
fixture() {
	label=$1; want=$2; mutate=$3
	tmp=$(mktemp -d)
	mkdir -p "$tmp/tools" "$tmp/applet"
	cp "$HERE/$GATE"     "$tmp/tools/"
	cp "$HERE/$APPLET"   "$tmp/applet/"

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

echo "control:"
fixture "the real applet passes" 0 "true"

echo ""
echo "each property must be caught when removed:"

# A -- visibility. The exact pre-fix state: assigned and logged, never branched on.
fixture "log-only read of hwError is caught" 1 \
	"sed -i 's/if self\.hwError then/if false then/' $APPLET"

# B -- the unwind itself.
fixture "missing unwind is caught" 1 \
	"sed -i 's/self:_levelMatch(0)/self:_noop()/' $APPLET"

# B -- the unwind's CONDITION. Unwinding unconditionally is a guess, not a fix:
# it lowers the volume against a filter that may still be applying its cut.
# NOTE: this mutation must track the real guard's text. It silently stopped
# matching once `and not res.reconciled` was added to that line, and the fixture
# then proved nothing while still reporting a pass -- caught only because the
# gate's own suite was re-run after the change.
fixture "unconditional unwind is caught" 1 \
	"sed -i 's/if res and res\.safeBypassed and not res\.reconciled then/if true then/' $APPLET
	 sed -i 's/\" safeBypassed=\", tostring(res and res\.safeBypassed),//' $APPLET"

# C -- callers must be able to tell applied from failed.
fixture "swallowed result is caught" 1 \
	"sed -i 's/^\treturn res or {/\tif false then return {/' $APPLET"

echo ""
echo "the gate must REFUSE rather than report clean:"

fixture "renamed _applyNow aborts (does not pass)" 2 \
	"sed -i 's/^function _applyNow(self)/function _commitToHardware(self)/' $APPLET"

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
[ "$fail" -eq 0 ] || exit 1
