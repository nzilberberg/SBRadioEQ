#!/bin/sh
# SBRadioEQ -- prove check-settings-unchanged.sh can actually fail.
#
#   sh tools/test-settings-guard.sh
#
# The fixture is the REAL incident, byte for byte: the settings before driving
# the UI, and the settings afterwards, where a stray scroll had moved bassGain
# 13.5 -> 11.0 (five 0.5 dB steps) and appliedAtten with it.
#
# A guard that has only ever been seen passing has not been tested.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
GATE="$HERE/tools/check-settings-unchanged.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
	label=$1; want=$2; shift 2
	got=0
	sh "$GATE" "$@" >"$TMP/out.txt" 2>&1 || got=$?
	if [ "$got" -eq 127 ]; then
		echo "  HARNESS  $label -- exit 127 is 'command not found', not a verdict"
		fail=$((fail + 1))
	elif [ "$got" -eq "$want" ]; then
		echo "  ok       $label (exit $got)"
		pass=$((pass + 1))
	else
		echo "  FAIL     $label -- expected $want, got $got"
		sed 's/^/             /' "$TMP/out.txt"
		fail=$((fail + 1))
	fi
}

# The real incident.
cat > "$TMP/before.lua" <<'EOF'
settings = {enabled=true,bassGain=13.5,trebGain=0,trebFreq=3118,trebQ=1.4,appliedAtten=14.306666666665,bassQ=1.5,bassFreq=194,}
EOF
cat > "$TMP/after_changed.lua" <<'EOF'
settings = {enabled=true,bassGain=11,trebGain=0,trebFreq=3118,trebQ=1.4,appliedAtten=11.346666666665,bassQ=1.5,bassFreq=194,}
EOF
cp "$TMP/before.lua" "$TMP/after_same.lua"

# A single-key change -- the smallest real mutation, e.g. one knob click.
sed 's/bassQ=1.5/bassQ=1.45/' "$TMP/before.lua" > "$TMP/after_oneclick.lua"

: > "$TMP/empty.lua"

echo "control -- an untouched run must pass:"
check "identical files pass" 0 "$TMP/before.lua" "$TMP/after_same.lua"

echo ""
echo "the guard must catch a mutation:"
check "the REAL incident is caught"        1 "$TMP/before.lua" "$TMP/after_changed.lua"
check "a single 0.05 Q click is caught"    1 "$TMP/before.lua" "$TMP/after_oneclick.lua"

echo ""
echo "absence must not read as 'unchanged':"
check "missing after-file fails"  2 "$TMP/before.lua" "$TMP/nope.lua"
check "missing before-file fails" 2 "$TMP/nope.lua"  "$TMP/after_same.lua"
check "empty file fails"          2 "$TMP/before.lua" "$TMP/empty.lua"

echo ""
echo "it must NAME the keys that moved, not just say something changed:"
sh "$GATE" "$TMP/before.lua" "$TMP/after_changed.lua" > "$TMP/report.txt" 2>&1 || true
if grep -q 'bassGain' "$TMP/report.txt" && grep -q 'appliedAtten' "$TMP/report.txt"; then
	echo "  ok       report names bassGain and appliedAtten"
	pass=$((pass + 1))
else
	echo "  FAIL     report does not name the changed keys"
	sed 's/^/             /' "$TMP/report.txt"
	fail=$((fail + 1))
fi
if grep -q '13.5' "$TMP/report.txt" && grep -q '11' "$TMP/report.txt"; then
	echo "  ok       report shows the before -> after values"
	pass=$((pass + 1))
else
	echo "  FAIL     report does not show the values"
	fail=$((fail + 1))
fi

echo ""
echo "test-settings-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
