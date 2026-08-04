--[[
SBRadioEQ -- test_headroom.lua         cd /tmp && jive test_headroom

⛔ THIS FILE USED TO REIMPLEMENT THE CODE IT WAS TESTING.

The applet cannot be loaded outside Jive, so the headroom rule and the nudge
clamp were COPIED into the test and the copies were checked. That proves the
copy is self-consistent and nothing about the applet: production could drift
away and every assertion here would stay green.

The policy now lives in uistate.lua and the applet calls it, so these exercise
the real functions. Anything still duplicated below is a bug in this file.

The measured facts the policy rests on (diag_ceiling2, diag_reference):
  * make-up is EXACT -- the midrange lands within 0.28 dB of where it started
    across the whole control surface;
  * it is large and unavoidable -- bass +15 with treble +15 costs 26.83 dB,
    because the coefficient format caps each section near unity, both boosts
    become cut, and the midrange is "elsewhere" for both.
So the ceiling is whether the make-up can be PAID.
]]

local U = require("uistate")
local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-52s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-52s %s", name, detail or "")) end
end

local function atten(bg, tg)
	local _, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = bg, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = tg, shape = 0.9 })
	return i.attenDb or 0
end

-- The production headroom rule, given a player volume.
local function budgetAt(volume, appliedAtten)
	return U.headroomDb(appliedAtten, D.volumeToDb(volume))
end

print("=== headroom is measured from the user's BASE level ===")
do
	ok("volume 36, nothing spent yet", math.abs(budgetAt(36, 0) - 31.57) < 0.2,
	   string.format("%.2f dB", budgetAt(36, 0)))

	-- After 10 dB of make-up the volume has RISEN, but the base has not moved,
	-- so the budget must be unchanged rather than shrinking as it is spent.
	local v10 = D.dbToVolume(D.volumeToDb(36) + 10)
	ok("same budget after 10 dB has been spent",
	   math.abs(budgetAt(v10, 10) - budgetAt(36, 0)) < 0.6,
	   string.format("%.2f at volume %d vs %.2f at 36", budgetAt(v10, 10), v10, budgetAt(36, 0)))

	ok("volume 100 has no headroom at all", budgetAt(100, 0) < 0.01,
	   string.format("%.2f dB", budgetAt(100, 0)))
end

--[[
⛔⛔ THIS BLOCK USED TO ASSERT THE DEFECT.

It tested U.mustCheckAffordability directly, and two of its four assertions were
"frequency is never checked" and "Q is never checked" -- passing expectations
that the headroom guard ignored those controls. The guard did ignore them, and
that was the bug: Q changes what the curve COSTS, so an unaffordable Q step was
accepted, written to the codec, and reported as applied while the output sagged.

A test that pins a defect in place is worse than no test, because the suite goes
green over it and the next reader takes the behaviour as intended.

What matters is the property the guard exists to protect: a change that makes the
curve cost MORE than the budget must be refused, whichever control caused it. The
cost is measured from the designed curve, so that is what is asserted here.
]]
print("=== cost is a property of the CURVE, not of which control moved ===")
do
	local FS = 44100
	local function costOf(bq, tq)
		local _, _, i = D.designPair(FS,
			{ kind = "lowshelf",  f0 = 150,  gainDb = 15, shape = bq },
			{ kind = "highshelf", f0 = 3000, gainDb = 15, shape = tq })
		return i.attenDb or 0
	end

	local atQ1 = costOf(1.0, 1.0)
	local atQ2 = costOf(2.0, 2.0)

	ok("raising Q with the gains unchanged costs MORE make-up", atQ2 > atQ1 + 1,
	   string.format("Q1.0 = %.2f dB -> Q2.0 = %.2f dB (+%.2f)", atQ1, atQ2, atQ2 - atQ1))

	-- The exact case the old guard waved through: budget sized for the Q 1.0
	-- curve, then Q raised. Affordability must say no.
	ok("a Q rise beyond the budget is NOT affordable",
	   not U.affordable(atQ2, atQ1),
	   string.format("needs %.2f dB, budget %.2f dB", atQ2, atQ1))

	ok("the same curve is affordable against its own cost",
	   U.affordable(atQ1, atQ1), "a step must never be refused at its own price")

	-- A cut must always remain available or the user is trapped.
	local cheaper = costOf(0.7, 0.7)
	ok("lowering Q is always affordable once the dearer curve was",
	   cheaper < atQ2 and U.affordable(cheaper, atQ2),
	   string.format("%.2f dB against a %.2f dB budget", cheaper, atQ2))
end

print("=== a boost that cannot be paid for is refused ===")
do
	local need = atten(15, 0)
	ok("bass +15 at volume 90 is unaffordable",
	   not U.affordable(need, budgetAt(90, 0)),
	   string.format("needs %.1f of %.1f dB", need, budgetAt(90, 0)))
	ok("the same boost at volume 30 is affordable",
	   U.affordable(need, budgetAt(30, 0)),
	   string.format("needs %.1f of %.1f dB", need, budgetAt(30, 0)))
end

