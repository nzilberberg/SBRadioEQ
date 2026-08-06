#!/bin/sh
# SBRadioEQ -- run a Lua script on the Radio, the ONE way that works.
#
#   RADIO=root@<ip> sh tools/bench.sh myprobe.lua            # plain
#   RADIO=root@<ip> sh tools/bench.sh myprobe.lua --framework # needs getTicks
#
# ⛔⛔ NEVER BACKGROUND DEVICE WORK. This script runs in the FOREGROUND and has
# no option to do otherwise, deliberately.
#
# A detached ssh to this box does not reliably signal completion. An agent
# backgrounded a bench sweep at 01:57, its output file was still 0 bytes seven
# hours later, and the run sat blocked the whole time waiting for a completion
# notification that never arrived. SEVEN HOURS, for a search that takes minutes.
#
# There is also no `timeout` command ON the device, so a runaway loop cannot be
# bounded from that side. Bound the work by the SIZE of the loop you write, and
# keep a single invocation well under a minute.
#
# THE TRAPS THIS SCRIPT ENCODES, each learned by losing time to it:
#
#   MODULE NAME, NOT PATH. `jive foo` takes a module name. `jive /tmp/foo.lua`
#   fails with a require traceback that looks like a missing file.
#
#   require() RESOLVES FROM THE CWD. eqdesign.lua must sit in the directory you
#   cd to, or `require("eqdesign")` fails.
#
#   jive.ui.* RESOLVES ONLY FROM /usr/share/jive. Anything needing Framework --
#   which is the only usable clock, see below -- must be copied there and run
#   there, then deleted. --framework does that and cleans up after itself.
#
#   os.clock() IS CPU TIME on this platform and reads 0.00. Framework:getTicks()
#   is the only wall clock. That is why timing work needs --framework.
#
#   jive USUALLY EXITS 0 EVEN ON A LUA ERROR -- but not always. The traceback
#   goes to stdout and the exit status is usually still success, so
#   `cmd || fallback` cannot be trusted to fire; this script scans the output
#   for a traceback instead. And because jive CAN also exit non-zero, the
#   capture below must not sit under `set -e` unprotected: the first version
#   did, died at the OUT=$(...) assignment, and printed NOTHING -- the one
#   run that most needed its output shown produced none at all.
#
# Gated by tools/check-no-detached-device.sh.

set -e

RADIO="${RADIO:?set RADIO=root@<your-radio-ip> -- no default}"
SCRIPT="${1:?usage: sh tools/bench.sh <script.lua> [--framework] [extra .lua deps...]}"
shift

[ -f "$SCRIPT" ] || { echo "FAIL: no such script: $SCRIPT"; exit 2; }

HERE=$(cd "$(dirname "$0")/.." && pwd)
NAME=$(basename "$SCRIPT" .lua)

FRAMEWORK=0
DEPS=""
for a in "$@"; do
	case "$a" in
		--framework) FRAMEWORK=1 ;;
		*.lua)       [ -f "$a" ] || { echo "FAIL: no such dep: $a"; exit 2; }
		             DEPS="$DEPS $a" ;;
		*)           echo "FAIL: unknown argument '$a'"; exit 2 ;;
	esac
done

# ConnectTimeout bounds the TCP connect ONLY, not authentication -- an ssh that
# stops at a password prompt hangs forever. Bench runs can be legitimately long,
# so the default is generous; override with SSH_TIMEOUT= for a long sweep.
SSH="timeout ${SSH_TIMEOUT:-300} ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $SSH_EXTRA"
SCP="timeout ${SSH_TIMEOUT:-300} scp -O -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 $SSH_EXTRA"

