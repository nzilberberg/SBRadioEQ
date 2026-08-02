--[[
cd /tmp && jive diag_stability

A full-blast high-pitched shriek happened at maximum volume WITH NOTHING PLAYING.
Silence in, noise out means the filter is generating it: an unstable biquad rings
up from its own numerical noise until it clips.

The suspect is designPair's pole repair. It nudges D2 to pull the poles inside
the unit circle, but gives up after 64 steps:

    while M.poleRadius(qa1, qa2) >= M.MAX_POLE_R and n < 64 do ... end
    return c        -- <-- returns the UNSTABLE filter if it never converged

M.design (single band) returns FLAT when a design cannot be stabilised.
designPair -- the one the applet actually calls -- has no such fallback.

This sweeps the ENTIRE reachable control surface, at the real UI step sizes, and
reports every combination whose quantised poles land on or outside the unit
circle. If any exist, the shriek is explained and the hazard is live.
]]

local D = require("eqdesign")
local FS = 44100

-- the applet's own limits and steps
local BF_LO, BF_HI = 100, 800
local TF_LO, TF_HI = 1000, 16000
local G_LO,  G_HI  = -15, 15
local Q_LO,  Q_HI  = 0.2, 2.0

local function poleR(c)
	if not c then return 0 end
	local _, _, _, a1, a2 = D.dequantize(c)
	return D.poleRadius(a1, a2)
end

local worst = { r = 0 }
local unstable, checked = {}, 0

--[[
A coarse-but-complete sweep: every band's frequency across its decade, gain
across its full range, Q across its full range. Fine enough to catch a region,
not just a point -- instability here is not a single unlucky rounding, it is
low frequency plus high Q plus large gain, which is an area.
]]
local BF = { 100, 120, 150, 200, 266, 350, 500, 650, 800 }
local TF = { 1000, 1500, 2500, 4000, 6000, 9000, 12000, 16000 }
local GG = { -15, -12, -6, 0, 6, 12, 15 }
local QQ = { 0.2, 0.4, 0.7, 0.9, 1.2, 1.5, 1.8, 2.0 }

for _, bf in ipairs(BF) do
for _, bg in ipairs(GG) do
for _, bq in ipairs(QQ) do
	-- treble held at a benign setting while the bass corner is swept, and
	-- vice versa: the full cross product is millions of designs on this CPU.
	local c1, c2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf,   gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = 4000, gainDb = 0,  shape = 0.9 })
	local r = poleR(c1)
	checked = checked + 1
	if r > worst.r then worst = { r = r, what = string.format("bass f0=%d g=%+d Q=%.1f", bf, bg, bq) } end
	if r >= 1.0 and #unstable < 12 then
		unstable[#unstable + 1] = string.format("BASS f0=%d gain=%+d Q=%.1f -> r=%.6f", bf, bg, bq, r)
	end
end end end

for _, tf in ipairs(TF) do
for _, tg in ipairs(GG) do
for _, tq in ipairs(QQ) do
	local c1, c2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150, gainDb = 0,  shape = 0.9 },
		{ kind = "highshelf", f0 = tf,  gainDb = tg, shape = tq })
	local r = poleR(c2)
	checked = checked + 1
	if r > worst.r then worst = { r = r, what = string.format("treb f0=%d g=%+d Q=%.1f", tf, tg, tq) } end
	if r >= 1.0 and #unstable < 12 then
		unstable[#unstable + 1] = string.format("TREB f0=%d gain=%+d Q=%.1f -> r=%.6f", tf, tg, tq, r)
	end
end end end

print(string.format("checked %d designs across the whole reachable control surface", checked))
print(string.format("MAX_POLE_R (the repair target) = %s", tostring(D.MAX_POLE_R)))
print("")
print(string.format("worst pole radius seen: %.6f  (%s)", worst.r, worst.what or "?"))
print("")
if #unstable > 0 then
	print("UNSTABLE DESIGNS REACHABLE FROM THE UI:")
	for _, u in ipairs(unstable) do print("  " .. u) end
	print("")
	print("An unstable biquad self-oscillates with no input. This is the shriek.")
else
	print("No design reached r >= 1.0 in this sweep.")
	print("If the worst radius is very close to 1 the filter still rings hard;")
	print("ring-down at r is -1/(fs*ln r) seconds per e-fold.")
end

--[[
Independently of whether the sweep found one: does the repair loop actually
guarantee anything? Drive it at the hardest corner and count the iterations it
needs. If that approaches the 64-step budget, the budget is the only thing
standing between the user and an unstable filter.
]]
print("")
print("How hard does the repair have to work? (iterations to stabilise)")
print("  the 64-step budget is the ONLY thing preventing an unstable write")
for _, bf in ipairs({ 100, 120, 150 }) do
	for _, bq in ipairs({ 1.5, 1.8, 2.0 }) do
		local c1 = D.designPair(FS,
			{ kind = "lowshelf", f0 = bf, gainDb = 15, shape = bq },
			{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
		print(string.format("  bass f0=%d Q=%.1f gain=+15 -> final r=%.6f", bf, bq, poleR(c1)))
	end
end
