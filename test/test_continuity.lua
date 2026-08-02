--[[
SBRadioEQ -- test_continuity.lua      cd /tmp && jive test_continuity

A control that jumps is unusable. Sweep each parameter one UI step at a time and
measure how far the response moves between adjacent steps. A smooth control
should move a little; a lurch means the design routine is returning something
qualitatively different for a neighbouring input -- almost certainly the silent
Q back-off inside design().

Reports, per sweep: the biggest single-step jump in dB and where it happened,
plus whether the achieved "shape" (the Q actually used) tracks the requested one.
]]

local D = require("eqdesign")
local FS = 44100

local GRID = {}
do
	local l0, l1 = math.log(40), math.log(16000)
	for i = 0, 40 do GRID[#GRID + 1] = math.exp(l0 + (l1 - l0) * i / 40) end
end

local function curveOf(c)
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	local out = {}
	for i, f in ipairs(GRID) do out[i] = D.responseDb(b0, b1, b2, a1, a2, f, FS) end
	return out
end

-- The SAME design without the 16-bit round trip. If this is smooth while the
-- quantised one lurches, the lurch is purely quantisation and no amount of
-- design-side cleverness will fix it -- only restricting the usable range, or
-- drawing the ideal curve, will.
local function idealCurveOf(kind, f0, gainDb, shape)
	local b0, b1, b2, a1, a2 = D.designIdeal(kind, FS, f0, gainDb, shape)
	if not b0 then return nil end
	local out = {}
	for i, f in ipairs(GRID) do out[i] = D.responseDb(b0, b1, b2, a1, a2, f, FS) end
	return out
end

local function maxDiff(c1, c2)
	local m, at = 0, 0
	for i = 1, #c1 do
		local d = math.abs(c1[i] - c2[i])
		if d > m then m, at = d, GRID[i] end
	end
	return m, at
end

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-40s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-40s %s", name, detail or "")) end
end

local function sweep(label, mk, mkIdeal, values, tol)
	print("=== " .. label .. " ===")
	local prev, prevV, prevI
	local worst, worstAt, worstFrom, worstTo = 0, 0, nil, nil
	local worstIdeal = 0
	for _, v in ipairs(values) do
		local c = mk(v)
		local cur = curveOf(c)
		local ide = mkIdeal and mkIdeal(v) or nil
		if prev then
			local d, atF = maxDiff(prev, cur)
			if d > worst then worst, worstAt, worstFrom, worstTo = d, atF, prevV, v end
		end
		if prevI and ide then
			local d = maxDiff(prevI, ide)
			if d > worstIdeal then worstIdeal = d end
		end
		prev, prevV, prevI = cur, v, ide
	end
	print(string.format("     quantised : worst step %.2f dB at %.0f Hz (%.3f -> %.3f)",
	      worst, worstAt, worstFrom or 0, worstTo or 0))
	print(string.format("     IDEAL     : worst step %.2f dB   <- how much is quantisation",
	      worstIdeal))
	ok(label .. " is smooth", worst <= tol, string.format("%.2f dB (tol %.1f)", worst, tol))
end

-- Q sweep at the UI's own step size (0.05), fixed 150 Hz / +12 dB bass
local qs = {}
for q = 0.2, 2.0001, 0.05 do qs[#qs + 1] = q end
sweep("Q sweep, lowshelf 150 Hz +12 dB",
      function(q) return D.design("lowshelf", FS, 150, 12, q) end,
      function(q) return idealCurveOf("lowshelf", 150, 12, q) end, qs, 1.5)

-- Gain sweep at the UI's step (0.5 dB)
local gs = {}
for g = 0, 15.001, 0.5 do gs[#gs + 1] = g end
sweep("Gain sweep, lowshelf 150 Hz Q0.9",
      function(g) return D.design("lowshelf", FS, 150, g, 0.9) end,
      function(g) return idealCurveOf("lowshelf", 150, g, 0.9) end, gs, 1.5)

-- Frequency sweep at the UI's step (x1.04 per click)
local fs = {}
local f = 100
while f <= 800 do fs[#fs + 1] = math.floor(f + 0.5); f = f * 1.04 end
sweep("Freq sweep, lowshelf +12 dB Q0.9",
      function(x) return D.design("lowshelf", FS, x, 12, 0.9) end,
      function(x) return idealCurveOf("lowshelf", x, 12, 0.9) end, fs, 1.5)

print("")
print(string.format("passed=%d failed=%d", pass, fail))
