--[[
SBRadioEQ -- test_pairnorm.lua      cd /tmp && jive test_pairnorm

⛔ THIS FILE PREVIOUSLY ASSERTED A FALSE CLAIM, and passed 26/26 while doing it.

The claim: "make-up is the CASCADE peak, not the sum" -- bass +12 with treble +6
costs 12 dB, not 18, because the two boosts sit at opposite ends of the spectrum
and never stack. It was defended twice under direct challenge and re-verified at
"0.000 dB error".

It is false, and the verification was circular. The old check computed
`trueRequired` as the peak of the unnormalised ideal cascade and compared
attenDb against it -- but BOTH sides came from the same response model, and that
model has no notion of the coefficient format. It could not have failed.

diag_canboost.lua settles it, with no hardware:

    largest boost ANY section can hold before the format forces a scale-down
        lowshelf 150 Hz ... +0.00 dB
        highshelf 4 kHz ... +0.00 dB
    (a +15 dB shelf at 4 kHz needs N0 = 129274; the field holds 32767)

No section can express gain above unity. Every boost is realised as
cut-elsewhere PER SECTION, and the midrange -- "elsewhere" for both bands --
loses roughly their sum. Measured: bass +15 / treble +15 costs 26.83 dB.

This was recorded on day one as "⛔ THE CHIP CANNOT EXPRESS GAIN ABOVE 0 dB.
Every boost is cut-elsewhere." The cascade-peak claim contradicted an already
established fact, and was then re-verified against a model that could not see it.

So these tests assert nothing about cascade peaks. They assert the property a
listener can actually feel -- the make-up puts the untouched midrange back where
it was -- measured from the QUANTISED coefficients, so the format is inside the
test rather than outside it.
]]

local D  = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-52s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-52s %s", name, detail or "")) end
end

local function bass(g) return { kind = "lowshelf",  f0 = 150,  gainDb = g, shape = 0.9 } end
local function treb(g) return { kind = "highshelf", f0 = 4000, gainDb = g, shape = 0.9 } end

local F_REF = 900          -- midrange; neither shelf targets it

local function realised(c, f)
	if not c then return 0 end
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	return D.responseDb(b0, b1, b2, a1, a2, f, FS)
end

local function design(bg, tg)
	local c1, c2, i = D.designPair(FS, bass(bg), treb(tg))
	local function peakOf(c)
		if not c then return 0 end
		local best = -1 / 0
		for _, f in ipairs(D.GRID) do
			local v = realised(c, f); if v > best then best = v end
		end
		return best
	end
	local pairPeak = -1 / 0
	for _, f in ipairs(D.GRID) do
		local v = realised(c1, f) + realised(c2, f)
		if v > pairPeak then pairPeak = v end
	end
	return i, realised(c1, F_REF) + realised(c2, F_REF), peakOf(c1), pairPeak
end

print("=== make-up restores the untouched midrange (the only thing a listener feels) ===")
do
	local worst, at, checked = 0, { 0, 0 }, 0
	for _, bg in ipairs({ 0, 3, 6, 9, 12, 15 }) do
	for _, tg in ipairs({ 0, 3, 6, 9, 12, 15 }) do
		local i, mid = design(bg, tg)
		local err = mid + (i.attenDb or 0)
		if math.abs(err) > math.abs(worst) then worst, at = err, { bg, tg } end
		checked = checked + 1
	end end
	ok("midrange lands where it started, everywhere", math.abs(worst) < 0.5,
	   string.format("%d pairs, worst %+.2f dB at bass %+d / treble %+d",
	                 checked, worst, at[1], at[2]))
end

print("=== the format caps EVERY section at unity -- this is what costs the volume ===")
do
	for _, t in ipairs({ { "lowshelf", 150 }, { "highshelf", 4000 } }) do
		local best = -1
		for g = 0, 20, 0.25 do
			local b0, b1, b2 = D.designIdeal(t[1], FS, t[2], g, 0.9)
			local worst = math.max(math.abs(b0) * D.SCALE,
			                       math.abs(b1) * D.SCALE_2,
			                       math.abs(b2) * D.SCALE)
			if worst <= 32767 then best = g else break end
		end
		ok(string.format("%s cannot hold ANY boost", t[1]), best <= 0.001,
		   string.format("largest that fits: %+.2f dB", best))
	end

	local b0 = D.designIdeal("highshelf", FS, 4000, 15, 0.9)
	ok("a +15 dB shelf at 4 kHz overflows N0 about 4x", math.abs(b0) * D.SCALE > 120000,
	   string.format("needs N0 = %.0f, field holds 32767", math.abs(b0) * D.SCALE))
