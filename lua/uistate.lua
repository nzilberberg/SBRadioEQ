--[[
SBRadioEQ -- uistate.lua

Pure UI decisions, kept out of the draw code so they can be tested.

The graph markers used to turn white when their band's cell was highlighted. The
native-skin port rewrote _redraw and silently dropped it -- the rule lived inside
a filledCircle argument, so nothing referenced it, nothing tested it, and losing
it broke no check. It came back only because the user noticed on the device.

Anything in this file is a rule about WHAT the screen should say, expressed
without reference to how it is painted: no colours, no coordinates, no jive
imports. That makes it requireable from the test bench, which cannot load the
applet (module(...) plus the whole UI stack).

The applet maps these states to colours; the tests assert the states.
]]

local M = {}

--[[
What a band's marker on the graph should look like.

  "selected"  the highlight is on one of THIS band's cells, whether the user is
              merely on it or actively editing it. Drawn white: it tells you
              which dot you are about to move, which is the question you have
              when your hand is on the knob.
  "active"    the band is doing something (gain is not zero) but the highlight
              is elsewhere. Drawn in the curve colour.
  "idle"      gain is zero, so the dot marks a band that is not affecting the
              sound. Drawn dim.

selBand is the band owning the currently highlighted cell (1 = bass,
2 = treble). Editing state deliberately does NOT appear here: a band is
"selected" in both modes, because the cell belongs to it either way.
]]
function M.markerState(selBand, band, gainDb)
	if selBand == band then return "selected" end
	if gainDb ~= 0 then return "active" end
	return "idle"
end

--[[
Moving the highlight: ONE cell per scroll event, never more.

A fast twist was skipping options. The handler applied the event's scroll value
directly -- `cell = (cell - 1 + delta) % 6 + 1` -- and a quick turn delivers a
delta bigger than 1, so the highlight jumped over cells you could never land on.

Clamping the STEP rather than debouncing on time is the right shape here. A
time debounce drops input, which reads as an unresponsive control -- the same
complaint that killed the apply-debounce earlier in this project. Clamping keeps
every event, it just makes each one worth exactly one cell. With six options
there is nothing acceleration could usefully buy.

This applies to SELECTION only. Editing a value keeps the raw delta, because
sweeping a frequency from 40 Hz to 16 kHz one step per event would be unusable.
]]
function M.selectStep(delta)
	if delta > 0 then return 1 end
	if delta < 0 then return -1 end
	return 0
end

-- Next highlighted cell, wrapping. count is the number of cells.
function M.nextCell(cell, delta, count)
	return ((cell - 1 + M.selectStep(delta)) % count) + 1
end

--[[
=============================================================================
CONTROL POLICY

These moved out of the applet so the TESTS EXERCISE PRODUCTION CODE. The
headroom and nudge tests used to reimplement this logic, because the applet
cannot be loaded outside Jive -- which meant they stayed green no matter what
the applet actually did. A test that reproduces the behaviour it is checking
proves only that the reproduction is self-consistent.
=============================================================================
]]

-- What each control can be, and how far one click moves it.
M.RANGE = {
	bassFreq = { lo = 100,  hi = 800,   kind = "freq" },
	trebFreq = { lo = 1000, hi = 16000, kind = "freq" },
	bassGain = { lo = -15,  hi = 15,    kind = "gain" },
	trebGain = { lo = -15,  hi = 15,    kind = "gain" },
	bassQ    = { lo = 0.2,  hi = 2.0,   kind = "q"    },
	trebQ    = { lo = 0.2,  hi = 2.0,   kind = "q"    },
}

--[[
One click of the knob on a value. Frequency moves proportionally (4%), gain and
Q by a fixed step; everything clamps to its range.

⚠️ `1.04 ^ delta` is parenthesised deliberately. This platform's Lua binds `^`
LOWER than `*`, so `v * 1.04 ^ delta` would compute `(v * 1.04) ^ delta`.
]]
function M.stepValue(key, v, delta)
	local r = M.RANGE[key]
	if not r then return v end

	if r.kind == "freq" then
		v = v * (1.04 ^ delta)
	elseif r.kind == "gain" then
		v = v + delta * 0.5
	else
		v = v + delta * 0.05
	end

	if v < r.lo then v = r.lo end
	if v > r.hi then v = r.hi end
	if r.kind == "freq" then v = math.floor(v + 0.5) end
	return v
