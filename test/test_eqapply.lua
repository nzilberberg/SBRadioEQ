--[[
SBRadioEQ -- test_eqapply.lua      cd /tmp && jive test_eqapply

Writes to the codec. Everything it applies is peak-normalised (<= 0 dB), so it
can only ever make things quieter -- no loud-audio risk. It restores the 12 dB
bass shelf at the end.
]]

local D = require("eqdesign")
local A = require("eqapply")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-46s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-46s %s", name, detail or "")) end
end

local FS = 44100

print("=== A. byte-swap helpers (the trap) ===")
-- TI default N0 = 27619 (0x6BE3) is reported by the driver as 58219 (0xE36B).
ok("swap16 undoes the driver swap", A.swap16(58219) == 27619, tostring(A.swap16(58219)))
ok("swap is its own inverse", A.swap16(A.swap16(58219)) == 58219, "")
ok("toSigned on a negative", A.toSigned(A.swap16(26262)) == -27034,
   tostring(A.toSigned(A.swap16(26262))))

print("=== B. command construction is pure and correct ===")
local c1 = { N0 = 16981, N1 = -15070, N2 = 13169, D1 = 30071, D2 = -27384 }
local c2 = D.FLAT
local cmd = A.buildCommand(c1, c2, A.ENABLE_BOTH)
ok("bypasses before writing", cmd:match("^[^;]*numid=21 0,0") ~= nil, "")
ok("re-enables at the end", cmd:match("numid=21 10,10[^;]*$") ~= nil, "")
ok("negative written as unsigned", cmd:match("numid=23 50466,50466") ~= nil, "")
ok("positive written as-is", cmd:match("numid=22 16981,16981") ~= nil, "")
ok("band 2 uses the second biquad", cmd:match("numid=25 32767,32767") ~= nil, "")
local n = 0; for _ in cmd:gmatch("cset") do n = n + 1 end
ok("12 csets total (2 enable + 10 coeff)", n == 12, tostring(n) .. " csets")

print("=== C. round trip through the real codec ===")
local bass,   bi = D.design("highshelf", FS, 150, -12, 0.9)
local treble, ti = D.design("lowshelf",  FS, 4000, -6, 0.9)
ok("bass design verified",   bi.ok, string.format("err=%.3f", bi.maxErrDb))
ok("treble design verified", ti.ok, string.format("err=%.3f", ti.maxErrDb))

A.apply(bass, treble, false)
local okb, whyb = A.verify("band1", bass)
local okt, whyt = A.verify("band2", treble)
ok("band1 readback matches what we wrote", okb, whyb)
ok("band2 readback matches what we wrote", okt, whyt)
ok("filter is enabled", A.readEnable() == 10, tostring(A.readEnable()))

print("=== D. wholesale bypass ===")
A.apply(nil, nil, true)
ok("enable register cleared", A.readEnable() == 0, tostring(A.readEnable()))

print("=== E. amixer path: correct but slow (informational) ===")
-- Measured ~1100 ms per full apply -- 12 process spawns on a 360 MHz core. That
-- is why the LIVE path is baby_bsp (~39 ms); see test_bsp_stereo. amixer stays
-- for readback and as a fallback, so what matters here is correctness, not speed.
local N = 5
local t0 = os.time()
for _ = 1, N do A.apply(bass, treble, false) end
local t1 = os.time()
print(string.format("     %d full applies in %d s  ->  ~%.0f ms each (informational)",
      N, t1 - t0, ((t1 - t0) * 1000) / N))
local okr5, why5 = A.verify("band1", bass)
ok("repeated applies stay correct", okr5, why5)

print("=== F. restore the 12 dB shelf ===")
-- Both sections identical, as the working configuration had them.
local restore = { N0 = 16514, N1 = -16201, N2 = 15899, D1 = 32328, D2 = -31899 }
A.apply(restore, restore, false)
local okr = A.verify("band1", restore)
local okr2 = A.verify("band2", restore)
ok("12 dB shelf restored on both sections", okr and okr2 and A.readEnable() == 10, "")

print("")
print(string.format("passed=%d failed=%d", pass, fail))
