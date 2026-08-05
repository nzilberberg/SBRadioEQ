--[[
SBRadioEQ -- test_levelstate.lua       cd /tmp && jive test_levelstate

THE INVARIANT: appliedAtten must always equal the make-up actually folded into
the player's volume.

It is bookkeeping ABOUT the real volume. The moment one moves without the other,
it is a lie, and every later decision is computed from the lie. Both of this
project's volume bugs were exactly that, and both were reported from the device
rather than caught here:

  * "if I cancel the edit, the gain level comes back but without the volume
    match adjustment" -- cancel restored appliedAtten but left the volume where
    the live edits had put it.
  * bypass overwrote the curve's make-up with 0, so un-bypassing computed a
    delta of zero and never brought the volume back up.

Single-call tests missed both, because each individual call was self-consistent.
The drift only appears across a SEQUENCE. So this simulates the player volume
and drives real operation sequences through the production functions, checking
the invariant after every step.

The simulation is of the PLAYER, not of the logic under test: volume is a number
with the device's real 0-100 quantisation, and the decisions come from uistate.
]]

local U = require("uistate")
local D = require("eqdesign")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-50s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-50s %s", name, detail or "")) end
end

--[[
A simulated player + settings. `truth` tracks, independently of appliedAtten,
how much make-up this simulation has actually put into the volume -- that is the
thing appliedAtten is supposed to equal, and comparing the two is the whole test.
]]
local function newState(volume)
	return { volume = volume, applied = 0, truth = 0 }
end

local function levelMatch(st, target)
	local delta = U.levelDelta(target, st.applied)
	if not delta then return end
	local fromDb = D.volumeToDb(st.volume)
	local newVol = D.dbToVolume(fromDb + delta)
	-- The same decision production makes, from the same function, and keyed on
	-- where the move LANDS -- a move that starts above zero and clamps to it must
	-- discard its residue exactly like one that started there.
	if U.floorDiscards(delta, newVol) then
		if newVol ~= st.volume then
			st.truth  = st.truth + (D.volumeToDb(newVol) - fromDb)
			st.volume = newVol
		end
		st.applied = target
		st.truth   = target          -- the floor absorbed the rest; books agree
		return
	end
	if newVol == st.volume then return end
	local toDb = D.volumeToDb(newVol)
	st.volume  = newVol
	st.truth   = st.truth + (toDb - fromDb)          -- what really went in
	st.applied = U.levelAchieved(st.applied, fromDb, toDb)
end

local function drift(st) return math.abs(st.applied - st.truth) end

print("=== a single apply keeps the books straight ===")
do
	local st = newState(40)
	levelMatch(st, 12)
	ok("appliedAtten equals the make-up really added", drift(st) < 0.01,
	   string.format("applied %.2f, actually added %.2f, volume %d",
	                 st.applied, st.truth, st.volume))
end

print("=== a long edit sweep does not accumulate drift ===")
do
	--[[
	Volume steps are 0.49 dB apart, so each move lands slightly off what was
	asked. Recording the REQUEST instead of the ACHIEVED value would compound
	that error over a sweep.
	]]
	local st = newState(35)
	for g = 0.5, 15, 0.5 do levelMatch(st, g) end
	for g = 15, 0.5, -0.5 do levelMatch(st, g) end
	ok("no drift after 60 adjustments", drift(st) < 0.01,
	   string.format("applied %.3f vs actual %.3f", st.applied, st.truth))
end

--[[
BYPASS. Toggling off targets 0 make-up; toggling on targets the curve's own
figure again. The bug was that the curve's figure had been OVERWRITTEN with 0,
so coming back computed a delta of zero.
]]
print("=== bypass off and on returns the volume to where it started ===")
do
	local CURVE = 15.29
	local st = newState(38)
	levelMatch(st, CURVE)                     -- EQ engaged
	local engagedVol = st.volume

	levelMatch(st, 0)                          -- bypass
	local bypassedVol = st.volume
	ok("bypassing lowers the volume", bypassedVol < engagedVol,
	   string.format("%d -> %d", engagedVol, bypassedVol))
	ok("and the books still agree", drift(st) < 0.01, string.format("drift %.3f", drift(st)))

	levelMatch(st, CURVE)                      -- un-bypass
	ok("un-bypassing puts the volume BACK", math.abs(st.volume - engagedVol) <= 1,
	   string.format("%d -> %d (was %d)", bypassedVol, st.volume, engagedVol))
	ok("and the books still agree", drift(st) < 0.01, string.format("drift %.3f", drift(st)))
