--[[
cd /tmp && jive diag_deadband

Making the peak search pole-aware fixed a +9.69 dB overshoot at 18.7 kHz, but
treble 4 kHz / +15 / Q 0.9 now comes out COMPLETELY SILENT -- response -inf, not
merely wrong. A dead band is worse than the bug being fixed, so this traces the
design of that one setting stage by stage instead of reasoning about it.

Note treble 1 kHz / +15 / Q 2.0 was ALREADY -inf before the change, so dead
sections are not purely a regression: the pole-aware search widened a hole that
was already there.

Printed at each stage: the coefficients, what the peak search thinks, and what
the trim loop would therefore do.
]]

local D = require("eqdesign")
local FS = 44100

local function show(tag, x)
	if not x then print(string.format("  %-22s nil", tag)) return end
	print(string.format("  %-22s b0=%+.6f b1=%+.6f b2=%+.6f a1=%+.6f a2=%+.6f",
		tag, x.b0, x.b1, x.b2, x.a1 or 0, x.a2 or 0))
end

-- Lua 5.1's string.format raises on inf/nan ("number expected, got number"),
-- and -inf is exactly the value being investigated, so never hand it to %f.
local function n(v, fmt)
	if v ~= v then return "nan" end
	if v == math.huge then return "+inf" end
	if v == -math.huge then return "-inf" end
	return string.format(fmt or "%.2f", v)
end

local function showQ(tag, c)
	if not c then print(string.format("  %-22s nil", tag)) return end
	-- tostring, never %d: the coefficients themselves turned out to be the
	-- inf/nan values, and %d on those raises rather than printing the evidence.
	print(string.format("  %-22s N0=%s N1=%s N2=%s D1=%s D2=%s",
		tag, tostring(c.N0), tostring(c.N1), tostring(c.N2),
		tostring(c.D1), tostring(c.D2)))
	local peak, pf = D.realisedPeakDb(c, FS)
	local _, _, _, a1, a2 = D.dequantize(c)
	print(string.format("  %-22s realisedPeak=%s dB at %s Hz | poleFreq=%s | poleR=%s",
		"", n(peak), n(pf, "%.0f"),
		n(D.poleFreq(a1, a2, FS) or 0/0, "%.0f"), n(D.poleRadius(a1, a2), "%.6f")))
end

local CASES = {
	{ "highshelf", 4000, 15, 0.9,  "the NEW dead band" },
	{ "highshelf", 1000, 15, 2.0,  "dead BEFORE the change too" },
	{ "highshelf", 16000, 15, 2.0, "the one the fix was for" },
	{ "highshelf", 4000, 15, 0.9,  "repeat, for contrast with lowshelf" },
	{ "lowshelf",  150, 15, 0.9,   "a healthy case" },
}

for _, c in ipairs(CASES) do
	local kind, f0, g, q, note = c[1], c[2], c[3], c[4], c[5]
	print(string.format("=== %s f0=%d gain=%+d Q=%.1f  (%s)", kind, f0, g, q, note))

	-- 1. the ideal design, unnormalised
	local x = {}
	x.b0, x.b1, x.b2, x.a1, x.a2 = D.designIdeal(kind, FS, f0, g, q)
	show("ideal", x)

	-- 2. what the peak search says about the IDEAL response
	do
		local peak = -1 / 0
		for _, f in ipairs(D.GRID) do
			local v = D.responseDb(x.b0, x.b1, x.b2, x.a1, x.a2, f, FS)
			if v > peak then peak = v end
		end
		local pf = D.poleFreq(x.a1, x.a2, FS)
		local atPole = pf and D.responseDb(x.b0, x.b1, x.b2, x.a1, x.a2, pf, FS) or -1/0
		print(string.format("  %-22s grid peak=%+.2f dB | at pole (%s Hz)=%+.2f dB",
			"ideal response", peak, tostring(pf and math.floor(pf) or "none"), atPole))
	end

	-- 3. what designPair actually produces
	local c1, c2, info = D.designPair(FS,
		{ kind = "lowshelf",  f0 = (kind == "lowshelf") and f0 or 150,
		  gainDb = (kind == "lowshelf") and g or 0,
		  shape  = (kind == "lowshelf") and q or 0.9 },
		{ kind = "highshelf", f0 = (kind == "highshelf") and f0 or 4000,
		  gainDb = (kind == "highshelf") and g or 0,
		  shape  = (kind == "highshelf") and q or 0.9 })
	showQ("designPair section1", c1)
	showQ("designPair section2", c2)
	print(string.format("  %-22s attenDb=%.2f  k1=%.2f  k2=%.2f",
		"charge", info.attenDb or 0, info.k1 or 0, info.k2 or 0))
	print("")
end
