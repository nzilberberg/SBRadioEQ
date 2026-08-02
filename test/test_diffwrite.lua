--[[
SBRadioEQ -- test_diffwrite.lua      cd /tmp && jive test_diffwrite

applyBSPDiff shortens the bypass window by writing only coefficients that moved.
Every write costs ~3.25 ms of UNFILTERED audio at boosted volume, so the count is
the thing that matters audibly.

Uses a STUB bsp that records calls instead of touching the codec -- this test must
not disturb whatever EQ the user currently has set.
]]

local A = require("eqapply")
local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-48s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-48s %s", name, detail or "")) end
end

local function stub()
	local s = { calls = {}, coeffs = 0, enables = 0 }
	function s:setMixer(name, a, b)
		s.calls[#s.calls + 1] = { name = name, a = a, b = b }
		if name == A.NAME.enable then s.enables = s.enables + 1 else s.coeffs = s.coeffs + 1 end
	end
	return s
end

local function pair(bg, tg)
	local c1, c2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = bg, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = tg, shape = 0.9 })
	return c1, c2
end

print("=== first write with no history writes everything ===")
local b = stub()
local c1, c2 = pair(12, 6)
local n = A.applyBSPDiff(b, c1, c2, nil, false, nil)
ok("all 10 coefficients written", n == 10, tostring(n) .. " writes")
ok("bracketed by bypass + enable", b.enables == 2, tostring(b.enables) .. " enable writes")

print("=== re-applying the SAME design writes nothing ===")
b = stub()
n = A.applyBSPDiff(b, c1, c2, { c1 = c1, c2 = c2 }, false, false)
ok("no coefficient writes", n == 0, tostring(n) .. " writes")
ok("filter never bypassed", b.enables == 0, tostring(b.enables) .. " enable writes")

print("=== one knob click writes only what moved ===")
local d1, d2 = pair(12.5, 6)
b = stub()
n = A.applyBSPDiff(b, d1, d2, { c1 = c1, c2 = c2 }, false, false)
ok("fewer than 10 writes", n < 10, tostring(n) .. " of 10")
ok("still bracketed", b.enables == 2, tostring(b.enables) .. " enable writes")
print(string.format("     -> bypass window ~%.0f ms instead of ~%.0f ms", n * 3.25, 10 * 3.25))

print("=== stereo: every coefficient write carries BOTH channels ===")
local bothOk = true
for _, c in ipairs(b.calls) do
	if c.name ~= A.NAME.enable and (c.a == nil or c.b == nil or c.a ~= c.b) then bothOk = false end
end
ok("L and R both supplied on every write", bothOk,
   "single-arg setMixer would zero the right channel")

print("=== bypass path ===")
b = stub()
n = A.applyBSPDiff(b, c1, c2, { c1 = c1, c2 = c2 }, true, false)
ok("bypass writes no coefficients", n == 0, tostring(n))
ok("bypass sets the enable register once", b.enables == 1, tostring(b.enables))
b = stub()
n = A.applyBSPDiff(b, c1, c2, { c1 = c1, c2 = c2 }, true, true)
ok("already bypassed: touches nothing", b.enables == 0 and n == 0, "")

print("")
print(string.format("passed=%d failed=%d", pass, fail))
