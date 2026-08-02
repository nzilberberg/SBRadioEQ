--[[
cd /tmp && jive diag_canboost

THE QUESTION THAT DECIDES THE CEILING.

Make-up for two boosted bands is ~their sum (26.8 dB at +15/+15) rather than the
cascade peak (~15 dB) because BOTH sections end up realising their boost as cut.
Section 1 is held at 0 dB peak by our own scaleTo0() -- the "protect the
intermediate" step -- not by the coefficient format (f1 measures 0.00 everywhere).

That invited the question "does the inter-biquad node have headroom?", which
needs hardware. But there is a prior question that needs nothing:

    CAN a section physically HOLD a boost in its coefficients at all?

Every previous fit measurement was taken AFTER peak-normalisation, which by
construction removes the gain -- so of course it found no penalty. Measure the
IDEAL, un-normalised design instead: if b0/b1/b2 do not fit the Q15 format, the
section cannot carry gain above unity no matter what the signal path allows, the
headroom question is moot, and 26.8 dB is the chip.

Format: N0 and N2 at scale 32768 (|b| < 1), N1 at scale 16384 (|b1| < 2).
]]

local D = require("eqdesign")
local FS = 44100

local function fits(kind, f0, g, s)
	local b0, b1, b2 = D.designIdeal(kind, FS, f0, g, s)
	local n0 = math.abs(b0) * D.SCALE
	local n1 = math.abs(b1) * D.SCALE_2
	local n2 = math.abs(b2) * D.SCALE
	local worst = math.max(n0, n1, n2)
	-- how much the section would have to be scaled down to fit, in dB
	local over = 0
	if worst > 32767 then over = 20 * (math.log(worst / 32767) / math.log(10)) end
	return worst <= 32767, n0, n1, n2, over
end

print("Can a section HOLD the boost, un-normalised? (limit 32767 on each)")
print("")
print("LOWSHELF at S=0.9 -- the bass band, held at 0 dB today by scaleTo0()")
print("   f0   gain        N0        N1        N2   fits?   must lose")
for _, f0 in ipairs({ 80, 150, 266, 400, 800 }) do
	for _, g in ipairs({ 3, 6, 9, 12, 15 }) do
		local okf, n0, n1, n2, over = fits("lowshelf", f0, g, 0.9)
		print(string.format("%5d  %+5.1f  %9.0f %9.0f %9.0f   %-5s  %6.2f dB",
			f0, g, n0, n1, n2, okf and "YES" or "no", over))
	end
end

print("")
print("HIGHSHELF at S=0.9 -- the treble band")
print("   f0   gain        N0        N1        N2   fits?   must lose")
for _, f0 in ipairs({ 2000, 4000, 8000 }) do
	for _, g in ipairs({ 3, 6, 9, 12, 15 }) do
		local okf, n0, n1, n2, over = fits("highshelf", f0, g, 0.9)
		print(string.format("%5d  %+5.1f  %9.0f %9.0f %9.0f   %-5s  %6.2f dB",
			f0, g, n0, n1, n2, okf and "YES" or "no", over))
	end
end

--[[
And the bottom line: the most gain a single section can hold before the format
forces it down. If this is ~0 dB, the ceiling is the format and no amount of
signal-path headroom would help.
]]
print("")
print("Largest boost each band can hold WITHOUT the format forcing a scale-down:")
print("")
print("  kind          f0     max gain that fits")
for _, t in ipairs({ { "lowshelf", 80 }, { "lowshelf", 150 }, { "lowshelf", 400 },
                     { "highshelf", 2000 }, { "highshelf", 4000 }, { "highshelf", 8000 } }) do
	local best = 0
	for g = 0, 20, 0.25 do
		if fits(t[1], t[2], g, 0.9) then best = g else break end
	end
	print(string.format("  %-10s %6d     %+6.2f dB", t[1], t[2], best))
end