end

--[[
THE ANTI-ASSERTION. Two boosted bands must cost MORE than the cascade peak. If a
future change makes this pass by charging only the peak, it has reintroduced the
false claim -- and the level will then sag on the device instead of in a test.
]]
print("=== two boosts cost more than the cascade peak (the old claim, inverted) ===")
do
	for _, p in ipairs({ { 12, 6 }, { 6, 12 }, { 15, 15 }, { 9, 9 } }) do
		local i = design(p[1], p[2])
		local cascadePeak = math.max(p[1], p[2])
		ok(string.format("bass %+d / treble %+d exceeds the cascade peak", p[1], p[2]),
		   (i.attenDb or 0) > cascadePeak + 1.0,
		   string.format("charges %.2f dB, cascade peak is %.0f", i.attenDb or 0, cascadePeak))
	end
end

--[[
Upper bound, as a guard against gross over-charging.

The allowance is not slack for its own sake. The naive sum is computed from the
IDEAL gains, and designPair normalises the REALISED, quantised response -- which
for a low shelf near DC can sit above its ideal after quantisation. Pulling that
back is real level removed, so it is legitimately charged, and the total lands
just over the ideal sum.

It was 1.0 dB and is now 1.5. That is a REAL WIDENING and it is worth being
suspicious of, so: the extra came from extending the CLIP check below 40 Hz,
which removed a measured +3.49 dB overshoot at 20 Hz on bass 100 / +15 / Q 0.2
and cost 1.24 dB on the two worst pairs. The ideal sum cannot see sub-40 Hz
clipping, so it was never the right ceiling for it.

⚠️ A widened ceiling proves less, so it is NOT what guards over-charging. That is
the FIRST assertion in this file -- the midrange must land within 0.5 dB of where
it started -- which is exact, cannot be satisfied by charging too much, and still
passes. Treat this one as a smoke alarm, not a proof.
]]
print("=== and never much more than the naive per-section sum ===")
do
	local QUANT_ALLOWANCE = 1.5
	for _, p in ipairs({ { 12, 6 }, { 6, 12 }, { 15, 15 }, { 3, 9 }, { 15, 0 }, { 0, 15 } }) do
		local i = design(p[1], p[2])
		local naive = math.max(p[1], 0) + math.max(p[2], 0)
		ok(string.format("bass %+d / treble %+d within the sum", p[1], p[2]),
		   (i.attenDb or 0) <= naive + QUANT_ALLOWANCE,
		   string.format("%.2f vs %.0f (+%.1f allowed for quantisation)",
		                 i.attenDb or 0, naive, QUANT_ALLOWANCE))
	end
end

print("=== one band alone still costs only its own boost ===")
do
	local i = design(12, 0)
	ok("bass only charges about 12", math.abs((i.attenDb or 0) - 12) < 0.6,
	   string.format("%.2f dB", i.attenDb or 0))
	i = design(0, 12)
	ok("treble only charges about 12", math.abs((i.attenDb or 0) - 12) < 0.6,
	   string.format("%.2f dB", i.attenDb or 0))
end

print("=== cuts cost nothing ===")
do
	local i = design(-12, -6)
	ok("all-cut needs no make-up", math.abs(i.attenDb or 0) < 0.05,
	   string.format("%.2f dB", i.attenDb or 0))
	i = design(0, 0)
	ok("flat needs no make-up", math.abs(i.attenDb or 0) < 0.05,
	   string.format("%.2f dB", i.attenDb or 0))
end

print("=== nothing clips: intermediate and output both stay at or under unity ===")
do
	local badSec1, badOut = {}, {}
	for _, bg in ipairs({ 0, 6, 12, 15 }) do
	for _, tg in ipairs({ 0, 6, 12, 15 }) do
		local _, _, sec1, out = design(bg, tg)
		if sec1 > 0.05 and #badSec1 < 3 then
			badSec1[#badSec1 + 1] = string.format("b%+d t%+d: %+.2f", bg, tg, sec1)
		end
		if out > 0.05 and #badOut < 3 then
			badOut[#badOut + 1] = string.format("b%+d t%+d: %+.2f", bg, tg, out)
		end
	end end
	ok("section 1 output (the intermediate) stays <= 0 dB", #badSec1 == 0,
	   table.concat(badSec1, " | "))
	ok("the pair's output stays <= 0 dB", #badOut == 0, table.concat(badOut, " | "))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
