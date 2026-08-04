#!/bin/sh
# Fixture test for check-device-transport.sh.
#
# A gate is worthless until it has been shown to BITE on a broken fixture and to
# STAY SILENT on a correct one. Both directions matter: a gate that never fires
# certifies nothing, and a gate that fires on correct code gets switched off.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/check-device-transport.sh"
[ -f "$GATE" ] || { echo "missing $GATE" >&2; exit 2; }

pass=0
fail=0

# run <expected-exit> <label>   (fixture dir is $TMP)
run() {
	exp="$1"; label="$2"
	sh "$GATE" "$TMP" >/dev/null 2>&1
	got=$?
	if [ "$got" -eq "$exp" ]; then
		echo "  ok    $label (exit $got)"
		pass=$((pass + 1))
	else
		echo "  FAIL  $label -- expected exit $exp, got $got"
		echo "        ---- gate output ----"
		sh "$GATE" "$TMP" 2>&1 | sed 's/^/        /'
		fail=$((fail + 1))
	fi
}

fresh() { rm -rf "$TMP"; mkdir -p "$TMP"; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

echo "check-device-transport fixtures:"

# --- must PASS -----------------------------------------------------------
fresh
cat > "$TMP/good.sh" <<'EOF'
SSH="timeout 30 ssh -o PreferredAuthentications=password -o StrictHostKeyChecking=no"
SCP="timeout 30 scp -O -o StrictHostKeyChecking=no"
timeout 25 ssh -o PreferredAuthentications=password root@1.2.3.4 "uptime"
EOF
run 0 "correct transport is silent"

# The false-positive guard: printing an example is not invoking one.
fresh
cat > "$TMP/help.sh" <<'EOF'
echo "          scp -O \"$BEFORE\" $RADIO:/etc/settings.lua"
# an ssh/scp line inside a comment is not an invocation
EOF
run 0 "printed/commented examples do not red the gate"

# --- must FAIL -----------------------------------------------------------
fresh
cat > "$TMP/keyonly.sh" <<'EOF'
timeout 25 ssh -o BatchMode=yes root@1.2.3.4 "uptime"
EOF
run 1 "key-only auth (BatchMode) is caught"

fresh
cat > "$TMP/notimeout.sh" <<'EOF'
SSH="ssh -o StrictHostKeyChecking=accept-new"
EOF
run 1 "ssh with no hard timeout is caught"

fresh
cat > "$TMP/connecttimeout.sh" <<'EOF'
SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
EOF
run 1 "ConnectTimeout alone does NOT satisfy the timeout rule"

fresh
cat > "$TMP/noO.sh" <<'EOF'
timeout 30 scp /tmp/x root@1.2.3.4:/tmp/x
EOF
run 1 "scp without -O is caught"

# --- must refuse to report clean on an empty scan ------------------------
fresh
run 2 "empty directory exits 2, not 0"

echo ""
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
