#!/bin/sh
# Prove check-commit-names-new-files.sh can fail, pass, and refuse.
#
#   sh tools/test-check-commit-names-new-files.sh
#
# The decisive fixture is the third one: it reproduces the ACTUAL 2026-08-04
# incident -- a commit that adds tools/check-device-transport.sh under a message
# about a cancel-ordering fix -- and the gate must reject it. The real HEAD, whose
# message was amended to name those files, must pass.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
GATE="$HERE/tools/check-commit-names-new-files.sh"

pass=0
fail=0

# ⛔ A temp repo must not inherit this repo's git location vars, or every git
# command below silently operates on the REAL repository instead of the fixture.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# $1 label  $2 expected exit  $3 new-file name  $4 commit message
fixture() {
	label=$1; want=$2; newfile=$3; message=$4
	tmp=$(mktemp -d)
	(
		cd "$tmp"
		git init -q .
		git config user.email t@t; git config user.name t
		echo base > base.txt
		git add base.txt
		git commit -qm "base commit"
		mkdir -p "$(dirname "$newfile")" 2>/dev/null || true
		echo "new file contents" > "$newfile"
		git add -A
		git commit -qm "$message"
	) >/dev/null 2>&1

	got=0
	( cd "$tmp" && sh "$GATE" HEAD >"$tmp/out.txt" 2>&1 ) || got=$?

	if [ "$got" -eq "$want" ]; then
		echo "  ok       $label (exit $got)"
		pass=$((pass + 1))
	else
		echo "  FAIL     $label -- expected exit $want, got $got"
		sed 's/^/             /' "$tmp/out.txt"
		fail=$((fail + 1))
	fi
	rm -rf "$tmp"
}

echo "a named new file passes:"
fixture "message names the added file" 0 "tools/check-thing.sh" \
	"Add check-thing.sh

Describes what the new gate does."

echo ""
echo "an UNNAMED new file is caught:"

# The real incident, reproduced: another session's gate swept into a commit whose
# message is entirely about something else.
fixture "the 2026-08-04 sweep is rejected" 1 "tools/check-device-transport.sh" \
	"Cancel no longer moves the volume itself; one owner for player volume

Both Back-cancel handlers performed their own player:volume() rollback
before _applyNow -- outside the PCM mute."

fixture "a plainly unrelated new file is rejected" 1 "notes/scratch.md" \
	"Fix the headroom clamp"

echo ""
echo "the gate must refuse rather than report clean:"
tmp=$(mktemp -d)
got=0
( cd "$tmp" && sh "$GATE" HEAD >/dev/null 2>&1 ) || got=$?
if [ "$got" -eq 2 ]; then
	echo "  ok       outside a git repo, aborts (exit 2)"
	pass=$((pass + 1))
else
	echo "  FAIL     outside a git repo -- expected exit 2, got $got"
	fail=$((fail + 1))
fi
rm -rf "$tmp"

got=0
( cd "$HERE" && sh "$GATE" definitely-not-a-ref >/dev/null 2>&1 ) || got=$?
if [ "$got" -eq 2 ]; then
	echo "  ok       unknown ref aborts (exit 2)"
	pass=$((pass + 1))
else
	echo "  FAIL     unknown ref -- expected exit 2, got $got"
	fail=$((fail + 1))
fi

echo ""
echo "test-check-commit-names-new-files: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
