--[[
cd /tmp && jive diag_graphtruth

"I can set bass 100 Hz / +15 dB / Q 2.0. Is the graph telling lies?"

Answerable exactly. The applet draws self.ideal1/ideal2 -- the UNQUANTISED design
-- offset by attenDb. The chip runs the quantised coefficients. So the question
is simply how far apart those two curves are at that setting.

Reported per frequency, for the setting asked about and a few neighbours, so the
answer is a number and not an adjective.
]]

local D = require("eqdesign")
local FS = 44100

local PROBE = { 30, 40, 50, 60, 80, 100, 150, 200, 300, 500, 1000, 3000, 8000 }

local function compare(bf, bg, bq, label)
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
	local atten = i.attenDb or 0
	local id = i.ideal1

	print(string.format("=== %s : bass %d Hz / %+d dB / Q %.1f   (make-up %.2f dB)",
		label, bf, bg, bq, atten))
	print("     Hz |  GRAPH SHOWS  |  CHIP DOES  |  difference")

	local worst, worstF = 0, 0
	for _, f in ipairs(PROBE) do
		-- what the graph draws: ideal response, offset by the make-up
		local g = atten
		if id then g = g + D.responseDb(id.b0, id.b1, id.b2, id.a1, id.a2, f, FS) end

		-- what the chip produces: quantised response, plus the same make-up
		local b0, b1, b2, a1, a2 = D.dequantize(c1)
		local h = atten + D.responseDb(b0, b1, b2, a1, a2, f, FS)

		local d = h - g
		if math.abs(d) > math.abs(worst) then worst, worstF = d, f end
		print(string.format("  %5d | %+11.2f   | %+9.2f   | %+8.2f %s",
			f, g, h, d, (math.abs(d) > 1.0) and "  <==" or ""))
	end
	print(string.format("  worst difference: %+.2f dB at %d Hz", worst, worstF))
	print("")
	return math.abs(worst)
end

compare(100, 15, 2.0, "THE SETTING ASKED ABOUT")
compare(100, 15, 0.9, "same corner, gentler Q")
compare(100,  6, 2.0, "same corner, smaller boost")
compare(400, 15, 2.0, "same gain and Q, higher corner")

print("How widespread is it? Worst graph-vs-chip difference, whole surface:")
print("  (only counting 40 Hz and up -- below that the driver produces nothing)")
local worstAll, whereAll = 0, ""
for _, bf in ipairs({ 100, 150, 220, 266, 330, 400, 600, 800 }) do
for _, bg in ipairs({ 6, 12, 15 }) do
for _, bq in ipairs({ 0.2, 0.9, 1.5, 2.0 }) do
	local c1, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
	local id = i.ideal1
	local b0, b1, b2, a1, a2 = D.dequantize(c1)
	for _, f in ipairs({ 40, 50, 60, 80, 100, 150, 200, 400, 1000 }) do
		local g = id and D.responseDb(id.b0, id.b1, id.b2, id.a1, id.a2, f, FS) or 0
		local h = D.responseDb(b0, b1, b2, a1, a2, f, FS)
		local d = math.abs(h - g)
		if d > worstAll then
			worstAll = d
			whereAll = string.format("bass %d / %+d / Q%.1f at %d Hz", bf, bg, bq, f)
		end
	end
end end end
print(string.format("  worst: %.2f dB  (%s)", worstAll, whereAll))
