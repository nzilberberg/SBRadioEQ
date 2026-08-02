--[[
SBRadioEQ -- test_eqdesign.lua
Runs in the REAL SqueezePlay Lua 5.1 on the Radio:   cd /tmp && jive test_eqdesign
]]

local M = require("eqdesign")

local pass, fail = 0, 0

local function ok(name, cond, detail)
	if cond then
		pass = pass + 1
		print(string.format("  ok   %-46s %s", name, detail or ""))
	else
		fail = fail + 1
		print(string.format("  FAIL %-46s %s", name, detail or ""))
	end
end

local function near(a, b, tol)
	return math.abs(a - b) <= tol
end

local FS = 44100

print("=== A. external reference: TI Table 10-4 defaults ===")
-- Datasheet: 0 dB from dc to ~150 Hz, rolling off to -3 dB (CASCADE of both
-- identical sections). If dequantize+responseDb reproduce that, they are right.
local ti = { N0 = 27619, N1 = -27034, N2 = 26461, D1 = 32131, D2 = -31506 }
local tb0, tb1, tb2, ta1, ta2 = M.dequantize(ti)
local function tiDb(f) return 2 * M.responseDb(tb0, tb1, tb2, ta1, ta2, f, FS) end
ok("cascade ~0 dB at 20 Hz",   near(tiDb(20),   0.00, 0.15), string.format("%.2f dB", tiDb(20)))
ok("cascade ~-1.6 dB at 150",  near(tiDb(150), -1.58, 0.10), string.format("%.2f dB", tiDb(150)))
ok("cascade ~-3.0 dB at 5k",   near(tiDb(5000), -3.00, 0.05), string.format("%.2f dB", tiDb(5000)))
ok("single section stable",    M.poleRadius(ta1, ta2) < 1,
   string.format("poleR=%.5f", M.poleRadius(ta1, ta2)))

print("=== B. the flat section (0 dB band) ===")
local fc, fi = M.design("highshelf", FS, 150, 0, 0.9)
ok("0 dB returns FLAT", fc.N0 == 32767 and fc.N1 == 0 and fc.N2 == 0
   and fc.D1 == 0 and fc.D2 == 0, "N0=" .. fc.N0)
ok("flat reason", fi.reason == "flat" and fi.ok, tostring(fi.reason))
local qb0, qb1, qb2, qa1, qa2 = M.dequantize(M.FLAT)
local flatErr = 0
for _, f in ipairs({20, 100, 1000, 10000, 20000}) do
	local d = M.responseDb(qb0, qb1, qb2, qa1, qa2, f, FS)
	if math.abs(d) > flatErr then flatErr = math.abs(d) end
end
ok("flat is flat everywhere", flatErr < 0.001, string.format("max |dB|=%.6f", flatErr))

print("=== C. quantise / dequantise round trip ===")
local rb0, rb1, rb2, ra1, ra2 = 0.518210, -0.919806, 0.401894, -1.835403, 0.835699
local rq = M.quantize(rb0, rb1, rb2, ra1, ra2)
local db0, db1, db2, da1, da2 = M.dequantize(rq)
ok("b0 round trips", near(db0, rb0, 1/32768), string.format("%.6f", db0))
ok("b1 round trips", near(db1, rb1, 2/32768), string.format("%.6f", db1))
ok("a1 round trips", near(da1, ra1, 2/32768), string.format("%.6f", da1))
print(string.format("     integers: N0=%d N1=%d N2=%d D1=%d D2=%d  <-- cross-check these",
      rq.N0, rq.N1, rq.N2, rq.D1, rq.D2))

print("=== D. unsigned conversion for amixer ===")
local au = M.toAmixer({ N0 = 16981, N1 = -15070, N2 = 13169, D1 = 30071, D2 = -27384 })
ok("negative -> +65536", au.N1 == 50466 and au.D2 == 38152,
   string.format("N1=%d D2=%d", au.N1, au.D2))
ok("positive untouched", au.N0 == 16981 and au.D1 == 30071, "")

print("=== E. verification actually rejects the bad case ===")
-- Q=8 peaking at 100 Hz asking -6 dB delivers +2.3 dB while STABLE. The design
-- routine must not hand that back at Q=8.
local bc, bi = M.design("peaking", FS, 100, -6, 8)
ok("Q=8 @100Hz was backed off or refused", (not bi.ok) or bi.shape < 8,
   string.format("ok=%s shape=%.3f err=%.2f", tostring(bi.ok), bi.shape, bi.maxErrDb))
