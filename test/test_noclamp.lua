--[[
SBRadioEQ -- test_noclamp.lua      cd /tmp && jive test_noclamp

THE REGRESSION THIS EXISTS FOR. bass +8 @266 Hz Q1.2 with treble +9 @4384 Hz Q0.95
produced a treble section whose b1 needed -2.963. N1 is stored at scale 16384, so
|b1| < 2.0 -- clampInt truncated it to -2.0 and the filter became a -36 dB brick
wall. Measured on the device: 50 Hz -35.60 dB, 500 Hz -38.87 dB. The user's audible
level vanished while every number in my logs looked correct, because I was
verifying the DESIGN and the chip was running the CLAMPED coefficients.

INVARIANT: no coefficient a design hands back may sit at the clamp limit, and the
realised response must track the intended shape. Swept across the whole control
range, not just the one case that bit.
]]

local D  = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-44s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-44s %s", name, detail or "")) end
end

local function clamped(c)
	for _, k in ipairs({ "N0", "N1", "N2", "D1", "D2" }) do
		-- FLAT deliberately uses 32767 for N0; that is the one legitimate case.
		local isFlat = (c.N0 == 32767 and c.N1 == 0 and c.N2 == 0 and c.D1 == 0 and c.D2 == 0)
		if not isFlat and (c[k] == D.INT_MAX or c[k] == D.INT_MIN) then return k end
	end
	return nil
end

print("=== the exact case from the device ===")
local c1, c2, i = D.designPair(FS,
	{ kind = "lowshelf",  f0 = 266,  gainDb = 8, shape = 1.2  },
	{ kind = "highshelf", f0 = 4384, gainDb = 9, shape = 0.95 })
ok("bass section has no clamped coefficient",  clamped(c1) == nil, tostring(clamped(c1)))
ok("treble section has no clamped coefficient", clamped(c2) == nil, tostring(clamped(c2)))

local b0,b1,b2,a1,a2 = D.dequantize(c2)
local lowDb = D.responseDb(b0,b1,b2,a1,a2, 50, FS)
local hiDb  = D.responseDb(b0,b1,b2,a1,a2, 12000, FS)
ok("treble shelf spans ~9 dB, not ~36", math.abs((hiDb - lowDb) - 9) < 1.5,
   string.format("%.2f dB span (low %.2f, high %.2f)", hiDb - lowDb, lowDb, hiDb))

-- combined, with the make-up added back: nothing should be buried
local d0,d1_,d2_,e1,e2 = D.dequantize(c1)
local worstDip = 1/0
for _, f in ipairs({ 50, 100, 200, 500, 1000, 2000, 4000, 8000, 12000 }) do
	local t = i.attenDb + D.responseDb(d0,d1_,d2_,e1,e2,f,FS) + D.responseDb(b0,b1,b2,a1,a2,f,FS)
	if t < worstDip then worstDip = t end
end
ok("no frequency is buried after make-up", worstDip > -12,
   string.format("worst %.2f dB (was -38.87 on the device)", worstDip))

print("=== sweep the whole control range for clamping ===")
local bad, checked = 0, 0
local firstBad = nil
for _, bf in ipairs({ 100, 150, 266, 400, 800 }) do
for _, bg in ipairs({ -15, -8, 0, 8, 15 }) do
for _, bq in ipairs({ 0.2, 0.9, 1.2, 2.0 }) do
for _, tf in ipairs({ 1000, 2500, 4384, 8000, 16000 }) do
for _, tg in ipairs({ -15, -8, 0, 9, 15 }) do
for _, tq in ipairs({ 0.2, 0.95, 2.0 }) do
	local x, y = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	checked = checked + 2
	local cx, cy = clamped(x), clamped(y)
	if cx or cy then
		bad = bad + 1
		if not firstBad then
			firstBad = string.format("b%+d@%d Q%.2f / t%+d@%d Q%.2f -> %s%s",
				bg, bf, bq, tg, tf, tq, tostring(cx), tostring(cy))
		end
	end
end end end end end end
ok("no clamped coefficient anywhere in range", bad == 0,
   string.format("%d sections checked, %d clamped%s", checked, bad,
                 firstBad and ("  first: " .. firstBad) or ""))

print("")
print(string.format("passed=%d failed=%d", pass, fail))