#[[ ⛔ A TIMING RUN ON A BUSY DEVICE IS WORSE THAN NO TIMING RUN.
#
# designPair was measured at 391.85 ms and reported as a 3.4x REGRESSION, and a
# change was withheld from the repo on that basis. The device was not idle: a
# backgrounded sweep was still consuming its single 360 MHz core. Re-measured on
# an idle box, the same code was 32.30 ms -- a 3.2x IMPROVEMENT. The number was
# not merely noisy, it had the wrong SIGN, and it drove a wrong decision.
#
# So --framework refuses to run when the device is busy. Refusing is the point:
# a contaminated measurement that looks plausible is the failure mode, and the
# only safe output is none.
#
# Set BENCH_MAX_LOAD to override (BENCH_MAX_LOAD=99 to force).
if [ "$FRAMEWORK" -eq 1 ]; then
	# BASELINE IS NOT ZERO: SqueezePlay runs continuously, so an idle Radio sits
	# around 0.7-1.0. A second CPU-bound job takes it past ~1.7. 1.5 divides them.
	MAXLOAD="${BENCH_MAX_LOAD:-1.5}"

	# `pidof jive` is what deploy.sh uses and it is the CRISP signal: exactly one
	# instance is SqueezePlay, a second is someone else's bench run. Load average
	# is a one-minute mean and lags a job that just started, so it is the backup.
	#
	# ⛔ `wc -w`, never `grep -c`. grep -c PRINTS 0 and EXITS 1 on no match, and
	# under `set -e` that aborted this script silently -- the first version of
	# this guard produced no output at all and looked like it had not run.
	# `|| true` on the whole probe for the same reason.
	state=$($SSH -n "$RADIO" "cut -d' ' -f1 /proc/loadavg; pidof jive | wc -w" 2>/dev/null || true)
	load=$(printf '%s\n' "$state" | sed -n 1p)
	jives=$(printf '%s\n' "$state" | sed -n 2p)

	if [ -z "$load" ] || [ -z "$jives" ]; then
		echo "FAIL: could not read the device's state -- refusing to time a box whose load is unknown"
		exit 2
	fi

	busy=$(awk -v l="$load" -v m="$MAXLOAD" 'BEGIN { print (l > m) ? 1 : 0 }')
	if [ "$busy" -eq 1 ] || [ "$jives" -gt 1 ]; then
		echo "REFUSING TO TIME: the device is busy."
		echo "  load average : $load   (limit $MAXLOAD)"
		echo "  jive processes: ${jives:-?}   (1 = just SqueezePlay)"
		echo ""
		echo "  A timing measurement taken here has been wrong by a factor of 3"
		echo "  WITH THE WRONG SIGN, and a code change was withheld because of it."
		echo "  Wait for the device to settle, or set BENCH_MAX_LOAD to override."
		exit 3
	fi
	echo "  device idle (load $load, $jives jive) -- timing is trustworthy" >&2
fi
#]]

#[[ ⛔ A DIRECTORY OF OUR OWN, NOT BARE /tmp.
#
# /tmp on the Radio is shared. A parallel session copied its own test file into
# it between our copy and our run, and we executed theirs -- see
# tools/run-suite.sh for the full account. A bench script staging under the same
# name as another project's module has exactly the same collision.
#]]
BENCHDIR=/tmp/sbradioeq-bench
$SSH -n "$RADIO" "rm -rf $BENCHDIR && mkdir -p $BENCHDIR" >/dev/null
$SCP "$SCRIPT" $DEPS "$RADIO:$BENCHDIR/" >/dev/null

