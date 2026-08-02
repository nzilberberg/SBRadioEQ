#!/bin/sh
# SBRadioEQ -- verified deploy.
#
#   sh tools/deploy.sh [--no-restart]
#
# "Are you sure it's pushed?" was a fair question that took a device-log dig to
# answer. The change WAS installed correctly -- md5 matched, the process had
# restarted -- but the screen had never been reopened, so it was still showing
# the previous render. Nothing in the deploy proved which build was on glass.
#
# So this does not report success from the exit code of scp. It:
#
#   1. bumps BUILD in the applet, so every deploy is distinguishable;
#   2. parse-checks the staged file BEFORE overwriting the installed one --
#      a broken applet can leave the UI unusable;
#   3. copies, then compares md5 of source and destination;
#   4. restarts, then confirms the process is NEW (different pid) and started
#      AFTER the copy landed;
#   5. prints the build number to look for on screen.
#
# Any step that cannot be verified is an error, not a warning.

set -e

# Your Radio, as user@host. Set it in the environment:
#     RADIO=root@192.168.1.50 sh tools/deploy.sh
# Deliberately no default: a hardcoded address is wrong for everyone except its
# author, and silently trying to reach a stranger's machine is worse than
# refusing to start.
RADIO="${RADIO:?set RADIO=root@<your-radio-ip>}"
DEST=/usr/share/jive/applets/SBRadioEQ
HERE=$(cd "$(dirname "$0")/.." && pwd)
APPLET="$HERE/applet/SBRadioEQApplet.lua"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=25"
SCP="scp -O -o StrictHostKeyChecking=no -o ConnectTimeout=25"

restart=yes
[ "$1" = "--no-restart" ] && restart=no

# ---- 1. bump the build number -------------------------------------------
cur=$(grep -oE '^local BUILD = [0-9]+' "$APPLET" | grep -oE '[0-9]+')
[ -n "$cur" ] || { echo "FAIL: no 'local BUILD = <n>' line in the applet"; exit 1; }
next=$((cur + 1))
sed -i.bak "s/^local BUILD = $cur\$/local BUILD = $next/" "$APPLET"
rm -f "$APPLET.bak"
echo "build $cur -> $next"

