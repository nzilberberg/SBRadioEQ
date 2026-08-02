--[[
cd /tmp && jive diag_intermediate

CLAIM UNDER TEST: live writing sounded worse than bypassing because the five
coefficient writes pass through mixed old/new filters, each held for ~3.25 ms, so
you hear several discontinuities instead of one.

That is checkable. Walk the exact write order applyBSPLive uses (numerators, then
the chosen denominator order) and compute the response of every intermediate
state. If the intermediates sit between old and new, the claim is wrong. If they
swing far outside both, it is right.
]]

local D = require("eqdesign")
local A = require("eqapply")
local FS = 44100

local function resp(c, f)
	local b0,b1,b2,a1,a2 = D.dequantize(c)
	return D.responseDb(b0,b1,b2,a1,a2,f,FS)
end

local FREQS = { 50, 100, 200, 500, 1000, 2000, 5000, 12000 }

-- one knob click on bass gain, mid-range settings
local function band1(g)
	local c1 = D.designPair(FS,
		{ kind="lowshelf",  f0=266,  gainDb=g, shape=1.2 },
		{ kind="highshelf", f0=4384, gainDb=9, shape=0.95 })
	return c1
end

local old, new = band1(8), band1(8.5)
print("bass 8.0 -> 8.5 dB, one click")
print(string.format("old  N0=%d N1=%d N2=%d D1=%d D2=%d", old.N0,old.N1,old.N2,old.D1,old.D2))
print(string.format("new  N0=%d N1=%d N2=%d D1=%d D2=%d", new.N0,new.N1,new.N2,new.D1,new.D2))

-- the order applyBSPLive would use
local order = { "N0", "N1", "N2" }
for _, k in ipairs(A.denomOrder(old, new) or {}) do order[#order+1] = k end
print("write order: " .. table.concat(order, ", "))
print("")

local cur = { N0=old.N0, N1=old.N1, N2=old.N2, D1=old.D1, D2=old.D2 }
print("state          " .. string.rep(" ", 2) ..
      table.concat({ "50Hz","100Hz","200Hz","500Hz","1kHz","2kHz","5kHz","12kHz" }, "   "))
local function row(label, c)
	local s = string.format("%-14s", label)
	for _, f in ipairs(FREQS) do s = s .. string.format("%7.1f", resp(c, f)) end
	return s
end
print(row("old", old))

local worstExcursion = 0
for i, k in ipairs(order) do
	cur[k] = new[k]
	print(row("after " .. k, cur))
	for _, f in ipairs(FREQS) do
		local o, n, c = resp(old, f), resp(new, f), resp(cur, f)
		local lo = math.min(o, n) - 0.5
		local hi = math.max(o, n) + 0.5
		local ex = 0
		if c < lo then ex = lo - c elseif c > hi then ex = c - hi end
		if ex > worstExcursion then worstExcursion = ex end
	end
end
print(row("new", new))
print("")
print(string.format("worst excursion OUTSIDE the old..new range: %.1f dB", worstExcursion))
print("(small => intermediates are benign and the claim is wrong;")
print(" large => each write is its own audible discontinuity)")
