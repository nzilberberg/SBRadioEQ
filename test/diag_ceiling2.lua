--[[
cd /tmp && jive diag_ceiling2

Boosting both bands costs far more volume make-up than boosting one. The stated
cause was fitCoeffs scaling the whole filter down to fit |b1| < 2.0 -- but
diag_qceiling measured ZERO fit penalty for single bands anywhere on the control
surface, so that story is at best incomplete.

There is a floor below which make-up cannot go: since the chip cannot express
gain above 0 dB, any curve whose combined response peaks at +P dB must be
realised P dB down, and P dB of volume must buy it back. That floor is
unavoidable and is not the bug.

So measure the GAP. For each pair of gains: the floor, what designPair actually
charges, and the difference -- then attribute the difference to the specific
step that produced it.
]]

local D = require("eqdesign")
local FS = 44100

local BASS = { kind = "lowshelf",  f0 = 150,  shape = 0.9 }
local TREB = { kind = "highshelf", f0 = 4000, shape = 0.9 }

local function spec(t, g) return { kind = t.kind, f0 = t.f0, gainDb = g, shape = t.shape } end

-- The unavoidable floor: the peak of the IDEAL combined response.
local function idealPeak(bg, tg)
	local function ideal(t, g)
		if g == 0 then return nil end
		local x = {}
		x.b0, x.b1, x.b2, x.a1, x.a2 = D.designIdeal(t.kind, FS, t.f0, g, t.shape)
		return x
	end
	local i1, i2 = ideal(BASS, bg), ideal(TREB, tg)
	local peak = -1 / 0
	for _, f in ipairs(D.GRID) do
		local v = 0
		if i1 then v = v + D.responseDb(i1.b0, i1.b1, i1.b2, i1.a1, i1.a2, f, FS) end
		if i2 then v = v + D.responseDb(i2.b0, i2.b1, i2.b2, i2.a1, i2.a2, f, FS) end
		if v > peak then peak = v end
	end
	return math.max(peak, 0)
end

print("Make-up volume owed, bass f0=150 S=0.9 / treble f0=4000 S=0.9")
print("floor = unavoidable (the combined curve's own peak); gap = what is wasted")
print("")
print("  bass  treb    floor   charged     GAP")

local worst = { gap = -1 }
for _, bg in ipairs({ 0, 3, 6, 9, 12, 15 }) do
	for _, tg in ipairs({ 0, 3, 6, 9, 12, 15 }) do
		local _, _, info = D.designPair(FS, spec(BASS, bg), spec(TREB, tg))
		local floor = idealPeak(bg, tg)
		local charged = info.attenDb or 0
		local gap = charged - floor
		if gap > worst.gap then worst = { gap = gap, bg = bg, tg = tg, floor = floor, charged = charged } end
		print(string.format("%+6.1f%+6.1f  %7.2f  %8.2f  %+7.2f%s",
			bg, tg, floor, charged, gap, gap > 1.0 and "   <==" or ""))
	end
end

print("")
if worst.gap > 0 then
	print(string.format("worst gap: bass %+.0f / treble %+.0f owes %.2f dB but is charged %.2f dB",
		worst.bg, worst.tg, worst.floor, worst.charged))
	print(string.format("           -- %.2f dB of volume thrown away", worst.gap))
end

--[[
Now attribute it. designPair charges in four parts:
  k1  section 1 normalised alone, to protect the INTERMEDIATE signal between the
      two cascaded biquads
  k2  the cascade normalised, so the OUTPUT stays <= 0 dB
  f1  section 1 scaled again so its integers fit the format
  f2  same for section 2
Only k2 is the floor. k1 is the price of the fixed-point cascade; f1/f2 are the
format. Reproduce each so the gap is attributed rather than guessed at.
]]
print("")
print("Attribution of the charge (k1 = intermediate protection, k2 = output")
print("normalisation, f1/f2 = making the integers fit):")
print("")
print("  bass  treb       k1       k2       f1       f2    total    floor")

local function raw(t, g)
	if g == 0 then return nil end
	local x = {}
	x.b0, x.b1, x.b2, x.a1, x.a2 = D.designIdeal(t.kind, FS, t.f0, g, t.shape)
	return x
end
local function respOf(x, f)
	if not x then return 0 end
	return D.responseDb(x.b0, x.b1, x.b2, x.a1, x.a2, f, FS)
end
local function scaleTo0(x)
	if not x then return 0 end
	local peak = -1 / 0
	for _, f in ipairs(D.GRID) do
		local g = respOf(x, f); if g > peak then peak = g end
	end
	if peak <= 0 then return 0 end
	local k = 10 ^ (-peak / 20)
	x.b0, x.b1, x.b2 = x.b0 * k, x.b1 * k, x.b2 * k
	return peak
end
local function fitOf(x)
	if not x then return 0 end
	local worstC = math.max(math.abs(x.b0) * D.SCALE,
	                        math.abs(x.b1) * D.SCALE_2,
	                        math.abs(x.b2) * D.SCALE)
	if worstC <= 32000 then return 0 end
	return -20 * (math.log(32000 / worstC) / math.log(10))
end

for _, bg in ipairs({ 6, 9, 12, 15 }) do
	for _, tg in ipairs({ 6, 9, 12, 15 }) do
		local r1, r2 = raw(BASS, bg), raw(TREB, tg)
		local k1 = scaleTo0(r1)
		local peak2 = -1 / 0
		for _, f in ipairs(D.GRID) do
			local g = respOf(r1, f) + respOf(r2, f)
			if g > peak2 then peak2 = g end
		end
		local k2 = 0
		if peak2 > 0 and r2 then
			k2 = peak2
			local k = 10 ^ (-peak2 / 20)
			r2.b0, r2.b1, r2.b2 = r2.b0 * k, r2.b1 * k, r2.b2 * k
		end
		local f1, f2 = fitOf(r1), fitOf(r2)
		print(string.format("%+6.1f%+6.1f %8.2f %8.2f %8.2f %8.2f %8.2f %8.2f",
			bg, tg, k1, k2, f1, f2, k1 + k2 + f1 + f2, idealPeak(bg, tg)))
	end
end
