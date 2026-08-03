--[[
test_graphrange -- the graph's vertical range must cover every reachable curve.

    cd /tmp && jive test_graphrange        (needs eqdesign.lua + uistate.lua beside it)

WHAT THIS EXISTS TO CATCH.

The drawing code PINS anything outside the range to the frame:

    if db >  DB_RANGE then db =  DB_RANGE end
    if db < -DB_RANGE then db = -DB_RANGE end

so a curve that exceeds it does not overflow visibly -- it goes flat-topped and
silently stops showing its own shape. The applet shipped at DB_RANGE = 16 while
bass +15 with treble +15 reaches +26.83 dB, so the most extreme setting the
control offers was drawn as a plateau.

WHY THE PEAK EQUALS THE MAKE-UP. designPair peak-normalises each section to
0 dB, because the chip cannot express gain above unity. _recomputeCurve then
adds attenDb back so boosts read above the centre line. The maximum plotted
value is therefore exactly attenDb, and the question "does the graph clip" is
the question "is DB_RANGE >= the largest attenDb the controls can reach".

This sweeps the corners of the control range rather than trusting the 26.83
figure, which came from one measurement and is quoted in a comment.

DB_RANGE is READ from the applet, never restated here -- a copy would agree on
the day it was written and drift the day the constant moved.
]]

local D = require("eqdesign")
local U = require("uistate")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-46s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-46s %s", name, detail or "")) end
end

-- ---- the constant, read from the applet -------------------------------------
local APPLET = "/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua"
local dbRange
do
	local fh = io.open(APPLET, "r")
	if fh then
		for line in fh:lines() do
			dbRange = tonumber(line:match("^local DB_RANGE%s*=%s*(%d+)")) or dbRange
		end
		fh:close()
	end
end
ok("DB_RANGE was read from the applet", dbRange ~= nil,
   "DB_RANGE = " .. tostring(dbRange))
if not dbRange then
	print("")
	print(string.format("passed=%d failed=%d", pass, fail))
	return
end

-- ---- sweep the control range ------------------------------------------------
local R = U.RANGE
local function corners(r)
	return { r.lo, (r.lo + r.hi) / 2, r.hi }
end

local worst, wdesc = -1 / 0, ""
local checked = 0

for _, bf in ipairs(corners(R.bassFreq)) do
for _, bg in ipairs({ 0, R.bassGain.hi }) do
for _, bq in ipairs(corners(R.bassQ)) do
	for _, tf in ipairs(corners(R.trebFreq)) do
	for _, tg in ipairs({ 0, R.trebGain.hi }) do
	for _, tq in ipairs(corners(R.trebQ)) do
		local _, _, i = D.designPair(FS,
			{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
			{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
		checked = checked + 1
		local peak = i.attenDb or 0        -- the plotted maximum, by construction
		if peak > worst then
			worst = peak
			wdesc = string.format("bass %.0f/%+.0f/Q%.1f treble %.0f/%+.0f/Q%.1f",
			                      bf, bg, bq, tf, tg, tq)
		end
	end end end
end end end

ok("swept the corners of the control range", checked > 0, checked .. " combinations")

ok("no reachable setting clips the graph", worst <= dbRange,
   string.format("worst plotted peak %.2f dB of %d available (%s)", worst, dbRange, wdesc))

-- A range far larger than needed squashes everyday curves, so flag slack too.
ok("the range is not wastefully large", worst >= dbRange - 6,
   string.format("headroom above the worst curve: %.2f dB", dbRange - worst))

--[[
NEGATIVE CONTROL. The old value must be shown to fail, or this test would pass
just as happily on the setting that shipped clipped.
]]
local OLD = 16
local caught = worst > OLD
ok("the gate FIRES on the old DB_RANGE of 16", caught,
   string.format("%.2f dB would have clipped at 16", worst))
assert(caught, "negative control did not fire: this test can no longer fail")

print("")
print(string.format("passed=%d failed=%d", pass, fail))