if bi.ok then
	local eb0, eb1, eb2, ea1, ea2 = M.dequantize(bc)
	local got = M.responseDb(eb0, eb1, eb2, ea1, ea2, 100, FS)
	ok("accepted design has right SIGN at f0", got < 0, string.format("%.2f dB", got))
end

print("=== F. benign cases must still succeed ===")
for _, c in ipairs({
	{ "highshelf", 150,  -12, 0.9 },
	{ "highshelf", 250,  -15, 0.9 },
	{ "lowshelf",  4000, -12, 0.9 },
	{ "lowshelf",  4000,  12, 0.9 },
	{ "peaking",   1000,  -6, 4   },
	{ "peaking",   1000,   6, 2   },
}) do
	local cc, ci = M.design(c[1], FS, c[2], c[3], c[4])
	local nb0, nb1, nb2, na1, na2 = M.dequantize(cc)
	ok(string.format("%s %dHz %+ddB", c[1], c[2], c[3]),
	   ci.ok and M.poleRadius(na1, na2) < 1,
	   string.format("err=%.3f poleR=%.5f shape=%.2f atten=%.1f",
	                 ci.maxErrDb, ci.poleR, ci.shape, ci.attenDb))
end

print("=== F2. a BOOST is realised as cut-elsewhere ===")
-- The chip cannot express gain > 0 dB. A +12 dB band must come back as a curve
-- whose peak is 0 dB, everything else 12 dB down, and attenDb reporting the
-- make-up the caller owes.
local pc, pi = M.design("lowshelf", FS, 4000, 12, 0.9)
ok("+12 dB verifies", pi.ok, string.format("err=%.3f", pi.maxErrDb))
ok("reports ~12 dB make-up", near(pi.attenDb, 12, 0.6), string.format("atten=%.2f", pi.attenDb))
local pb0, pb1, pb2, pa1, pa2 = M.dequantize(pc)
-- A LOW shelf boosts the LOW end, so 20 Hz is the peak and 20 kHz the reference.
local pLow  = M.responseDb(pb0, pb1, pb2, pa1, pa2, 20, FS)
local pHigh = M.responseDb(pb0, pb1, pb2, pa1, pa2, 20000, FS)
ok("boosted band sits at 0 dB, not above", pLow <= 0.05,
   string.format("%.3f dB at 20 Hz", pLow))
ok("rest of the band is cut instead", near(pHigh, -12, 0.6),
   string.format("%.2f dB at 20 kHz", pHigh))
ok("relative lift is the 12 dB asked for", near(pLow - pHigh, 12, 0.6),
   string.format("%.2f dB", pLow - pHigh))

print("=== G. maxShape falls with frequency ===")
local q1k  = M.maxShape("peaking", FS, 1000, -6)
local q100 = M.maxShape("peaking", FS, 100,  -6)
local q60  = M.maxShape("peaking", FS, 60,   -6)
ok("Q ceiling 1k >= 100Hz", q1k >= q100, string.format("1k=%.2f 100=%.2f", q1k, q100))
ok("Q ceiling 100 >= 60Hz", q100 >= q60, string.format("100=%.2f 60=%.2f", q100, q60))

print("=== H. volume curve / headroom ===")
ok("volume 100 -> 0 dB headroom", near(M.headroomDb(100), 0, 0.01),
   string.format("%.2f", M.headroomDb(100)))
ok("volume 40 -> ~29.6 dB",  near(M.headroomDb(40), 29.6, 0.1),
   string.format("%.2f", M.headroomDb(40)))
ok("volume 25 -> ~37 dB",    near(M.headroomDb(25), 37.0, 0.1),
   string.format("%.2f", M.headroomDb(25)))
ok("curve continuous at 25", near(M.volumeToDb(25), -37, 0.01),
   string.format("%.3f", M.volumeToDb(25)))

print("=== I. make-up cap is honoured ===")
-- At high volume there is little headroom to make the level back up, so the
-- caller can cap how much attenuation it is willing to accept.
local hc, hi = M.design("highshelf", FS, 150, 12, 0.9, { maxAttenDb = 3 })
ok("boost needing more make-up than allowed is refused", not hi.ok, tostring(hi.reason))
local hc2, hi2 = M.design("highshelf", FS, 150, 12, 0.9, { maxAttenDb = 30 })
ok("same boost allowed with ample make-up", hi2.ok,
   string.format("atten=%.2f", hi2.attenDb or -1))

print("")
print(string.format("passed=%d failed=%d", pass, fail))