end

print("=== the bug that shipped: a target that never recovers ===")
do
	--[[
	NEGATIVE CONTROL. _applyNow used to do `if bypass then self.attenDb = 0 end`,
	so the curve's figure was destroyed by bypassing and un-bypass read the same
	zero. Reproduced here: the target does not come back.
	]]
	local st = newState(38)
	local curveFigure = 15.29
	levelMatch(st, curveFigure)
	local engagedVol = st.volume

	curveFigure = 0                            -- <-- the overwrite that shipped
	levelMatch(st, curveFigure)                -- bypass
	levelMatch(st, curveFigure)                -- "un-bypass", reading the same 0

	ok("the old behaviour leaves the volume down", st.volume < engagedVol,
	   string.format("stuck at %d instead of %d", st.volume, engagedVol))
	assert(st.volume < engagedVol,
	       "negative control did not reproduce the bug -- this test proves nothing")
end

--[[
CANCEL. The edit moves the volume live; cancelling has to undo exactly this
edit's contribution and restore the bookkeeping to match.
]]
print("=== cancelling an edit restores the volume, not just the number ===")
do
	local st = newState(40)
	levelMatch(st, 15.0)                       -- a +15 curve is engaged
	local beforeEdit    = st.volume
	local snapApplied   = st.applied

	-- edit the gain down to 0: the volume follows
	for g = 14.5, 0, -0.5 do levelMatch(st, g) end
	ok("editing moved the volume down", st.volume < beforeEdit,
	   string.format("%d -> %d", beforeEdit, st.volume))

	--[[
	⛔ CANCEL NO LONGER COMPUTES A VOLUME. It used to call U.cancelVolumeDb and
	write the result directly -- which happened BEFORE the apply transaction and
	therefore outside the PCM mute, the v0.2.2 ordering defect.

	The current design keeps the REAL appliedAtten across the snapshot restore and
	lets the ordinary muted transaction reconcile from there. So the cancel is
	simulated the way production does it: restore the controls, keep the real
	compensation, then run one levelMatch toward the snapshot's target.
	]]
	levelMatch(st, snapApplied)          -- the transaction reconciles, muted

	ok("the volume is back where it started", math.abs(st.volume - beforeEdit) <= 1,
	   string.format("%d (was %d)", st.volume, beforeEdit))
	ok("and the books agree again", drift(st) < 0.01, string.format("drift %.3f", drift(st)))
end

print("=== cancelling preserves a manual volume change made mid-edit ===")
do
	--[[
	Undoing THIS EDIT's contribution, rather than snapping back to a remembered
	volume, means anything the user did to the volume knob survives the cancel.
	]]
	local st = newState(40)
	levelMatch(st, 15.0)
	local snapApplied = st.applied
	local beforeEdit  = st.volume

	for g = 14.5, 8, -0.5 do levelMatch(st, g) end
	st.volume = st.volume + 6                  -- the user turns it up mid-edit

	--[[
	The property survives the architecture change, and for a better reason.
	Reconciling from the REAL current compensation to the snapshot's target moves
	the volume by our contribution only, so a manual change made mid-edit is
	simply never part of the delta -- the same outcome the old direct computation
	produced, now falling out of the transaction rather than a second code path.
	]]
	levelMatch(st, snapApplied)

	ok("the manual +6 survives the cancel", st.volume > beforeEdit,
	   string.format("restored to %d, pre-edit was %d", st.volume, beforeEdit))
end

print("=== the step floor does not silently desync the books ===")
do
	--[[
	Moves below one volume step are skipped. Skipping must leave appliedAtten
	untouched -- if it advanced without the volume moving, the two would part
	company by a fraction on every click.
	]]
	local st = newState(40)
	local before = st.applied
	levelMatch(st, 0.2)
	ok("a sub-step target changes nothing at all",
	   st.applied == before and drift(st) < 0.01,
	   string.format("applied %.3f, volume %d", st.applied, st.volume))
end