# ---- 2. parse-check the STAGED file before it replaces anything ----------
for f in "$HERE"/applet/*.lua "$HERE"/lua/*.lua; do
	$SCP "$f" "$RADIO:/tmp/$(basename "$f")" >/dev/null
done
cat > /tmp/_sbreq_check.lua <<'LUA'
local bad = 0
for _, p in ipairs({ "/tmp/SBRadioEQApplet.lua", "/tmp/SBRadioEQMeta.lua",
                     "/tmp/eqdesign.lua", "/tmp/eqapply.lua" }) do
	local f, err = loadfile(p)
	if not f then print("PARSE FAIL " .. p .. ": " .. tostring(err)); bad = bad + 1 end
end
print(bad == 0 and "PARSE OK" or "PARSE FAILED")
LUA
$SCP /tmp/_sbreq_check.lua "$RADIO:/tmp/_sbreq_check.lua" >/dev/null
if ! $SSH "$RADIO" "cd /tmp && /usr/bin/jive _sbreq_check 2>&1" | grep -q "PARSE OK"; then
	echo "FAIL: staged files do not parse -- NOT installing"
	exit 1
fi
echo "staged files parse"

# ---- 3. install EVERY staged file, then prove the bytes match ------------
#
# The list used to be hardcoded to four names. Adding uistate.lua shipped an
# applet that required a module the deploy never copied -- it parsed fine,
# because `require` is not resolved at parse time, and broke on open. Derive the
# list from the same files that were staged, so a new module cannot be missed.
names=""
for f in "$HERE"/applet/*.lua "$HERE"/lua/*.lua; do
	names="$names $(basename "$f")"
done
for n in $names; do
	$SSH "$RADIO" "cp /tmp/$n $DEST/$n" >/dev/null
done
$SSH "$RADIO" "sync" >/dev/null
echo "installed:$names"

local_md5=$(md5sum "$APPLET" | cut -d' ' -f1)
dest_md5=$($SSH "$RADIO" "md5sum $DEST/SBRadioEQApplet.lua" | cut -d' ' -f1)
if [ "$local_md5" != "$dest_md5" ]; then
	echo "FAIL: installed copy differs"
	echo "  local $local_md5"
	echo "  dest  $dest_md5"
	exit 1
fi
echo "md5 verified: $local_md5"

# ---- 3b. every module the installed code REQUIRES must be present ---------
#
# This is the check that would have caught the missing uistate.lua. Parsing
# proves the syntax; only resolving the requires proves the applet can load.
# busybox sed has no -E (it wants -r), and when the first version used -E it
# printed a usage message, produced no module list, and reported "all present" --
# a check that passed because it had done nothing. cut needs no regex flavour.
extract="grep -ohE 'applets\.SBRadioEQ\.[a-zA-Z0-9_]+' *.lua | cut -d. -f3 | sort -u"

found=$($SSH "$RADIO" "cd $DEST && $extract")
if [ -z "$found" ]; then
	echo "FAIL: could not extract any required module names."
	echo "      The applet certainly requires some, so this check is broken --"
	echo "      treating it as a failure rather than trusting an empty result."
	exit 1
fi

missing=$($SSH "$RADIO" "cd $DEST && for m in \$($extract); do [ -f \"\$m.lua\" ] || echo \"\$m\"; done")
if [ -n "$missing" ]; then
	echo "FAIL: the installed applet requires modules that are not installed:"
	for m in $missing; do echo "  applets.SBRadioEQ.$m -> $DEST/$m.lua MISSING"; done
	exit 1
fi
echo "requires resolved: $(echo $found | tr '\n' ' ')"

# ---- 4. restart, and prove the process is new ----------------------------
#
# ⛔ /etc/init.d/squeezeplay restart is "stop; start", and stop is a bare
#    `kill $(cat squeezeplay.pid)` that does not wait. start then runs while the
#    old process may still be alive, so instances ACCUMULATE. Three were found
#    running at once, and because the watchdog monitors squeezeplay.pid, the
#    stale pidfile eventually rebooted the Radio.
#
#    Two instances both driving the EQ applet also defeats the bypass bracket
#    outright: one process can re-enable the filter in the middle of the other's
#    coefficient write, which is the live-partial-filter state measured at
#    +42 dB. So a clean single instance is a CORRECTNESS requirement, not tidiness.
#
if [ "$restart" = yes ]; then
	oldpids=$($SSH "$RADIO" "pidof jive" 2>/dev/null || echo "")
	$SSH "$RADIO" "/etc/init.d/squeezeplay stop >/dev/null 2>&1" || true

	# wait for every old pid to actually die, then insist
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
		echo "FAIL: squeezeplay would not die (pids:$still) -- refusing to start another"
		exit 1
	fi

	$SSH "$RADIO" "/etc/init.d/squeezeplay start >/dev/null 2>&1" || true

	# Poll rather than sample once. A single check at 22 s reported "not running"
	# on a freshly rebooted device that was simply still coming up -- and a false
	# failure here is as bad as a false pass, because it sends you looking at the
	# wrong thing.
	newpids=""
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
		sleep 3
		newpids=$($SSH "$RADIO" "pidof jive" 2>/dev/null || echo "")
		[ -n "$newpids" ] && break
	done
	count=$(echo $newpids | wc -w)
	if [ "$count" -eq 0 ]; then
		echo "FAIL: squeezeplay is not running after start"
		exit 1
	fi
	if [ "$count" -gt 1 ]; then
		echo "FAIL: $count instances running ($newpids) -- they will fight over the codec"
		exit 1
	fi
	case " $oldpids " in
		*" $newpids "*) echo "FAIL: pid unchanged ($newpids) -- the restart did not take"; exit 1 ;;
	esac
	echo "restarted: [$oldpids] -> $newpids  (exactly one instance)"
fi

echo ""
echo "DEPLOYED build $next."
echo "The Equalizer screen does NOT survive a restart -- reopen it:"
echo "  Settings > Audio Settings > Equalizer"
echo "The status bar's bottom-right corner must read  b$next"
echo "If it reads anything else, you are looking at an older render."
