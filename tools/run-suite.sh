#!/bin/sh
# SBRadioEQ -- run the whole test suite on the Radio, in a directory of our own.
#
#   RADIO=root@<ip> sh tools/run-suite.sh [name ...]
#
# ⛔⛔ WHY THIS EXISTS: /tmp ON THE DEVICE IS A SHARED, WRITEABLE WORKSPACE.
#
# The suite used to be driven by copying test files to /tmp and running them
# there. On 2026-08-04 a PARALLEL SESSION working on a different project (an
# OpenVPN applet) copied its own test_nospawn.lua into the same /tmp eleven
# minutes after ours landed. Our run then executed THEIR file and reported
# "test_nospawn passed=1 failed=6" against this project -- six failures that had
# nothing to do with this code, describing a policy module this repo has never
# contained.
#
# It fails in the confusing direction: the suite is red, the names look like
# ours, and the obvious conclusion is that the last change broke something.
# (The same collision most likely produced an earlier run that exited non-zero
# with no output at all.)
#
# The device timestamps were the tell -- our files at 08:25, theirs at 08:36 --
# and /tmp/openvpn.log sitting alongside them.
#
# So: a directory named for this project, wiped at the start of every run, and
# every module and test copied into it fresh. Two sessions can then use the same
# Radio without either seeing the other's files. Same class as `git add -A`
# sweeping a parallel session's work into a commit: a shared mutable workspace
# with no owner.
#
# Exit 0 all green, 1 a suite failed, 2 the run could not be set up.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
: "${RADIO:?set RADIO=root@<radio-ip>}"

# Named for the project, not for the process: a stable path is easy to inspect
# after a failure, and wiping it per run is what actually prevents the collision.
REMOTE=/tmp/sbradioeq-suite

SSHOPT="-o PreferredAuthentications=password -o StrictHostKeyChecking=no"
SSH="timeout ${SSH_TIMEOUT:-180} ssh $SSHOPT"
SCP="timeout ${SSH_TIMEOUT:-300} scp -O $SSHOPT"

# ⛔ THE RUN ITSELF NEEDS ITS OWN, MUCH LONGER BOUND. The setup calls are quick,
# but the whole suite is ~24 files against a 360 MHz core and takes minutes. The
# first version reused the 180 s setup timeout here and reported
# "the run itself did not complete" -- indistinguishable, from the output alone,
# from a device that had dropped off. Every ssh still needs SOME hard bound
# (a detached ssh waiting on auth hangs forever), so this is a bigger number,
# not an unbounded call.
SSH_RUN="timeout ${SUITE_TIMEOUT:-900} ssh $SSHOPT"

$SSH "$RADIO" "rm -rf $REMOTE && mkdir -p $REMOTE" || {
	echo "FAIL(2): could not prepare $REMOTE on $RADIO"
	exit 2
}

# Modules first, then tests and their fixtures. Derived from the tree, never a
# hand-typed list -- a suite that silently does not get copied reads as a pass.
$SCP "$HERE"/lua/*.lua "$RADIO:$REMOTE/" >/dev/null || { echo "FAIL(2): module copy failed"; exit 2; }
$SCP "$HERE"/test/*.lua "$RADIO:$REMOTE/" >/dev/null || { echo "FAIL(2): test copy failed"; exit 2; }

if [ $# -gt 0 ]; then
	WANT="$*"
else
	# ⛔ FLATTEN TO ONE LINE. `ls` yields one name per line, and the list is
	# interpolated into a remote `for n in $WANT; do` -- an embedded newline ends
	# the for statement before its `do`, and busybox reports only
	# "syntax error: unexpected word (expecting \"do\")" with no clue which
	# variable did it.
	WANT=$(cd "$HERE/test" && ls test_*.lua | sed 's/\.lua$//' | tr '\n' ' ')
fi

echo "running in $REMOTE on $RADIO"
out=$($SSH_RUN "$RADIO" "cd $REMOTE && for n in $WANT; do printf '%-20s ' \$n; /usr/bin/jive \$n 2>&1 | tail -1; done") || {
	echo "FAIL(2): the run itself did not complete"
	exit 2
}

echo "$out"

# A suite that printed nothing is not a pass. The per-line check catches a file
# that failed to load as well as one that failed its assertions.
bad=$(printf '%s\n' "$out" | grep -v 'failed=0' || true)
count=$(printf '%s\n' "$out" | grep -c 'passed=' || true)

echo ""
if [ "$count" -eq 0 ]; then
	echo "FAIL(2): no suite reported a result -- the run produced nothing to judge"
	exit 2
fi
if [ -n "$bad" ]; then
	echo "run-suite: FAILURES"
	printf '%s\n' "$bad" | sed 's/^/  /'
	exit 1
fi
echo "run-suite: $count suites, all green"
