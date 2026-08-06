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

#[[ ⛔⛔ A LOCAL `timeout` DOES NOT BOUND THE REMOTE PROCESS.
#
# SSH_RUN's timeout kills the ssh CLIENT. The remote command keeps going, and the
# Radio has no `timeout` of its own to stop it. Here that is worse than a single
# stranded process: the remote command is a LOOP, so after the client is gone the
# device carries on starting jive after jive with nobody reading a word of it, on
# one 360 MHz core.
#
# Measured in tools/bench.sh's sibling of this bug (2026-08-05): three orphaned
# runs drove the load average to 3.29 and every measurement taken in that state
# was worthless -- the same hazard the --framework busy-check refuses to time
# through. The orphans are invisible from here; nothing fails, results just get
# slower and then wrong.
#
# Record the PIDs first and subtract afterwards. Killing by name takes down
# SqueezePlay, which is pid 1 of the set and always running.
#]]
#[[ ⛔ VERIFY WHAT ARRIVED. A SILENT SCP IS NOT A DELIVERY.
#
# Same reasoning as tools/bench.sh: deploy.sh has always checksummed its staged
# files, this path never did, and it copies into a SHARED /tmp. A suite that runs
# a stale module prints passes for code that is not in the tree -- which is worse
# than a failure, because it is a green light for something never tested.
#]]
# ⛔ ONE ROUND TRIP, NOT ONE PER FILE. The first version of this ran an ssh per
# file -- 28 password-authenticated connections to a 360 MHz box -- and pushed the
# suite past ten minutes on its own. A verification step slow enough to be skipped
# protects nothing; the check has to be cheap enough that nobody is tempted to
# turn it off.
remote_sums=$($SSH "$RADIO" "cd $REMOTE 2>/dev/null && md5sum *.lua 2>/dev/null" || true)
mismatch=0
for f in "$HERE"/lua/*.lua "$HERE"/test/*.lua; do
	b=$(basename "$f")
	want=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
	got=$(printf '%s\n' "$remote_sums" | awk -v n="$b" '$2 == n || $2 == "*"n { print $1; exit }')
	if [ -z "$want" ] || [ -z "$got" ] || [ "$want" != "$got" ]; then
		echo "FAIL(2): $b did not arrive intact (local=${want:-?} device=${got:-missing})"
		mismatch=1
	fi
done
if [ "$mismatch" -ne 0 ]; then
	echo "  Refusing to run: a suite that measures files other than the ones you"
	echo "  edited reports passes for code that is not in the tree."
	exit 2
fi

PRE_JIVE=$($SSH "$RADIO" "pidof jive" 2>/dev/null || true)

#[[ ⛔ KILLING jive IS NOT ENOUGH HERE -- KILL THE SHELL DRIVING THE LOOP.
#
# Measured 2026-08-05, the hard way: after this run was interrupted, killing the
# running jive simply let the remote `for` loop start the NEXT test. A second
# kill, a third jive. The loop is the orphan; each jive is only its current
# child, and reaping children of a live loop is an infinite game.
#
# So the remote shell records its own pid before it starts iterating, and the
# reap kills THAT first. Everything else follows from it.
#]]
LOOPPID="$REMOTE/loop.pid"
echo "running in $REMOTE on $RADIO"
RUN_RC=0
out=$($SSH_RUN "$RADIO" "echo \$\$ > $LOOPPID; cd $REMOTE && for n in $WANT; do printf '%-20s ' \$n; /usr/bin/jive \$n 2>&1 | tail -1; done") || RUN_RC=$?

if [ "$RUN_RC" -ne 0 ]; then
	printf '%s\n' "$out"
	NOW_JIVE=$($SSH "$RADIO" "pidof jive" 2>/dev/null || true)
	STRAY=""
	for p in $NOW_JIVE; do
		found=0
		for q in $PRE_JIVE; do [ "$p" = "$q" ] && found=1 && break; done
		[ "$found" -eq 0 ] && STRAY="$STRAY $p"
	done
	# The loop FIRST -- while it lives it replaces every jive killed below.
	$SSH "$RADIO" "P=\$(cat $LOOPPID 2>/dev/null); [ -n \"\$P\" ] && kill -9 \$P 2>/dev/null; rm -f $LOOPPID" >/dev/null 2>&1 || true
	if [ -n "$STRAY" ]; then
		echo "reaping the remote loop and the process(es) it left behind:$STRAY"
		$SSH "$RADIO" "kill -9$STRAY" >/dev/null 2>&1 || true
	fi
	if [ "$RUN_RC" -eq 124 ]; then
		echo "FAIL(2): the run TIMED OUT after ${SUITE_TIMEOUT:-900}s (partial output above)."
		echo "  Do not simply re-run: a device that timed out once is slower next time."
	else
		echo "FAIL(2): the run itself did not complete (exit $RUN_RC)"
	fi
	exit 2
fi

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
