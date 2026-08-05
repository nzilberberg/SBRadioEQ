--[[
SBRadioEQ -- test_eqapply.lua      cd /tmp && jive test_eqapply

THE ROUND TRIP: coefficients written in-process really do arrive in the chip.

Writes to the codec. Everything it applies is peak-normalised (<= 0 dB), so it
can only ever make things quieter -- no loud-audio risk. It restores the 12 dB
bass shelf at the end.

⛔ THE WRITE IS baby_bsp; THE READBACK IS amixer. That split is the point, not an
inconsistency. This file used to write with A.apply -- the amixer shell path --
because amixer is also how you read, so one tool did both halves. That write path
is gone (baby_bsp ships with every Radio firmware, so it was unreachable), and
the round trip now crosses the two: the PRODUCTION writer puts the coefficients
in, and an INDEPENDENT reader gets them back out. That is a stronger test than it
was, because the two halves no longer share an implementation that could be
wrong in the same direction.

The readback undoes the driver's byte swap (A.readBand), which the write path
does not apply -- see eqapply's header.
]]

local D = require("eqdesign")
local A = require("eqapply")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-46s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-46s %s", name, detail or "")) end
end

--[[
⛔ FAIL LOUD, BUT STILL PRINT A SUMMARY. run-suite.sh judges each file by its LAST
LINE matching `failed=0`; a bare error() here loses that line and the run reports
a traceback instead of a verdict.
]]
local okbsp, bsp = pcall(require, "baby_bsp")
if not okbsp then
	print("  FAIL baby_bsp is unavailable -- cannot exercise the write path")
	print("")
	print("passed=0 failed=1")
	return
end

-- Every write below goes through the production path, which restores the PCM
-- volume to a CACHED level; prime it once so the cache is this process's own.
local function write(c1, c2, bypass, prevBypass)
	A.forgetMutePoint(); A.mutePoint()
	return A.applyBSPMuted(bsp, c1, c2, nil, bypass, prevBypass)
end

local FS = 44100

print("=== A. byte-swap helpers (the trap) ===")
-- TI default N0 = 27619 (0x6BE3) is reported by the driver as 58219 (0xE36B).
ok("swap16 undoes the driver swap", A.swap16(58219) == 27619, tostring(A.swap16(58219)))
ok("swap is its own inverse", A.swap16(A.swap16(58219)) == 58219, "")
ok("toSigned on a negative", A.toSigned(A.swap16(26262)) == -27034,
   tostring(A.toSigned(A.swap16(26262))))

print("=== C. round trip through the real codec ===")
local bass,   bi = D.design("highshelf", FS, 150, -12, 0.9)
local treble, ti = D.design("lowshelf",  FS, 4000, -6, 0.9)
ok("bass design verified",   bi.ok, string.format("err=%.3f", bi.maxErrDb))
ok("treble design verified", ti.ok, string.format("err=%.3f", ti.maxErrDb))

local res = write(bass, treble, false, nil)
ok("the write reports success", type(res) == "table" and res.ok == true,
   type(res) == "table" and tostring(res.error or res.writes) or type(res))

local okb, whyb = A.verify("band1", bass)
local okt, whyt = A.verify("band2", treble)
ok("band1 readback matches what we wrote", okb, whyb)
ok("band2 readback matches what we wrote", okt, whyt)
ok("filter is enabled", A.readEnable() == 10, tostring(A.readEnable()))

print("=== D. wholesale bypass ===")
--[[
prevBypass MUST be false here. applyBSPMuted early-returns doing nothing when it
is told the filter is ALREADY bypassed (prevBypass == true), and the readback
below would then be asserting against whatever section C left behind.
]]
local resB = write(nil, nil, true, false)
ok("the bypass reports success", type(resB) == "table" and resB.ok == true,
   type(resB) == "table" and tostring(resB.error) or type(resB))
ok("enable register cleared", A.readEnable() == 0, tostring(A.readEnable()))

print("=== E. repeated applies stay correct ===")
-- Not a timing test. The amixer timing comparison that lived here measured the
-- deleted shell backend; BSP timing is covered by test_bsp_stereo.
for _ = 1, 5 do write(bass, treble, false, true) end
local okr5, why5 = A.verify("band1", bass)
ok("five applies in a row still read back correctly", okr5, why5)

print("=== F. restore the 12 dB shelf ===")
-- Both sections identical, as the working configuration had them.
local restore = { N0 = 16514, N1 = -16201, N2 = 15899, D1 = 32328, D2 = -31899 }
write(restore, restore, false, false)
local okr  = A.verify("band1", restore)
local okr2 = A.verify("band2", restore)
ok("12 dB shelf restored on both sections", okr and okr2 and A.readEnable() == 10, "")

print("")
print(string.format("passed=%d failed=%d", pass, fail))
