#!/bin/sh
# GATE: device transport must be ABLE to authenticate, and must not hang.
#
# WHY THIS EXISTS -- two failures that both masquerade as "the Radio is unreachable":
#
#   1. KEY-ONLY AUTH CAN NEVER SUCCEED HERE. The Radio has no SSH key and never
#      has -- /root/.ssh does not exist, deliberately (the zero-uninstall-footprint
#      property). A tool that asks for key-only auth can therefore only ever report
#      "no key". On 2026-08-04 that refusal was read as the blocker and several
#      turns were spent asking for a key install; the password mechanism (an
#      SSH_ASKPASS shim) had been available the whole time.
#
#   2. NO HARD TIMEOUT MEANS AN INFINITE HANG. ConnectTimeout bounds the TCP
#      connect ONLY -- not authentication. An ssh that connects and then stops at a
#      password prompt waits forever, and a detached ssh loses its askpass helper
#      and does the same. tools/check-uninstall-clean.sh states this rule in a
#      comment; deploy.sh and bench.sh broke it.
#
#   3. scp needs -O -- Dropbear has no sftp subsystem.
#
# Usage: sh tools/check-device-transport.sh [dir]
# Exit 0 = clean, 1 = violations found, 2 = cannot run.

set -u

ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 2
DIR="${1:-$ROOT/tools}"
[ -d "$DIR" ] || { echo "check-device-transport: no such dir: $DIR" >&2; exit 2; }

SELF=$(basename "$0")
TESTSELF="test-$SELF"

# Split so this gate does not match its own source when scanning.
KEYONLY="Batch""Mode"

# Lines that are comments, or that merely PRINT an example command, are not
# invocations. Without this a help string like `echo "  scp -O ..."` reddens the
# gate on correct code -- and a gate that fires on correct code gets switched off.
NOISE='^[0-9]+:[[:space:]]*(#|echo|printf|:[[:space:]]*")'

scanned=0
fail=0

for f in "$DIR"/*.sh; do
	[ -f "$f" ] || continue
	b=$(basename "$f")
	[ "$b" = "$SELF" ] && continue
	[ "$b" = "$TESTSELF" ] && continue
	scanned=$((scanned + 1))

	# --- 1. key-only auth ------------------------------------------------
	hits=$(grep -n "$KEYONLY" "$f" | grep -vE "$NOISE" || true)
	if [ -n "$hits" ]; then
		echo "FAIL $b: requests key-only auth; the Radio has no key, so this can never authenticate"
		printf '%s\n' "$hits" | sed 's/^/          /'
		fail=1
	fi

	# --- 2. hard timeout on every ssh/scp --------------------------------
	# Require a literal `timeout ` on the same line. ConnectTimeout does not
	# satisfy this and must not be allowed to: hence the word-boundary guard.
	offend=$(grep -nE '(^|[^-_[:alnum:]])(ssh|scp)[[:space:]]' "$f" \
		| grep -vE "$NOISE" \
		| grep -vE '(^|[^[:alnum:]])timeout[[:space:]]' || true)
	if [ -n "$offend" ]; then
		echo "FAIL $b: ssh/scp without a hard 'timeout N' (ConnectTimeout is NOT one)"
		printf '%s\n' "$offend" | sed 's/^/          /'
		fail=1
	fi

	# --- 3. scp -O --------------------------------------------------------
	scpbad=$(grep -nE '(^|[^-_[:alnum:]])scp[[:space:]]' "$f" \
		| grep -vE "$NOISE" \
		| grep -vE '(^|[[:space:]])-O([[:space:]]|$)' || true)
	if [ -n "$scpbad" ]; then
		echo "FAIL $b: scp without -O (Dropbear has no sftp subsystem)"
		printf '%s\n' "$scpbad" | sed 's/^/          /'
		fail=1
	fi
done

if [ "$scanned" -eq 0 ]; then
	echo "check-device-transport: scanned 0 files -- refusing to report clean" >&2
	exit 2
fi

if [ "$fail" -eq 0 ]; then
	echo "check-device-transport: OK ($scanned files)"
	exit 0
fi

echo ""
echo "Fix: give every ssh/scp a hard timeout and use password auth:"
echo "     printf '#!/bin/sh\\necho 1234\\n' > /tmp/askpass.sh && chmod +x /tmp/askpass.sh"
echo "     export SSH_ASKPASS=/tmp/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0"
echo "     timeout 25 ssh -o PreferredAuthentications=password ..."
echo "     (export the SAME env for scp, and use scp -O)"
exit 1
