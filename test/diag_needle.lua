--[[
cd /tmp && jive diag_needle

A full-blast high-pitched shriek at maximum volume WITH NOTHING PLAYING.

RULED OUT (diag_stability): an unstable filter. 952 designs across the whole
reachable control surface, worst pole radius 0.998039, none at or above 1.0.

What that sweep DID establish is the setup for this one. Poles sitting at
r = 0.998 are a resonance with a gain of roughly 1/(1-r) ~ +54 dB. A shelf's
numerator is supposed to cancel that almost exactly. Quantising the numerator to
16 bits spoils the cancellation slightly, and "slightly" against a +54 dB pole
is not slight.

The normalisation that is supposed to catch a peak like that -- the realised-peak
trim added in designPair -- searches M.GRID, which is 64 points. A resonance at
r = 0.998 has a -3 dB width of about 14 Hz. Sixty-four points spread over three
decades cannot see a 14 Hz needle: adjacent points near 1 kHz are ~250 Hz apart.

So: evaluate every design on a DENSE grid and compare with what the 64-point grid
believes. Anything the coarse grid scores at 0 dB while the dense grid finds a
large peak is a filter shipped with an uncancelled resonance -- inaudible in
silence until something excites it, which at volume 100 is any UI click.
]]

local D = require("eqdesign")
local FS = 44100

local function respOf(c, f)
	if not c then return 0 end
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	return D.responseDb(b0, b1, b2, a1, a2, f, FS)
end

-- What designPair's own normalisation looks at.
local function coarsePeak(c)
	local m = -1 / 0
	for _, f in ipairs(D.GRID) do
		local v = respOf(c, f); if v > m then m = v end
	end
	return m
end

--[[
Dense enough to resolve the needle. r = 0.998 is ~14 Hz wide; a 4000-point log
grid from 20 Hz to 20 kHz gives ~1.7 Hz resolution at 1 kHz, so a peak cannot
hide between samples.
]]
local L0, L1, N = math.log(20), math.log(20000), 4000
local function densePeak(c)
	local m, mf = -1 / 0, 0
	for i = 0, N do
		local f = math.exp(L0 + (L1 - L0) * i / N)
		local v = respOf(c, f)
		if v > m then m, mf = v, f end
	end
	return m, mf
end

print(string.format("M.GRID has %d points -- that is what designPair normalises against.", #D.GRID))
do
	-- how far apart are the coarse points where a needle would hide?
	local g = D.GRID
	local worstGap, at = 0, 0
	for i = 2, #g do
		local gap = g[i] - g[i - 1]
		if gap > worstGap then worstGap, at = gap, g[i - 1] end
	end
	print(string.format("Widest gap between adjacent grid points: %.0f Hz (near %.0f Hz)", worstGap, at))
	print(string.format("A pole at r=0.998 is about %.0f Hz wide at -3 dB.",
		(1 - 0.998) * FS / math.pi))
end

print("")
print("Peak the COARSE grid sees vs what is REALLY there:")
print("")
print("  band  f0     gain   Q     coarse    DENSE    at Hz    hidden")

local worst = { d = -1 / 0 }
local hidden = {}

local function check(kind, f0, g, q)
	local c1, c2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = (kind == "bass") and f0 or 150,
		  gainDb = (kind == "bass") and g or 0, shape = (kind == "bass") and q or 0.9 },
		{ kind = "highshelf", f0 = (kind == "treb") and f0 or 4000,
		  gainDb = (kind == "treb") and g or 0, shape = (kind == "treb") and q or 0.9 })
	local c = (kind == "bass") and c1 or c2
	local cp = coarsePeak(c)
	local dp, df = densePeak(c)
	local gapdB = dp - cp
	if dp > worst.d then
		worst = { d = dp, f = df, c = cp, what = string.format("%s f0=%d gain=%+d Q=%.1f", kind, f0, g, q) }
	end
	if gapdB > 3 then
		hidden[#hidden + 1] = string.format("%s f0=%d gain=%+d Q=%.1f: coarse %+.1f, dense %+.1f at %.0f Hz",
			kind, f0, g, q, cp, dp, df)
	end
	return cp, dp, df, gapdB
end

for _, spec in ipairs({
	{ "bass", 100, 15, 0.2 }, { "bass", 100, 15, 2.0 }, { "bass", 100, -15, 0.2 },
	{ "bass", 150, 15, 0.9 }, { "bass", 150, -15, 2.0 }, { "bass", 266, 12, 1.5 },
	{ "bass", 800, 15, 2.0 }, { "bass", 100,  6, 0.2 },
	{ "treb", 1000, 15, 2.0 }, { "treb", 1000, -15, 2.0 }, { "treb", 4000, 15, 0.9 },
	{ "treb", 16000, 15, 2.0 }, { "treb", 2500, -12, 1.8 },
}) do
	local cp, dp, df, gap = check(spec[1], spec[2], spec[3], spec[4])
	print(string.format("  %-4s %6d  %+5d  %.1f  %+8.2f %+8.2f %8.0f   %s",
		spec[1], spec[2], spec[3], spec[4], cp, dp, df,
		gap > 3 and string.format("%+.1f dB HIDDEN", gap) or ""))
end

print("")
print(string.format("worst realised peak anywhere: %+.2f dB at %.0f Hz (%s)",
	worst.d, worst.f, worst.what))
print(string.format("  the coarse grid scored that same filter at %+.2f dB", worst.c))
print("")
if #hidden > 0 then
	print("FILTERS SHIPPED WITH A RESONANCE THE NORMALISATION CANNOT SEE:")
	for _, h in ipairs(hidden) do print("  " .. h) end
else
	print("No design hid a peak of more than 3 dB from the coarse grid.")
end
