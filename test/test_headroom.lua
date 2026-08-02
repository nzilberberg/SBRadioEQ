--[[
SBRadioEQ -- test_headroom.lua         cd /tmp && jive test_headroom

The make-up owed for a boost must be payable, or the level sags instead.

Measured facts this rests on (diag_ceiling2.lua, diag_reference.lua):
  * make-up is EXACT -- the midrange lands within 0.28 dB of where it started
    across the whole control surface, so the arithmetic is not the problem;
  * the amount is large and unavoidable -- bass +15 with treble +15 costs
    26.83 dB, because the coefficient format caps each section near unity, both
    boosts are realised as cut, and the midrange is "elsewhere" for both.

So the ceiling is HEADROOM. This checks the clamp that enforces it, and checks
the two ways a clamp like this usually goes wrong: trapping the user in a state
they cannot leave, and clamping when it has no business doing so.

The applet's logic is reproduced here rather than imported -- SBRadioEQApplet is
a `module(...)` applet that needs the whole SqueezePlay window stack to load.
Anything reproduced is a comment away from its original.
]]

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

-- _headroomDb: what the volume control can still give, measured from the user's
-- base level (the current volume already contains appliedAtten of make-up).
local function headroom(volume, appliedAtten)
	return (appliedAtten or 0) - D.volumeToDb(volume)
end

-- _nudge's clamp: a boost that cannot be paid for is refused.
local function nudgeGain(bg, tg, which, step, volume, appliedAtten)
	local nbg, ntg = bg, tg
	if which == "bass" then nbg = bg + step else ntg = tg + step end
	if nbg > 15 then nbg = 15 end
	if ntg > 15 then ntg = 15 end
	if nbg < -15 then nbg = -15 end
	if ntg < -15 then ntg = -15 end
	local rising = (which == "bass" and nbg > bg) or (which == "treb" and ntg > tg)
	if rising and atten(nbg, ntg) > headroom(volume, appliedAtten) + 0.01 then
		return bg, tg, true                        -- refused
	end
	return nbg, ntg, false
end

print("=== headroom is measured from the user's BASE level ===")
do
	ok("volume 36, no make-up applied yet", math.abs(headroom(36, 0) - 31.57) < 0.2,
	   string.format("%.2f dB", headroom(36, 0)))
	-- after 10 dB of make-up the volume has RISEN, but the base has not moved,
	-- so the budget must be unchanged rather than shrinking as we spend it
	local v10 = D.dbToVolume(D.volumeToDb(36) + 10)
	ok("same budget after 10 dB has been spent",
	   math.abs(headroom(v10, 10) - headroom(36, 0)) < 0.6,
	   string.format("%.2f dB at volume %d vs %.2f at 36", headroom(v10, 10), v10, headroom(36, 0)))
	ok("volume 100 has no headroom at all", headroom(100, 0) < 0.01,
	   string.format("%.2f dB", headroom(100, 0)))
end

print("=== a boost that cannot be paid for is REFUSED ===")
do
	-- at volume 90 there is very little left to give
	local hr = headroom(90, 0)
	local bg, tg, limited = nudgeGain(0, 0, "bass", 15, 90, 0)
	ok("bass +15 at volume 90 is refused", limited and bg == 0,
	   string.format("headroom %.1f dB, needs %.1f dB", hr, atten(15, 0)))

	-- the same request low down is affordable
	bg, tg, limited = nudgeGain(0, 0, "bass", 15, 30, 0)
	ok("bass +15 at volume 30 is allowed", (not limited) and bg == 15,
	   string.format("headroom %.1f dB, needs %.1f dB", headroom(30, 0), atten(15, 0)))
end

print("=== the SECOND band is what actually hits the ceiling ===")
do
	--[[
	This is the user's report: one band fine, the second kills the level. The
	volume has to be chosen so the pair genuinely does not fit -- at 55 there is
	22.2 dB available and the pair needs 21.6, which IS affordable, and refusing
	it would be the clamp misfiring.
	]]
	local vol = 65
	local hr  = headroom(vol, 0)
	local bg, tg, limited = nudgeGain(0, 0, "bass", 12, vol, 0)
	ok("bass +12 alone is affordable", (not limited) and bg == 12,
	   string.format("needs %.1f of %.1f dB", atten(12, 0), hr))

	local _, tg2, lim2 = nudgeGain(12, 0, "treb", 12, vol, 0)
	ok("treble +12 on top is refused rather than sagging", lim2 and tg2 == 0,
	   string.format("would need %.1f of %.1f dB", atten(12, 12), hr))

	--[[
	And the same pair IS allowed once there is room for it.

	The volume is DERIVED from what the pair actually costs, not hardcoded. An
	earlier version pinned volume 55, chosen when the pair cost 21.6 dB; a later
	fix to the design engine raised it to 23.8 dB and 55 could no longer pay, so
	a correct clamp failed a stale test. Deriving it means a change in the design
	can never invalidate the assertion -- only a change in the CLAMP can, which
	is the thing under test.
	]]
	local need = atten(12, 12)
	local roomy = D.dbToVolume(-(need + 3))        -- 3 dB of margin over the cost
	local _, tg3, lim3 = nudgeGain(12, 0, "treb", 12, roomy, 0)
	ok("the same pair is allowed once there is room", (not lim3) and tg3 == 12,
	   string.format("needs %.1f of %.1f dB at volume %d",
	                 need, headroom(roomy, 0), roomy))
end

print("=== the clamp never traps the user ===")
do
	-- Whatever state we are in, turning a gain DOWN must always be permitted:
	-- a cut demands no make-up, and it is the way out.
	local trapped = {}
	for _, vol in ipairs({ 30, 55, 80, 95, 100 }) do
	for _, bg in ipairs({ 0, 6, 12, 15 }) do
	for _, tg in ipairs({ 0, 6, 12, 15 }) do
		local nbg, ntg, lim = nudgeGain(bg, tg, "bass", -0.5, vol, 0)
		if lim and #trapped < 3 then
			trapped[#trapped + 1] = string.format("vol %d bass %+.0f treb %+.0f", vol, bg, tg)
		end
	end end end
	ok("a cut is never refused, at any volume or setting", #trapped == 0,
	   table.concat(trapped, " | "))
end

print("=== the clamp does not fire when there is room ===")
do
	local spurious = {}
	for _, vol in ipairs({ 20, 30, 40 }) do
	for _, tg in ipairs({ 0, 3, 6 }) do
		local _, _, lim = nudgeGain(0, tg, "bass", 0.5, vol, 0)
		if lim and #spurious < 3 then
			spurious[#spurious + 1] = string.format("vol %d treb %+.0f needs %.1f of %.1f",
				vol, tg, atten(0.5, tg), headroom(vol, 0))
		end
	end end
	ok("small boosts at low volume are always allowed", #spurious == 0,
	   table.concat(spurious, " | "))
end

print("=== with no player, do not clamp on a guess ===")
do
	--[[
	_headroomDb returns 96 dB when there is no local player. Refusing edits
	because the volume happens to be unreadable would make the control appear
	broken for a reason the user cannot see or act on, so the fallback must be
	permissive. Check the largest demand on the surface still clears it.
	]]
	local NO_PLAYER = 96
	local worst = atten(15, 15)
	ok("the biggest possible demand clears the fallback budget", worst < NO_PLAYER,
	   string.format("worst case %.1f dB vs %.0f dB budget", worst, NO_PLAYER))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
