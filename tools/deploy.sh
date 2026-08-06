#!/bin/sh
# SBRadioEQ -- verified, atomic deploy.
#
#   RADIO=root@<ip> sh tools/deploy.sh [--no-restart]
#
# A broken applet can leave the Radio's UI unusable, and a half-installed one is
# worse than either version. So nothing here reports success from an exit code:
# every step is verified, and the installed directory is only ever swapped in
# whole.
#
# ONE MANIFEST drives staging, parsing, installing, hashing and the require
# check. An earlier version derived the install list from a glob but parse-checked
# a HARDCODED FOUR NAMES -- so uistate.lua was installed without ever being
# parsed, and strings.txt was never installed at all.
#
# Any step that cannot be verified is an error, not a warning.

set -e

# Your Radio, as user@host:
#     RADIO=root@192.168.1.50 sh tools/deploy.sh
# Deliberately no default: a hardcoded address is wrong for everyone except its
# author, and silently reaching for a stranger's machine is worse than refusing.
RADIO="${RADIO:?set RADIO=root@<your-radio-ip>}"

DEST=/usr/share/jive/applets/SBRadioEQ
STAGE=/tmp/sbradioeq-stage
HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"

# REAP-EXEMPT: deploy STOPS SqueezePlay on purpose -- killing every jive by name
# is the intended act here, not a stranded-orphan cleanup, and the set-subtraction
# reap that tools/check-device-reap.sh requires of bench.sh and run-suite.sh would
# be wrong for it. The one remote script this runs, `jive _sbreq_check`, is a
# sub-second parse check, and the restart path below kills all jive afterwards
# anyway, so it cannot leave a long-lived orphan on the core.

# accept-new, not no. This writes executable Lua as root; disabling the identity
# check entirely would let anything answering on that address receive it. Trust
# on first use, then verify -- a development convenience should not silently turn
# off authentication of a root target.
SSHOPT="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=25"
# ConnectTimeout bounds the TCP connect ONLY, not authentication. The Radio has no
# SSH key (deliberately), so an ssh that connects and then stops at a password
# prompt waits FOREVER. Every call needs a hard timeout as well. Override with
# SSH_TIMEOUT= if a legitimately slow step needs longer.
SSH="timeout ${SSH_TIMEOUT:-180} ssh $SSHOPT"
SCP="timeout ${SSH_TIMEOUT:-180} scp -O $SSHOPT"

#[[ ---- --stage-only ---------------------------------------------------------
#
# ⛔ SWAPPING THE DIRECTORY UNDER A LIVE JIVE GIVES A MIXED-VERSION PROCESS.
#
# The atomic directory swap guarantees the files on DISK are never a mixture. It
# guarantees nothing about the modules already resident in the running Jive: the
# Meta and uistate are loaded at startup, while the main Applet is loaded lazily
# when the screen is first opened. Skip the restart and a later screen-open can
# pair NEW applet code with OLD state helpers in one process -- which produces
# test results that describe a build that does not exist anywhere.
#
# So the flag no longer claims to have deployed anything runnable. It stages, and
# it says plainly that the applet must not be opened until Jive restarts.
# `--no-restart` is kept as a deprecated alias so an existing habit does not
# silently do something different from what it used to.
#]]
restart=yes
stageonly=no
case "$1" in
	--stage-only|--stage-without-activating) restart=no; stageonly=yes ;;
	--no-restart)
		restart=no; stageonly=yes
		echo "note: --no-restart is now --stage-only; the applet is NOT active until you restart"
		;;
esac