#[[ ⛔⛔ A LOCAL `timeout` DOES NOT BOUND THE REMOTE PROCESS.
#
# `timeout 540 ssh ...` kills the ssh CLIENT. The `jive` on the other end keeps
# running, and the Radio has no `timeout` of its own to stop it (see the header).
# So every run that times out leaves a CPU-BOUND ORPHAN on a single 360 MHz core.
#
# THIS IS SELF-REINFORCING, which is what makes it worth a guard rather than a
# rule. Each orphan slows the next run, which makes IT more likely to time out,
# which leaves another orphan. Measured 2026-08-05: three orphaned sweeps stacked
# up (12m44s, 5m28s and 44s of CPU burned with nobody listening) and drove the
# load average to 3.29 on a one-core box. An agent spent ninety minutes inside
# that spiral, correctly noticing runs were slow and launching them "one at a
# time to isolate the slow one" -- each isolation run adding another orphan.
#
# Everything measured in that state is worthless. This is the same hazard the
# --framework busy-check already refuses to time through, but the plain path had
# no check at all, and the plain path is what sweeps use.
#
# REAP ONLY WHAT THIS RUN STARTED. The PIDs present beforehand are somebody
# else's business -- SqueezePlay itself is always among them, and a parallel
# session's bench may be too. Killing by name would take down the player.
#]]
PRE_JIVE=$($SSH -n "$RADIO" "pidof jive" 2>/dev/null || true)
pre_count=$(printf '%s' "$PRE_JIVE" | wc -w)
if [ "$pre_count" -gt 1 ]; then
	echo "bench: WARNING -- $pre_count jive processes were already running before this run." >&2
	echo "  One is SqueezePlay; the rest are orphans from an earlier timed-out run or" >&2
	echo "  another session. This device is oversubscribed and ANY measurement taken" >&2
	echo "  now is unreliable. Clear them before trusting a number." >&2
fi

# RC captured, not trusted to abort: a non-zero jive exit under `set -e` used
# to kill this script at the assignment, BEFORE the printf -- the run showed no
# output at all, exactly when the traceback mattered most.
RC=0
OUT=$(
if [ "$FRAMEWORK" -eq 1 ]; then
	# jive.ui.* only resolves from the jive tree; copy in, run, clean up. The
	# cleanup runs even on failure -- leaving files in /usr/share/jive pollutes
	# a system directory on the user's device.
	files="$BENCHDIR/$(basename "$SCRIPT")"
	for d in $DEPS; do files="$files $BENCHDIR/$(basename "$d")"; done
	$SSH -n "$RADIO" "cp $files /usr/share/jive/ && cd /usr/share/jive && jive $NAME 2>&1; rm -f $(for f in $files; do printf '/usr/share/jive/%s ' "$(basename "$f")"; done)"
else
	$SSH -n "$RADIO" "cd $BENCHDIR && jive $NAME 2>&1"
fi
) || RC=$?

printf '%s\n' "$OUT"

#[[ REAP. Any jive that appeared DURING this run and is still alive is ours and
# is now unowned -- the client that was reading it is gone. 124 is timeout(1)'s
# signal that it killed the client, which is the case that orphans; but a run
# interrupted any other way strands the remote process just as thoroughly, so
# reap on every non-zero exit.
#
# Set subtraction, not `pidof jive`: killing by name kills SqueezePlay.
#]]
if [ "$RC" -ne 0 ]; then
	NOW_JIVE=$($SSH -n "$RADIO" "pidof jive" 2>/dev/null || true)
	STRAY=""
	for p in $NOW_JIVE; do
		found=0
		for q in $PRE_JIVE; do [ "$p" = "$q" ] && found=1 && break; done
		[ "$found" -eq 0 ] && STRAY="$STRAY $p"
	done
	if [ -n "$STRAY" ]; then
		echo ""
		echo "bench: reaping remote process(es) this run started and left behind:$STRAY"
		echo "  A local timeout kills the ssh client, not the jive on the device. Left"
		echo "  alone these burn the only core and poison every later measurement."
		$SSH -n "$RADIO" "kill -9$STRAY" >/dev/null 2>&1 || true
	fi
	echo ""
	if [ "$RC" -eq 124 ]; then
		echo "bench: TIMED OUT after ${SSH_TIMEOUT:-300}s -- output above is partial."
		echo "  Shrink the sweep or raise SSH_TIMEOUT; do NOT just re-run, a device that"
		echo "  timed out once is slower on the second attempt."
	else
		echo "bench: the remote command exited $RC -- output above is everything it produced"
	fi
	exit 1
fi

# jive exits 0 even when the script threw, so the exit status is worthless.
# Detect the traceback instead and fail loudly, or a broken probe reads as a
# clean run with no output.
if printf '%s\n' "$OUT" | grep -q 'stack traceback:'; then
	echo ""
	echo "bench: the script THREW -- jive still exited 0, so do not read the above as a result"
	exit 1
fi