--[[
BEST-EFFORT LEVEL MATCHING -- switching it ON against a curve it cannot fully pay for.

The feature must not refuse, must not switch itself back off, and must not need a
toggle cycle to recover. It applies what the volume range allows, records what it
actually ACHIEVED (not what was asked), and catches up on its own when the curve
becomes cheaper. The separate rule -- that an EDIT may not newly exceed the
headroom -- lives in the applet's _design and is covered by test_headroom.

The distinction that makes this safe: appliedAtten is bookkeeping about the REAL
volume. If only part of the make-up went in, recording the full figure would
claim attenuation that is not being compensated, and every later delta would be
computed from that lie.
]]
print("=== enabling level matching on an unaffordable curve is BEST EFFORT ===")
do
	local st = newState(90)                  -- only a few dB of room above
	local CURVE = 30.0                       -- both bands +15 at Q 1.0, measured

	levelMatch(st, CURVE)

	ok("the volume moved as far as it could", st.volume > 90,
	   string.format("90 -> %d", st.volume))
	ok("it did not overshoot the top", st.volume <= 100, tostring(st.volume))
	ok("appliedAtten records what was ACHIEVED, not what was asked",
	   st.applied < CURVE and st.applied > 0,
	   string.format("achieved %.2f of %.1f dB", st.applied, CURVE))
	ok("the books still agree with the real volume", drift(st) < 0.01,
	   string.format("drift %.3f", drift(st)))

	-- Now the user makes the curve cheaper. No toggle, no retry: the next apply
	-- reconciles from what is really in place toward the new, affordable target.
	local before = st.applied
	levelMatch(st, 2.0)

	ok("a curve cheap enough to afford reconciles automatically", st.applied < before,
	   string.format("%.2f -> %.2f dB", before, st.applied))
	ok("and lands on the new target", math.abs(st.applied - 2.0) < 1.5,
	   string.format("applied %.2f, target 2.0", st.applied))
	ok("the books agree after recovery", drift(st) < 0.01,
	   string.format("drift %.3f", drift(st)))
end


--[[
THE VOLUME FLOOR ABSORBS THE REMAINDER.

Reachable without anything failing: level matching raises the volume to pay for a
big boost, the user then turns the volume down by hand, and then bypasses or
resets. The downward move now needs to go below zero, and the control floors
there.

Carrying the un-removable residue forward was the wrong answer twice over. It
reported a failure, which holds the mute -- correct when make-up is standing over
reduced attenuation, but here the volume is already at the floor, so there is
nothing to be loud with and no further reduction available to retry. The books
also stayed permanently wrong.

So the floor discards it: appliedAtten becomes the target and the accounting
matches the real volume again.
]]
print("=== a downward move that LANDS on volume zero discards the residue ===")
do
	--[[
	The case the first version of this test missed. It set the volume to 0 before
	reconciling, so it only ever exercised a move that STARTED at the floor -- the
	one branch that had been implemented. A move that starts above zero and clamps
	to it took the ordinary path and stranded what it could not remove.

	Written from the POLICY (compensation below the floor is discarded) rather
	than from the code path, this is the case that falls out first.
	]]
	local st = newState(40)
	levelMatch(st, 15.0)                       -- volume climbs to pay for a boost
	st.volume = 5                              -- the user turns it right down

	levelMatch(st, 0)                          -- bypass: remove all of it

	ok("the volume reaches the floor", st.volume == 0, tostring(st.volume))
	ok("appliedAtten reaches the target, not a residue", math.abs(st.applied) < 0.01,
	   string.format("applied %.2f", st.applied))
	ok("the books agree with the real volume", drift(st) < 0.01,
	   string.format("drift %.3f", drift(st)))
end

print("=== a downward move that STARTS at volume zero does the same ===")
do
	local st = newState(40)
	levelMatch(st, 15.0)                       -- a +15 curve, volume climbs
	ok("the curve raised the volume", st.volume > 40,
	   string.format("40 -> %d", st.volume))

	st.volume = 0                              -- the user turns it right down
	st.truth  = 0                              -- nothing of ours is in it now

	levelMatch(st, 0)                          -- bypass / reset: unwind it all

	ok("appliedAtten is cleared, not left stranded", math.abs(st.applied) < 0.01,
	   string.format("applied %.3f", st.applied))
	ok("the books agree with the real volume", drift(st) < 0.01,
	   string.format("drift %.3f", drift(st)))

	-- And the state is usable again afterwards.
	levelMatch(st, 6.0)
	ok("a later curve compensates from a clean slate", st.applied > 0,
	   string.format("applied %.2f from volume %d", st.applied, st.volume))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