# ---- the manifest -------------------------------------------------------
# Everything that belongs in the installed applet directory, once.
MANIFEST=""
for f in "$HERE"/applet/*.lua "$HERE"/applet/strings.txt "$HERE"/lua/*.lua; do
	[ -f "$f" ] && MANIFEST="$MANIFEST $f"
done
[ -n "$MANIFEST" ] || { echo "FAIL: manifest is empty"; exit 1; }

# ---- build number, rolled back if anything below fails -------------------
# A failed deploy used to consume a number anyway, so the sequence gained holes
# and "which build is on the device" got harder to answer, not easier.
cur=$(grep -oE '^local BUILD = [0-9]+' "$APPLET" | grep -oE '[0-9]+')
[ -n "$cur" ] || { echo "FAIL: no 'local BUILD = <n>' line in the applet"; exit 1; }
next=$((cur + 1))
SUCCESS=""
rollback_build() {
	[ -n "$SUCCESS" ] && return 0
	sed -i.bak "s/^local BUILD = $next\$/local BUILD = $cur/" "$APPLET" 2>/dev/null || true
	rm -f "$APPLET.bak"
	echo "  (build number rolled back to $cur)"
}
trap rollback_build EXIT

sed -i.bak "s/^local BUILD = $cur\$/local BUILD = $next/" "$APPLET"
rm -f "$APPLET.bak"
echo "build $cur -> $next"

# ---- stage ---------------------------------------------------------------
$SSH "$RADIO" "rm -rf $STAGE && mkdir -p $STAGE" >/dev/null
for f in $MANIFEST; do
	$SCP "$f" "$RADIO:$STAGE/$(basename "$f")" >/dev/null
done

# ---- parse EVERY staged .lua, from the manifest --------------------------
{
	echo "local bad = 0"
	echo "for _, p in ipairs({"
	for f in $MANIFEST; do
		case "$f" in *.lua) echo "  \"$STAGE/$(basename "$f")\"," ;; esac
	done
	echo "}) do"
	echo "  local fn, err = loadfile(p)"
	echo "  if not fn then print('PARSE FAIL ' .. p .. ': ' .. tostring(err)); bad = bad + 1 end"
	echo "end"
	echo "print(bad == 0 and 'PARSE OK' or 'PARSE FAILED')"
} > /tmp/_sbreq_check.lua
$SCP /tmp/_sbreq_check.lua "$RADIO:$STAGE/_sbreq_check.lua" >/dev/null
if ! $SSH "$RADIO" "cd $STAGE && /usr/bin/jive _sbreq_check 2>&1" | grep -q "PARSE OK"; then
	echo "FAIL: staged files do not parse -- nothing installed"
	exit 1
fi
$SSH "$RADIO" "rm -f $STAGE/_sbreq_check.lua" >/dev/null
echo "parsed: $(echo $MANIFEST | tr ' ' '\n' | grep -c '\.lua$') lua files"

# ---- verify the staged bytes before anything is swapped in ---------------
for f in $MANIFEST; do
	b=$(basename "$f")
	l=$(md5sum "$f" | cut -d' ' -f1)
	r=$($SSH "$RADIO" "md5sum $STAGE/$b" | cut -d' ' -f1)
	if [ "$l" != "$r" ]; then
		echo "FAIL: $b differs after upload ($l vs $r)"
		exit 1
	fi
done
echo "md5 verified: $(echo $MANIFEST | wc -w) files"

# ---- every require must resolve INSIDE the staging directory -------------
# Parsing proves syntax; only resolving the requires proves it can load.
# busybox sed has no -E (it wants -r); using it once made this check print a
# usage message, extract nothing, and report success. cut needs no regex flavour.
extract="grep -ohE 'applets\.SBRadioEQ\.[a-zA-Z0-9_]+' *.lua | cut -d. -f3 | sort -u"
found=$($SSH "$RADIO" "cd $STAGE && $extract")
if [ -z "$found" ]; then
	echo "FAIL: extracted no required module names at all -- this check is broken,"
	echo "      and an empty result must not be read as a clean one."
	exit 1
fi
missing=$($SSH "$RADIO" "cd $STAGE && for m in \$($extract); do [ -f \"\$m.lua\" ] || echo \"\$m\"; done")
if [ -n "$missing" ]; then
	echo "FAIL: staged applet requires modules that are not staged:"
	for m in $missing; do echo "  applets.SBRadioEQ.$m -> $m.lua MISSING"; done
	exit 1
fi
echo "requires resolved: $(echo $found | tr '\n' ' ')"

# ---- stop, swap, start ---------------------------------------------------
#
# ⛔ /etc/init.d/squeezeplay restart is "stop; start", and stop is a bare
#    `kill $(cat squeezeplay.pid)` that does not wait. start then runs while the
#    old process may still be alive, so instances ACCUMULATE. Three were found
#    running at once, and because the watchdog monitors that pidfile, the stale
#    entry eventually rebooted the Radio.
#
#    Two instances both driving the applet also defeats the bypass bracket: one
#    can re-enable the filter mid-write in the other, which is the live partial
#    filter measured at +42 dB. A single instance is a CORRECTNESS requirement.
#
if [ "$restart" = yes ]; then
	oldpids=$($SSH "$RADIO" "pidof jive" 2>/dev/null || echo "")

	# ⛔ stopwdog, NOT stop.
	#
	# `stop` DELETES /var/run/squeezeplay.pid. The watchdog polls that file every
	# 5 seconds (interval=5 in /etc/watchdog.conf) and treats a missing pidfile as
	# a failure -- it runs repair.sh and lets the hardware watchdog REBOOT the
	# Radio. This script holds the process down for well over 5 s while it swaps
	# the directory, so using `stop` rebooted the device on every deploy.
	#
	# `stopwdog` exists for exactly this: it stops SqueezePlay and parks a
	# `sleep 1h` pid in the pidfile so the watchdog stays satisfied while work
	# happens. The placeholder is cleared just before start, below.
	$SSH "$RADIO" "/etc/init.d/squeezeplay stopwdog >/dev/null 2>&1" || true
	$SSH "$RADIO" "
	  for i in 1 2 3 4 5 6 7 8 9 10; do
	    pidof jive >/dev/null 2>&1 || break
	    sleep 1
	  done
	  if pidof jive >/dev/null 2>&1; then
	    for p in \$(pidof jive); do kill -9 \$p 2>/dev/null; done
	    sleep 2
	  fi
	" >/dev/null 2>&1 || true
	still=$($SSH "$RADIO" "pidof jive" 2>/dev/null || echo "")
	if [ -n "$still" ]; then
		echo "FAIL: squeezeplay would not die (pids:$still) -- refusing to swap under a live process"
		exit 1
	fi
fi

# Swap the whole directory in one rename, with the previous one kept for
# rollback. Copying module-by-module over a live install can leave a
# mixed-version applet, and lazy loading could observe the mixture.
# mkdir -p handles a FRESH install, where DEST does not exist yet.
$SSH "$RADIO" "
  set -e
  mkdir -p $(dirname $DEST)
  rm -rf $DEST.new $DEST.old
  mv $STAGE $DEST.new
  if [ -d $DEST ]; then mv $DEST $DEST.old; fi
  mv $DEST.new $DEST
  sync
" >/dev/null
echo "installed atomically: $(echo $MANIFEST | wc -w) files"

if [ "$restart" = yes ]; then
	# Release the watchdog placeholder and start in one go. `start` refuses if the
	# pidfile holds a LIVING pid, and stopwdog deliberately left a `sleep 1h`
	# there -- so the placeholder must be killed first. Doing both in a single
	# remote command keeps the window where no pidfile exists sub-second, well
	# inside the watchdog's 5 s interval.
	$SSH "$RADIO" "
	  P=\$(cat /var/run/squeezeplay.pid 2>/dev/null)
	  if [ -n \"\$P\" ]; then kill \$P 2>/dev/null; fi
	  rm -f /var/run/squeezeplay.pid
	  /etc/init.d/squeezeplay start >/dev/null 2>&1
	" >/dev/null 2>&1 || true

	# Poll rather than sample once: a single check at 22 s reported "not running"
	# on a device that was simply still coming up, and a false failure sends you
	# looking at the wrong thing.
	newpids=""
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
		sleep 3
		newpids=$($SSH "$RADIO" "pidof jive" 2>/dev/null || echo "")
		[ -n "$newpids" ] && break
	done
	count=$(echo $newpids | wc -w)

	if [ "$count" -eq 0 ] || [ "$count" -gt 1 ]; then
		echo "FAIL: $count jive instances after start ($newpids) -- rolling back"
		$SSH "$RADIO" "
		  if [ -d $DEST.old ]; then rm -rf $DEST; mv $DEST.old $DEST; sync; fi
		  P=\$(cat /var/run/squeezeplay.pid 2>/dev/null)
		  if [ -n \"\$P\" ] && kill -0 \$P 2>/dev/null; then kill \$P 2>/dev/null; fi
		  rm -f /var/run/squeezeplay.pid
		  /etc/init.d/squeezeplay start >/dev/null 2>&1
		" >/dev/null 2>&1 || true
		echo "  previous version restored; check the device"
		exit 1
	fi
	case " $oldpids " in
		*" $newpids "*) echo "FAIL: pid unchanged ($newpids) -- the restart did not take"; exit 1 ;;
	esac
	echo "restarted: [$oldpids] -> $newpids  (exactly one instance)"
fi

$SSH "$RADIO" "rm -rf $DEST.old" >/dev/null 2>&1 || true

SUCCESS=1
echo ""
if [ "$stageonly" = yes ]; then
	# Do NOT call this deployed. Nothing is running the new code, and if the
	# screen is opened before a restart the process can mix old and new modules.
	echo "STAGED build $next -- NOT ACTIVE."
	echo "  The files are in place; the running Jive still holds the previous"
	echo "  modules. Do NOT open the applet until you restart, or you will be"
	echo "  testing a mixture of builds that exists nowhere else:"
	echo "    ssh <radio> /etc/init.d/squeezeplay restart"
	exit 0
fi

echo "DEPLOYED build $next."
# The menu path is DERIVED from strings.txt, not typed here. It was typed here
# once, the EQ moved one level down behind a Tone Controls menu, and this line
# went on confidently naming a path that no longer existed. A deploy script that
# tells you where to look is only useful if it cannot be wrong.
label() { sed -n "/^$1\$/{n;s/^\tEN\t//p;}" "$HERE/applet/strings.txt"; }
MENU_LABEL=$(label SBRADIOEQ_MENU)
EQ_LABEL=$(label SBRADIOEQ)

echo "The Equalizer screen does NOT survive a restart -- reopen it:"
if [ -n "$MENU_LABEL" ] && [ -n "$EQ_LABEL" ]; then
	echo "  Settings > Audio Settings > $MENU_LABEL > $EQ_LABEL"
else
	echo "  Settings > Audio Settings  (menu labels unreadable from strings.txt)"
fi
echo "The status bar's bottom-right corner must read  b$next"
echo "If it reads anything else, you are looking at an older render."
