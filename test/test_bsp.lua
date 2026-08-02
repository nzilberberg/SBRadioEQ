--[[
SBRadioEQ -- test_bsp.lua      cd /tmp && jive test_bsp

Decides the interaction model. amixer costs ~1200 ms for a full apply (12 process
spawns on a 360 MHz core), which is far too slow for live knob updates. baby_bsp
is an in-process Lua C module -- if setMixer accepts the coefficient controls,
live updating is viable; if it does not, the UI has to defer writes.

Everything written here is <= 0 dB. Restores the 12 dB shelf at the end.
]]

local A = require("eqapply")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-44s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-44s %s", name, detail or "")) end
end

print("=== A. can we load the BSP at all? ===")
local okload, bsp = pcall(require, "baby_bsp")
ok("require('baby_bsp')", okload, okload and "loaded" or tostring(bsp))
if not okload then
	print("passed=" .. pass .. " failed=" .. (fail + 1))
	return
end

print("=== B. read a known control through the BSP ===")
local okget, enableVal = pcall(function() return bsp:getMixer("Audio Codec Digital Filter Control") end)
ok("getMixer(enable register)", okget, okget and tostring(enableVal) or tostring(enableVal))

local okget2, n0 = pcall(function() return bsp:getMixer("Audio Effects Filter N0 Coefficient") end)
ok("getMixer(N0 coefficient)", okget2, okget2 and tostring(n0) or tostring(n0))

print("=== C. THE question: does setMixer take a coefficient? ===")
-- Write a value we can recognise, then read it back through amixer (which we
-- know how to parse, byte-swap included).
local TESTVAL = 16981
local okset, seterr = pcall(function() bsp:setMixer("Audio Effects Filter N0 Coefficient", TESTVAL) end)
ok("setMixer(N0, integer) did not error", okset, okset and "" or tostring(seterr))

if okset then
	local raw = A.readRaw(A.NUMID.band1.N0)
	local trueVal = raw and A.toSigned(A.swap16(raw)) or nil
	ok("chip actually holds the written value", trueVal == TESTVAL,
	   string.format("raw=%s true=%s expected=%d", tostring(raw), tostring(trueVal), TESTVAL))
end

print("=== D. timing: BSP vs amixer ===")
local N = 200
local t0 = os.time()
for _ = 1, N do pcall(function() bsp:setMixer("Audio Effects Filter N0 Coefficient", TESTVAL) end) end
local t1 = os.time()
local bspMs = ((t1 - t0) * 1000) / N
print(string.format("     %d setMixer calls in %d s  ->  ~%.1f ms each", N, t1 - t0, bspMs))

local M = 5
local one = string.format("%s -c %d cset numid=%d %d,%d >/dev/null 2>&1",
                          A.AMIXER, A.CARD, A.NUMID.band1.N0, TESTVAL, TESTVAL)
local t2 = os.time()
for _ = 1, M do os.execute(one) end
local t3 = os.time()
local amixerMs = ((t3 - t2) * 1000) / M
print(string.format("     %d amixer spawns in %d s  ->  ~%.0f ms each", M, t3 - t2, amixerMs))

ok("BSP is usable for live updates (10 writes < 100 ms)", bspMs * 10 < 100,
   string.format("~%.1f ms x 10 = %.0f ms", bspMs, bspMs * 10))

print("=== E. restore the 12 dB shelf ===")
local restore = { N0 = 16514, N1 = -16201, N2 = 15899, D1 = 32328, D2 = -31899 }
A.apply(restore, restore, false)
local okr, whyr = A.verify("band1", restore)
ok("restored", okr and A.readEnable() == 10, whyr .. " enable=" .. tostring(A.readEnable()))

print("")
print(string.format("passed=%d failed=%d", pass, fail))
