--[[
SBRadioEQ -- test_bsp_stereo.lua     cd /tmp && jive test_bsp_stereo

setMixer takes ONE integer but the coefficient controls carry TWO values (L,R).
If only the left channel lands, the two channels run different filters and the
image collapses. Verify BOTH, and pin down the per-write cost properly (the
previous run hit the 1 s clock floor).
]]

local A   = require("eqapply")
local bsp = require("baby_bsp")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-42s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-42s %s", name, detail or "")) end
end

-- Full "values=L,R" for a numid, both byte-swapped back to true coefficients.
local function readPair(numid)
	local fh = io.popen(string.format("%s -c %d cget numid=%d 2>/dev/null", A.AMIXER, A.CARD, numid))
	local out = fh:read("*a"); fh:close()
	local l, r = out:match(":%s*values=(%-?%d+),(%-?%d+)")
	if not l then return nil end
	return A.toSigned(A.swap16(tonumber(l))), A.toSigned(A.swap16(tonumber(r)))
end

print("=== A. does one setMixer write BOTH channels? ===")
-- Start from a known-different state so a stale channel is visible.
os.execute(string.format("%s -c %d cset numid=%d 0,0 >/dev/null 2>&1",
           A.AMIXER, A.CARD, A.NUMID.band1.N0))
local zl, zr = readPair(A.NUMID.band1.N0)
ok("pre-state cleared on both channels", zl == 0 and zr == 0,
   string.format("L=%s R=%s", tostring(zl), tostring(zr)))

local V = 16981
-- ONE argument: reproduces the bug, and must stay in the suite as the regression.
bsp:setMixer("Audio Effects Filter N0 Coefficient", V)
local l1, r1 = readPair(A.NUMID.band1.N0)
ok("single-arg setMixer zeroes the RIGHT channel", l1 == V and r1 == 0,
   string.format("L=%s R=%s  (this is the bug)", tostring(l1), tostring(r1)))

-- Two arguments: the fix.
os.execute(string.format("%s -c %d cset numid=%d 0,0 >/dev/null 2>&1",
           A.AMIXER, A.CARD, A.NUMID.band1.N0))
A.setStereo(bsp, A.NAME.band1.N0, V)
local l, r = readPair(A.NUMID.band1.N0)
ok("setStereo writes left",  l == V, string.format("L=%s", tostring(l)))
ok("setStereo writes right", r == V, string.format("R=%s", tostring(r)))

print("=== B. negative coefficients survive the round trip ===")
-- The control is unsigned 0..65535, so the caller passes the unsigned form.
local NEG = -16201
A.setStereo(bsp, A.NAME.band1.N1, NEG + 65536)
local nl, nr = readPair(A.NUMID.band1.N1)
ok("negative lands on both channels", nl == NEG and nr == NEG,
   string.format("L=%s R=%s want=%d", tostring(nl), tostring(nr), NEG))

print("=== B2. a full BSP apply lands on both channels ===")
local D = require("eqdesign")
local bb = D.design("highshelf", 44100, 150, -12, 0.9)
local tt = D.design("lowshelf",  44100, 4000, -6, 0.9)
A.applyBSP(bsp, bb, tt, false)
local allOk, detail = true, ""
for _, band in ipairs({ "band1", "band2" }) do
	local want = (band == "band1") and bb or tt
	for _, k in ipairs({ "N0", "N1", "N2", "D1", "D2" }) do
		local L, R = readPair(A.NUMID[band][k])
		if L ~= want[k] or R ~= want[k] then
			allOk = false
			detail = string.format("%s.%s L=%s R=%s want=%d", band, k,
			                       tostring(L), tostring(R), want[k])
		end
	end
end
ok("all 10 coefficients correct on BOTH channels", allOk, detail)
ok("filter enabled after BSP apply", A.readEnable() == 10, tostring(A.readEnable()))

print("=== C. per-write cost, past the clock floor ===")
local N = 4000
local t0 = os.time()
for _ = 1, N do bsp:setMixer("Audio Effects Filter N0 Coefficient", V) end
local t1 = os.time()
local ms = ((t1 - t0) * 1000) / N
print(string.format("     %d writes in %d s  ->  %.3f ms each", N, t1 - t0, ms))
print(string.format("     a full 12-write apply  ->  ~%.1f ms", ms * 12))
ok("full apply comfortably under 50 ms", ms * 12 < 50, string.format("%.1f ms", ms * 12))

print("=== D. restore the 12 dB shelf ===")
local restore = { N0 = 16514, N1 = -16201, N2 = 15899, D1 = 32328, D2 = -31899 }
-- The production writer, not the deleted shell path: it keeps the PCM mute
-- around the bypass window and returns a result instead of throwing.
A.forgetMutePoint(); A.mutePoint()
A.applyBSPMuted(bsp, restore, restore, nil, false, false)
local okr, whyr = A.verify("band1", restore)
local okr2 = A.verify("band2", restore)
ok("restored on both sections", okr and okr2 and A.readEnable() == 10, whyr)

print("")
print(string.format("passed=%d failed=%d", pass, fail))
