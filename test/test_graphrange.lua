--[[
test_graphrange -- the graph's vertical range must fit the curve, both ways.

    cd /tmp && jive test_graphrange     (needs eqdesign.lua + uistate.lua beside it)

⛔ THIS TEST MEASURED THE WRONG QUANTITY ONCE, AND CERTIFIED A BAD DISPLAY.

Its first version used `peak = info.attenDb`. attenDb is the MAKE-UP -- what the
volume restores -- and the graph never plots it. _recomputeCurve draws

    d(f) = attenDb + response(realised1, f) + response(realised2, f)

and the two sections are peak-normalised INDEPENDENTLY, at DIFFERENT
frequencies. Where bass is at its maximum treble is at its floor, so the top of
the drawn curve is attenDb MINUS that floor.

The gap is not small. At bass 100/+15/Q2.0 with treble 3000/+15/Q2.0 the make-up
is 34.76 dB while the curve spans only -1.85..+17.57. Sizing the range against
34.76 gave DB_RANGE 36, at which that curve reached half the upper half and the
rest of the plot was unreachable by any setting -- and this test PASSED, because
it was checking a number nobody draws.

So the sweep below reproduces the draw path exactly rather than taking a
shortcut through attenDb, and it now fails in BOTH directions: too small clips,
too large wastes.

DB_RANGE is READ from the installed applet, never restated here.
]]

local D = require("eqdesign")
local U = require("uistate")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-44s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-44s %s", name, detail or "")) end
end

-- the applet's own frequency grid, so the sampled extremes match what is drawn
local FREQS = {}
do
	local l0, l1 = math.log(40), math.log(16000)
	for i = 0, 80 do FREQS[i + 1] = math.exp(l0 + (l1 - l0) * i / 80) end
end

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
ok("DB_RANGE was read from the installed applet", dbRange ~= nil,
   "DB_RANGE = " .. tostring(dbRange))
if not dbRange then
	print(""); print(string.format("passed=%d failed=%d", pass, fail)); return
end

-- EXACTLY what _recomputeCurve plots.
local function drawnSpan(bf, bg, bq, tf, tg, tq)
	local _, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	local p, q, off = i.realised1, i.realised2, i.attenDb or 0
	local mx, mn = -1 / 0, 1 / 0
	for _, f in ipairs(FREQS) do
		local d = off
		if p then d = d + D.responseDb(p.b0, p.b1, p.b2, p.a1, p.a2, f, FS) end
		if q then d = d + D.responseDb(q.b0, q.b1, q.b2, q.a1, q.a2, f, FS) end
		if d > mx then mx = d end
		if d < mn then mn = d end
	end
	return mx, mn
end

local R = U.RANGE
local function corners(r) return { r.lo, (r.lo + r.hi) / 2, r.hi } end

local hi, lo, hiAt, loAt, n = -1 / 0, 1 / 0, "", "", 0
for _, bf in ipairs(corners(R.bassFreq)) do
for _, bg in ipairs({ R.bassGain.lo, 0, R.bassGain.hi }) do
for _, bq in ipairs(corners(R.bassQ)) do
for _, tf in ipairs(corners(R.trebFreq)) do
for _, tg in ipairs({ R.trebGain.lo, 0, R.trebGain.hi }) do
for _, tq in ipairs(corners(R.trebQ)) do
	local a, b = drawnSpan(bf, bg, bq, tf, tg, tq)
	n = n + 1
	if a > hi then hi = a; hiAt = string.format("b %.0f/%+.0f/Q%.1f t %.0f/%+.0f/Q%.1f", bf,bg,bq,tf,tg,tq) end
	if b < lo then lo = b; loAt = string.format("b %.0f/%+.0f/Q%.1f t %.0f/%+.0f/Q%.1f", bf,bg,bq,tf,tg,tq) end
end end end end end end

ok("swept the control range", n > 0, n .. " combinations")

local need = math.max(math.abs(hi), math.abs(lo))

ok("nothing the controls can reach clips", need <= dbRange,
   string.format("needs +/-%.2f, have +/-%d   (high %+.2f %s)", need, dbRange, hi, hiAt))

-- The failure that motivated the rewrite: a range so large the curve can never
-- use it. 6 dB of slack is generous; 36 against a 22.3 need was 13.7 dB.
ok("the range is not wastefully large", (dbRange - need) <= 6,
   string.format("slack %.2f dB above the worst curve", dbRange - need))

--[[
NEGATIVE CONTROLS. Both directions, because this test previously passed while
the display was wrong -- one-sided checking is how that happened.
]]
local caughtSmall = need > 16
ok("fires on the old DB_RANGE of 16 (clipping)", caughtSmall,
   string.format("%.2f dB would clip at 16", need))

local caughtBig = (36 - need) > 6
ok("fires on DB_RANGE 36 (waste)", caughtBig,
   string.format("36 would leave %.2f dB of slack", 36 - need))

assert(caughtSmall, "negative control did not fire: cannot detect clipping")
assert(caughtBig,   "negative control did not fire: cannot detect waste")

print("")
print(string.format("passed=%d failed=%d", pass, fail))
