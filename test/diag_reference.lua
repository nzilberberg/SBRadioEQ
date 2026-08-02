--[[
cd /tmp && jive diag_reference

attenDb is the volume the applet adds back after designing a curve. It is only
correct if it restores the UNBOOSTED part of the spectrum to where it sat before
the EQ was touched. That is what "level matched" means to a listener: turn up the
bass, and the voices stay put.

So the test is not whether attenDb is small. It is whether

    realised(f_ref) + attenDb == 0

at a reference frequency the user did not ask to change -- the midrange between
a 150 Hz bass shelf and a 4 kHz treble shelf.

The user's report is that boosting a SECOND band drops the overall level while
one band alone is fine. If that is real, the error will be zero down the first
row and column and grow off-diagonal.
]]

local D = require("eqdesign")
local FS = 44100

local BASS = { kind = "lowshelf",  f0 = 150,  shape = 0.9 }
local TREB = { kind = "highshelf", f0 = 4000, shape = 0.9 }
local F_REF = 900          -- between the two shelves; neither band targets it

local function spec(t, g) return { kind = t.kind, f0 = t.f0, gainDb = g, shape = t.shape } end

local function realisedAt(c, f)
	if not c then return 0 end
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	return D.responseDb(b0, b1, b2, a1, a2, f, FS)
end

print(string.format("Reference frequency %d Hz -- the midrange neither band targets.", F_REF))
print("err = where the midrange actually lands after make-up. 0 = level matched,")
print("negative = the user's music got quieter than before they touched anything.")
print("")
print("  bass  treb   realised   attenDb      err")

local worst = { e = 0 }
for _, bg in ipairs({ 0, 3, 6, 9, 12, 15 }) do
	for _, tg in ipairs({ 0, 3, 6, 9, 12, 15 }) do
		local c1, c2, info = D.designPair(FS, spec(BASS, bg), spec(TREB, tg))
		local r = realisedAt(c1, F_REF) + realisedAt(c2, F_REF)
		local err = r + (info.attenDb or 0)
		if math.abs(err) > math.abs(worst.e) then
			worst = { e = err, bg = bg, tg = tg, r = r, a = info.attenDb }
		end
		print(string.format("%+6.1f%+6.1f  %9.2f  %8.2f  %+7.2f%s",
			bg, tg, r, info.attenDb or 0, err,
			math.abs(err) > 1.0 and "   <==" or ""))
	end
end

print("")
print(string.format("worst: bass %+.0f / treble %+.0f -- midrange lands %+.2f dB off",
	worst.bg, worst.tg, worst.e))

--[[
And the question the whole ceiling argument turns on: is the charge avoidable?

Each section's coefficients must fit the format, which caps a section at roughly
0 dB peak on its own. If that is binding, then two boosted bands genuinely cost
their SUM in make-up and there is nothing to reclaim -- the ceiling is the chip,
not the code. Measure the realised peak of each section separately to see which
of the two is actually pinned.
]]
print("")
print("Is the charge avoidable? Peak of each REALISED section on its own.")
print("A section pinned at ~0 dB is at the format's limit; the cost is the chip.")
print("")
print("  bass  treb   sec1 pk   sec2 pk   sum of pks   charged")
for _, bg in ipairs({ 6, 12, 15 }) do
	for _, tg in ipairs({ 6, 12, 15 }) do
		local c1, c2, info = D.designPair(FS, spec(BASS, bg), spec(TREB, tg))
		local function pk(c)
			if not c then return 0 end
			local best = -1 / 0
			for _, f in ipairs(D.GRID) do
				local v = realisedAt(c, f); if v > best then best = v end
			end
			return best
		end
		local p1, p2 = pk(c1), pk(c2)
		print(string.format("%+6.1f%+6.1f  %8.2f  %8.2f  %11.2f  %8.2f",
			bg, tg, p1, p2, -(p1 + p2), info.attenDb or 0))
	end
end