print("=== the SECOND band is what hits the ceiling ===")
do
	local vol  = 65
	local one  = atten(12, 0)
	local both = atten(12, 12)
	ok("bass +12 alone is affordable", U.affordable(one, budgetAt(vol, 0)),
	   string.format("needs %.1f of %.1f dB", one, budgetAt(vol, 0)))
	ok("treble +12 on top is refused rather than sagging",
	   not U.affordable(both, budgetAt(vol, 0)),
	   string.format("would need %.1f of %.1f dB", both, budgetAt(vol, 0)))

	-- Derived, not hardcoded: an earlier version pinned volume 55 and a later
	-- design change made the pair cost more, so a correct clamp failed a stale test.
	local roomy = D.dbToVolume(-(both + 3))
	ok("the same pair is allowed once there is room",
	   U.affordable(both, budgetAt(roomy, 0)),
	   string.format("needs %.1f of %.1f dB at volume %d", both, budgetAt(roomy, 0), roomy))
end

print("=== stepValue clamps every control to its range ===")
do
	local bad = {}
	for key, r in pairs(U.RANGE) do
		local hi = U.stepValue(key, r.hi, 50)
		local lo = U.stepValue(key, r.lo, -50)
		if hi > r.hi + 1e-9 then bad[#bad + 1] = key .. " over " .. tostring(hi) end
		if lo < r.lo - 1e-9 then bad[#bad + 1] = key .. " under " .. tostring(lo) end
	end
	ok("no control can be driven past its limits", #bad == 0, table.concat(bad, " | "))

	ok("frequency steps proportionally and lands on an integer",
	   U.stepValue("bassFreq", 200, 1) == 208,
	   tostring(U.stepValue("bassFreq", 200, 1)) .. " (200 x 1.04)")
	ok("gain steps 0.5 dB", U.stepValue("bassGain", 3, 1) == 3.5,
	   tostring(U.stepValue("bassGain", 3, 1)))
	ok("Q steps 0.05", math.abs(U.stepValue("bassQ", 0.9, 1) - 0.95) < 1e-9,
	   tostring(U.stepValue("bassQ", 0.9, 1)))

	--[[
	The `^` precedence trap, exercised through production code. On this platform
	`v * 1.04 ^ d` would compute `(v * 1.04) ^ d`; stepValue parenthesises it.
	At 200 Hz with d=3 the wrong form gives 208^3 = 8998912.
	]]
	ok("frequency stepping is not wrecked by ^ precedence",
	   U.stepValue("bassFreq", 200, 3) == 225,
	   tostring(U.stepValue("bassFreq", 200, 3)) .. " (the broken form gives 8998912)")
end

--[[
=============================================================================
BACK CANCELS AN EDIT.

Edits apply live on every click, so cancel cannot mean "do not apply" -- it has
to mean "put back what was there". Back previously just left edit mode, and the
changed value was then saved on exit: documented as cancel, behaved as accept.
=============================================================================
]]
print("=== Back restores everything the edit touched ===")
do
	local s = { bassFreq = 150, bassGain = 3, bassQ = 0.9,
	            trebFreq = 4000, trebGain = 0, trebQ = 0.9,
	            appliedAtten = 3.1, enabled = true }
	local snap = U.snapshot(s)

	-- a live edit session
	s.bassGain    = U.stepValue("bassGain", s.bassGain, 12)
	s.bassFreq    = U.stepValue("bassFreq", s.bassFreq, 4)
	s.appliedAtten = 14.7

	ok("the edit really changed things", s.bassGain ~= 3 and s.bassFreq ~= 150,
	   string.format("gain %.1f, freq %d", s.bassGain, s.bassFreq))

	U.restoreSnapshot(s, snap)
	local restored = s.bassGain == 3 and s.bassFreq == 150 and s.bassQ == 0.9
	ok("every value is back", restored,
	   string.format("gain %.1f, freq %d, Q %.2f", s.bassGain, s.bassFreq, s.bassQ))

	--[[
	The level accounting must come back too. The live edits moved the player
	volume; restoring the curve without restoring appliedAtten leaves the volume
	compensating for attenuation that is no longer there.
	]]
	ok("appliedAtten is restored with it", s.appliedAtten == 3.1,
	   tostring(s.appliedAtten))
end

print("=== the snapshot is a COPY, not a reference ===")
do
	--[[
	If snapshot returned the settings table itself, editing would mutate the
	snapshot too and cancel would restore the edited values -- passing every
	assertion above while doing nothing.
	]]
	local s = { bassFreq = 150, bassGain = 3, bassQ = 0.9,
	            trebFreq = 4000, trebGain = 0, trebQ = 0.9,
	            appliedAtten = 0, enabled = true }
	local snap = U.snapshot(s)
	s.bassGain = 15
	ok("mutating settings does not move the snapshot", snap.bassGain == 3,
	   "snapshot holds " .. tostring(snap.bassGain))

	assert(snap ~= s, "snapshot returned the settings table itself -- cancel would be a no-op")
end

print("=== cancelling with no snapshot is safe ===")
do
	local s = { bassGain = 9 }
	ok("restoreSnapshot(nil) changes nothing and reports false",
	   U.restoreSnapshot(s, nil) == false and s.bassGain == 9, "")
end

print("=== with no player, do not clamp on a guess ===")
do
	--[[
	_headroomDb returns 96 dB when the volume is unreadable. Refusing edits
	because of that would make the control appear broken for a reason the user
	cannot see or act on, so the fallback must be permissive.
	]]
	local NO_PLAYER = 96
	local worst = atten(15, 15)
	ok("the biggest possible demand clears the fallback budget",
	   U.affordable(worst, NO_PLAYER),
	   string.format("worst case %.1f dB vs %.0f dB", worst, NO_PLAYER))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
