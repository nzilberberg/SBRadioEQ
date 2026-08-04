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

--[[
⛔ M.mustCheckAffordability WAS REMOVED 2026-08-04 -- do not reintroduce it.

It decided whether to run the headroom check from WHICH CONTROL MOVED:

    if not r or r.kind ~= "gain" then return false end
    return newValue > oldValue

so Q and frequency edits skipped the check. But Q changes the cost -- measured
on the device, both bands at +15 need 30.00 dB of make-up at Q 1.0 and 34.41 dB
at Q 2.0. An unaffordable Q step was therefore accepted, written, and reported
as applied while the output sagged.

Worse, the suite ASSERTED the hole: test_headroom carried "frequency is never
checked" and "Q is never checked" as passing expectations, so the defect had a
test defending it.

The replacement lives in the applet's _design, which compares the DESIGNED
attenDb of the candidate curve against the budget -- the quantity the guard
actually protects, rather than a proxy for it. It covers any parameter, present
or future, that changes what the curve costs. M.affordable above is still the
comparison; only the decision about WHEN to apply it moved.
]]

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
⛔ M.cancelVolumeDb WAS REMOVED 2026-08-04 -- do not reintroduce it.

It computed a volume for cancel to write DIRECTLY, and that direct write was the
v0.2.2 ordering defect: it happened before the apply transaction and therefore
outside the PCM mute, so cancelling back to a stronger curve raised the volume
before the attenuation was restored.

Cancel now writes no volume at all. It keeps the REAL appliedAtten across the
snapshot restore and lets the muted transaction reconcile the difference. There
is exactly one function permitted to write player volume -- _levelMatch -- and
check-apply-checked enforces it. A helper whose only purpose is to compute a
second volume path is the defect waiting to be re-adopted.
]]

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

--[[
THE DEFAULTS -- ONE TABLE, TWO CONSUMERS.

These are both the values a fresh install starts with (SBRadioEQMeta's
defaultSettings) and the values "Reset Tone" returns to. The user asked for
those to be the same thing, and the only way they stay the same is for there to
be one of them. A second copy in the Meta would agree on the day it was written
and drift on the day one of them was tuned.

WHERE THE NUMBERS COME FROM:

  bassFreq 150   Not a guess. The AIC3104's OWN default coefficients -- read off
                 the chip with the applet removed, so they are the driver's and
                 not ours -- decode to a low shelf hinged at ~140 Hz. That is
                 Logitech's own choice of bass corner for this exact speaker.

  trebFreq 3000  Judgement, and the weaker of the two. Nothing documents a
                 treble corner for this hardware: the Boom's tone frequencies
                 live in its closed firmware (the DAC channel is write-only,
                 there is no read path), its white paper covers bass EXTENSION
                 rather than the tone control, and its TAS3204 is a programmable
                 DSP so no datasheet defines it either.

  Q 1.0          MEASURED ceiling. A shelf overshoots above shape 1.0 and the
                 overshoot is paid for in make-up volume: a +10 dB request costs
                 10.00 dB at shape 1.0, 10.18 at 1.2 and 10.59 at 1.5. At 1.0
                 and below the cost tracks the request exactly. Do not raise it.

  gains 0        Two of the three Squeezebox Booms on the author's network sit
                 at bass 0 / treble 0. Flat is what people actually run.
]]
M.DEFAULTS = {
	enabled      = true,
	-- Level matching ON by default: without it, turning the bass up makes the
	-- music quieter, which is what the control looked broken doing before it
	-- existed. Off is the deliberate choice, not the starting point.
	levelMatch   = true,
	bassGain     = 0,
	bassFreq     = 150,
	bassQ        = 1.0,
	trebGain     = 0,
	trebFreq     = 3000,
	trebQ        = 1.0,
	-- How much make-up is folded into the player volume. Zero on a fresh
	-- install and after a reset, because the reset also takes the volume back
	-- down -- see resetToDefaults in the applet.
	appliedAtten = 0,
}

-- A FRESH copy every time. Handing out M.DEFAULTS itself would let the framework
-- store settings table alias it, and the next edit would silently rewrite the
-- defaults -- so a later reset would restore whatever was last set.
function M.defaults()
	local t = {}
	for k, v in pairs(M.DEFAULTS) do t[k] = v end
	return t
end

return M
