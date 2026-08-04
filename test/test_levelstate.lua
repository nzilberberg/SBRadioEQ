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

print("")
print(string.format("passed=%d failed=%d", pass, fail))