end

--[[
How much make-up the volume can still give, measured from the user's own base
level: the current volume ALREADY contains appliedAtten dB of make-up, so the
ceiling is everything between here and full scale plus what is already spent.

volumeDb is the player's volume expressed in dB (negative below full scale).
]]
function M.headroomDb(appliedAtten, volumeDb)
	return (appliedAtten or 0) - (volumeDb or 0)
end

-- Can a curve costing attenDb be paid for out of budget? The tolerance absorbs
-- the last fractional dB so a step is not refused for a rounding hair.
function M.affordable(attenDb, budget)
	return (attenDb or 0) <= (budget or 0) + 0.01
end

-- Only a boost has to be afforded. A cut demands no make-up and must ALWAYS be
-- permitted, or a user who has run out of headroom is trapped at that setting.
function M.mustCheckAffordability(key, newValue, oldValue)
	local r = M.RANGE[key]
	if not r or r.kind ~= "gain" then return false end
	return newValue > oldValue
end

--[[
EDIT SNAPSHOT -- what Back restores.

Editing applies live, on every click, because that is the whole point of the
control. So "cancel" cannot mean "do not apply"; it has to mean "put back what
was there". Without this, Back merely left edit mode and the changed value was
then saved on exit -- Back read as cancel and behaved as accept.

appliedAtten is captured too: the live edits moved the player volume, and
restoring the values without restoring the level accounting leaves the volume
compensating for a curve that is no longer set.
]]
function M.snapshot(s)
	local t = {}
	for k in pairs(M.RANGE) do t[k] = s[k] end
	t.appliedAtten = s.appliedAtten
	t.enabled      = s.enabled
	return t
end

function M.restoreSnapshot(s, snap)
	if not snap then return false end
	for k, v in pairs(snap) do s[k] = v end
	return true
end

--[[
Where the VOLUME has to go when an edit is cancelled.

Restoring appliedAtten alone is not enough, and is actively wrong: appliedAtten
is bookkeeping ABOUT the player volume, not a copy of it. Live editing moves the
real volume -- drop a +15 band to 0 and the volume comes down ~15 dB to match --
so putting the number back while leaving the volume down claims 15 dB of make-up
that is not there. The curve returns and the level does not.

Undo exactly what THIS EDIT applied, rather than snapping to a remembered
volume: appliedAtten is the running total of the make-up we have added, so the
difference between now and the snapshot is our contribution and nothing else.
Anything the user did to the volume knob mid-edit is left alone, because it is
not in that difference.

All in dB; the caller converts to and from the player's own scale.
]]
function M.cancelVolumeDb(currentVolumeDb, appliedNow, appliedAtSnapshot)
	local ours = (appliedNow or 0) - (appliedAtSnapshot or 0)
	return (currentVolumeDb or 0) - ours
end

--[[
LEVEL MATCHING, as two pure steps.

THE INVARIANT, which both of this project's volume bugs broke:

    appliedAtten must always equal the make-up actually folded into the
    player's volume.

It is bookkeeping about the real volume, so anything that changes one without
the other makes it a lie, and every later decision is computed from the lie.
Both failures were that:

  * cancelling an edit restored appliedAtten but left the volume where the live
    edits had moved it;
  * bypass overwrote the curve's make-up with 0, so un-bypassing computed a
    delta of zero and never brought the volume back.

Splitting it means the arithmetic can be tested over SEQUENCES of operations
rather than one call at a time, which is where drift shows up.

Below one volume step there is nothing to gain from moving, and chasing
fractions would jitter the volume during a sweep.
]]
M.VOLUME_STEP_DB = 0.4

-- How far the volume should move, or nil when it is not worth moving.
function M.levelDelta(target, applied)
	local delta = (target or 0) - (applied or 0)
	if delta < M.VOLUME_STEP_DB and delta > -M.VOLUME_STEP_DB then return nil end
	return delta
end

--[[
What is now folded into the volume, after a move from fromDb to toDb.

Recorded from what was ACHIEVED, not what was asked for: volume steps are
0.49 dB apart above setting 25, so asking for +3.0 and getting +2.96 would drift
a little further out of true on every adjustment.
]]
function M.levelAchieved(applied, fromDb, toDb)
	return (applied or 0) + ((toDb or 0) - (fromDb or 0))
end

return M
