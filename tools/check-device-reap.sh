#!/bin/sh
# SBRadioEQ -- a script that runs jive over ssh must reap what it strands.
#
#   sh tools/check-device-reap.sh
#
# ⛔⛔ A LOCAL `timeout` BOUNDS THE SSH CLIENT, NOT THE REMOTE PROCESS.
#
# `timeout 540 ssh root@radio "jive sweep"` kills ssh. The `jive` on the other
# end keeps running with nobody reading it, and the Radio has NO `timeout`
# command of its own (see check-no-detached-device.sh) so nothing over there
# stops it either.
#
# WHY THIS IS A SPIRAL AND NOT JUST LITTER. Each orphan burns the single 360 MHz
# core. That makes the next run slower, which makes IT likelier to time out,
# which strands another orphan. Measured 2026-08-05: three stacked sweeps --
# 12m44s, 5m28s and 44s of CPU with no listener -- drove the load average to 3.29
# on a one-core box. An agent spent NINETY MINUTES inside that spiral, correctly
# noticing runs were slow and launching them "one at a time to isolate the slow
# one", each isolation run adding another orphan. It was not stalled and not
# looping; it was starving the device it was measuring, and every number it took
# in that state was worthless.
#
# WHY A GATE AND NOT A RULE. bench.sh ALREADY refused to run on a busy device --
# but only inside its `--framework` branch, and the plain path is what sweeps
# use. A guard on the branch nobody takes is not a guard. Committed enforcement
# is the only kind that survives the next script.
#
# THE RULE. Any committed script that runs `jive` on the device through a
# bounded ssh must, on a non-zero exit:
#   1. have captured `pidof jive` BEFORE the run, and
#   2. kill only the difference -- the PIDs that appeared during ITS run.
#
# ⛔ REAP BY SET SUBTRACTION, NEVER BY NAME. `pkill jive` / `killall jive` take
# down SqueezePlay: it is always in that set, and jive_alsa sits next to it. A
# gate that accepted kill-by-name would bless a script that kills the player.

set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
fail=0

# Comment-stripped view. This gate's own prose says "pidof jive" and "kill -9"
# several times over; matching on a file's comments would let a script pass by
# EXPLAINING the reap it does not perform. Sibling gates in this tree have been
# fooled by exactly that -- twice by their own headers.
strip() { sed 's/#.*//' "$1"; }

# Scripts that actually run jive on the device: an ssh invocation naming jive, in
# CODE. deploy.sh restarts SqueezePlay rather than running a script under it, so
# it is matched here only if it ever starts one.
CANDIDATES=""
for f in "$HERE"/tools/*.sh; do
	case "$(basename "$f")" in
		check-*|test-check-*) continue ;;      # gates do not touch the device
	esac
	code=$(strip "$f")
	if printf '%s\n' "$code" | grep -Eq '(ssh|SSH|SSH_RUN)[^|]*jive'; then
		CANDIDATES="$CANDIDATES $f"
	fi
done

# ⛔ VACUOUS PASS. If the discovery above matches nothing -- a rename, a refactor,
# a changed quoting style -- this gate would check zero files and report success
# about it. That failure mode is silent and is exactly how a gate rots. There is
# at least bench.sh and run-suite.sh; fewer than two means discovery broke.
n=$(printf '%s\n' $CANDIDATES | grep -c . || true)
if [ "$n" -lt 2 ]; then
	echo "FAIL: found $n script(s) running jive over ssh; expected at least"
	echo "      bench.sh and run-suite.sh. The DISCOVERY is broken, not the tree --"
	echo "      fix the match before trusting a pass from this gate."
	exit 1
fi

#[[ THE EXEMPTION, AND WHY ONE IS NEEDED.
#
# deploy.sh kills every jive BY NAME on purpose -- stopping SqueezePlay is part
# of deploying, not an accident. A blanket "never kill by name" rule is a real
# FALSE POSITIVE on it, and a gate that cries wolf is one that gets switched off.
#
# So the exemption is explicit, per-file, and must carry its reasoning IN the
# file: a line containing REAP-EXEMPT followed by at least MIN_REASON characters
# saying why. That keeps the escape hatch visible in review and stops it being
# used as a shrug. A marker with no reason is rejected exactly like no marker.
#]]
MIN_REASON=60

for f in $CANDIDATES; do
	rel=${f#"$HERE"/}
	code=$(strip "$f")

	# The marker is read from the RAW file: it lives in a comment by design.
	marker=$(grep -h 'REAP-EXEMPT' "$f" 2>/dev/null | head -1 || true)
	reason=$(printf '%s' "$marker" | sed 's/.*REAP-EXEMPT[: ]*//')
	rlen=$(printf '%s' "$reason" | wc -c)
	exempt=0
	if [ -n "$marker" ]; then
		if [ "$rlen" -ge "$MIN_REASON" ]; then
			exempt=1
		else
			echo "FAIL: $rel carries REAP-EXEMPT with only $rlen characters of reason"
			echo "      (need $MIN_REASON). An exemption without an argument is a shrug."
			fail=1
		fi
	fi

	if [ "$exempt" -eq 1 ]; then
		continue
	fi

	# 1. The before-set must be captured.
	if ! printf '%s\n' "$code" | grep -q 'pidof jive'; then
		echo "FAIL: $rel runs jive over ssh but never captures 'pidof jive' first."
		echo "      Without the before-set there is no way to tell ITS orphan from"
		echo "      SqueezePlay, and no safe reap is possible."
		fail=1
	fi

	# 2. Something must actually be killed, and the target must be a COMPUTED
	#    set -- a bare variable, not the live output of pidof. `kill -9 $STRAY`
	#    passes; `kill -9 $(pidof jive)` is rule 3's problem, not a reap.
	if ! printf '%s\n' "$code" | grep -Eq 'kill -9[[:space:]]*\$[A-Za-z_]'; then
		echo "FAIL: $rel never reaps a COMPUTED set of PIDs. A local timeout leaves"
		echo "      the remote jive running on the device's only core, poisoning"
		echo "      every later measurement."
		fail=1
	fi

	# 3. Kill by name is worse than not killing at all.
	if printf '%s\n' "$code" | grep -Eq 'pkill[[:space:]]+(-[0-9A-Za-z]+[[:space:]]+)*jive|killall[[:space:]]+(-[0-9A-Za-z]+[[:space:]]+)*jive|\$\(pidof jive\)[^|]*kill|kill[^|]*\$\(pidof jive\)'; then
		echo "FAIL: $rel reaps jive BY NAME. SqueezePlay is always in that set and"
		echo "      jive_alsa is beside it -- this kills the player. Subtract the"
		echo "      before-set instead and kill only the difference. If the kill is"
		echo "      DELIBERATE, say so with a REAP-EXEMPT line giving the reason."
		fail=1
	fi
done

if [ "$fail" -ne 0 ]; then
	echo ""
	echo "check-device-reap: FAILED"
	exit 1
fi

echo "check-device-reap: ok ($n script(s) run jive over ssh; each captures the"
echo "  before-set and reaps only what it started)"
