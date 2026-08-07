--[[
SBRadioEQ -- test_clipgate.lua      cd /tmp && jive test_clipgate

THE PRODUCTION BOUNDARY FAILS CLOSED: designPair may not return an over-unity
filter as an ordinary successful design, no matter what its bounded correction
search managed to find.

WHY THIS FILE EXISTS

correct() in eqdesign.lua is bounded (MAX_PASSES, MAX_CORRECTION_DB). When it
exhausts without measuring a candidate at or below unity it returns the
lowest-peak candidate it found -- which may still be above 0 dB. Before the
final clip gate existed, designPair then returned those coefficients with
ok = true; nothing on the apply path consulted the design's verdict (_check is
an alarm, not a gate), so the coefficients could reach the codec. And the
control-space sweep in test_clipinvariant.lua could not be the guarantee that
this never happens: it SAMPLES gain at 1.0 dB and Q at 0.2 where the real UI
steps are 0.5 and 0.05, and the v0.2.10 incident lived at exactly the kind of
quantisation-dependent interior point a sample misses.

No reachable setting is known to exhaust the correction, so this file FORCES
the paths instead of waiting for a sweep to find them: the measurement
functions are temporarily replaced with versions that report far above their
real value, which drives correct() into exhaustion by construction. The stubs
are restored before anything is asserted about real behaviour. This is a test
of the WIRING -- that a failed measurement cannot travel from correct()
through designPair to a caller as a success -- and the wiring is exactly what
was broken.
]]

local D  = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-56s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-56s %s", name, detail or "")) end
end

local function isFlat(c)
	return c ~= nil and c.N0 == D.FLAT.N0 and c.N1 == D.FLAT.N1
	   and c.N2 == D.FLAT.N2 and c.D1 == D.FLAT.D1 and c.D2 == D.FLAT.D2
end
local function coefStr(c)
	if not c then return "nil" end
	return string.format("%d/%d/%d/%d/%d", c.N0, c.N1, c.N2, c.D1, c.D2)
end

local BASS  = { kind = "lowshelf",  f0 = 100,  gainDb = 6, shape = 2.0 }
local FLATB = { kind = "lowshelf",  f0 = 150,  gainDb = 0, shape = 1.0 }
local TREB  = { kind = "highshelf", f0 = 4000, gainDb = 6, shape = 1.0 }

print("=== 1. forced correction exhaustion cannot come back as a success ===")
do
	-- +40 dB on every measurement: MAX_CORRECTION_DB is 12, so no amount of
	-- level the correction is allowed to spend can bring a reading under the
	-- cap -- exhaustion is guaranteed, not hoped for.
	local real = D.realisedPeakDb
	D.realisedPeakDb = function(c, fs)
		local p, f = real(c, fs)
		return p + 40, f
	end
	local okCall, c1, c2, i = pcall(D.designPair, FS, BASS, FLATB)
	D.realisedPeakDb = real

	ok("designPair survives the forced exhaustion", okCall,
	   okCall and "" or tostring(c1))
	if okCall then
		ok("the design is refused: ok = false", i.ok == false, "ok=" .. tostring(i.ok))
		ok("a reason is given", i.reason ~= nil, tostring(i.reason))
		ok("diag.clipGuard is set for the flight recorder",
		   i.diag and i.diag.clipGuard == true, tostring(i.diag and i.diag.clipGuard))
		ok("section 1 comes back FLAT, not the over-unity candidate",
		   isFlat(c1), coefStr(c1))
		ok("section 2 comes back FLAT", isFlat(c2), coefStr(c2))
		local p1 = real(c1, FS)
		ok("what is returned REALLY measures under unity (real reader)",
		   p1 == p1 and p1 <= 0, string.format("%+.4f dB", p1))
		ok("no make-up is charged for a filter that is not running",
		   (i.attenDb or -1) == 0, string.format("attenDb=%s", tostring(i.attenDb)))
		ok("the realised view drawn on screen is the FLAT truth",
		   i.realised1 and math.abs(i.realised1.b0 - 32767 / 32768) < 1e-9
		   and i.realised1.a1 == 0 and i.realised1.a2 == 0, nil)
	end
end

print("")
print("=== 2. the cascade invariant refuses on its own ===")
do
	-- Both bands live and individually fine; only the CASCADE measurement is
	-- forced over the line. The gate must refuse on invariant 2 alone -- this
	-- is the wiring for the case where each section passes solo but their
	-- fixed-point product does not.
	local real = D.cascadePeakDb
	D.cascadePeakDb = function(a, b, fs)
		local p, f = real(a, b, fs)
		return p + 40, f
	end
	local c1, c2, i = D.designPair(FS, BASS, TREB)
	D.cascadePeakDb = real

	ok("over-unity cascade is refused: ok = false", i.ok == false, "ok=" .. tostring(i.ok))
	ok("both sections substituted FLAT", isFlat(c1) and isFlat(c2),
	   coefStr(c1) .. " | " .. coefStr(c2))
	ok("the cascade figure is recorded in diag",
	   i.diag and i.diag.cascadeDb ~= nil, tostring(i.diag and i.diag.cascadeDb))
	ok("no make-up is charged", (i.attenDb or -1) == 0, tostring(i.attenDb))
end

print("")
print("=== 3. the gate measures the FINAL integers, after all correction ===")
do
	local c1, c2, i = D.designPair(FS, BASS, TREB)
	local p1 = D.realisedPeakDb(c1, FS)
	ok("diag.peak1 is the realised peak of the RETURNED section 1",
	   i.diag.peak1 == i.diag.peak1 and math.abs(i.diag.peak1 - p1) < 1e-9,
	   string.format("diag %+.5f vs recomputed %+.5f dB", i.diag.peak1, p1))
	local casc = D.cascadePeakDb(c1, c2, FS)
	ok("diag.cascadeDb is the cascade peak of the RETURNED pair",
	   i.diag.cascadeDb == i.diag.cascadeDb and math.abs(i.diag.cascadeDb - casc) < 1e-9,
	   string.format("diag %+.5f vs recomputed %+.5f dB", i.diag.cascadeDb, casc))

	-- Independent check that cascadePeakDb is a real measurement of these
	-- integers: a dense responseDb sweep of the returned pair must not sit
	-- above the reported peak by more than a refinement hair.
	local b10, b11, b12, a11, a12 = D.dequantize(c1)
	local b20, b21, b22, a21, a22 = D.dequantize(c2)
	local worst = -1 / 0
	local lo, hi = math.log(20), math.log(FS / 2 - 1)
	for k = 0, 400 do
		local f = math.exp(lo + (hi - lo) * k / 400)
		local v = D.responseDb(b10, b11, b12, a11, a12, f, FS)
		        + D.responseDb(b20, b21, b22, a21, a22, f, FS)
		if v > worst then worst = v end
	end
	ok("no dense-sweep point sits above the reported cascade peak",
	   worst <= casc + 0.05,
	   string.format("dense %+.4f vs reported %+.4f dB", worst, casc))
	ok("and the ordinary design is, of course, accepted", i.ok == true, nil)
end

print("")
print("=== 4. the original incident stays fixed and is NOT over-rejected ===")
do
	-- bass 100 Hz / +6 dB / Q 2.0 realised +0.508 dB in v0.2.10 (the logged
	-- SBEQ-ANOMALY the owner heard). It must design clean AND pass the gate.
	local c1, c2, i = D.designPair(FS, BASS, FLATB)
	ok("bass 100/+6/Q2.0 is an ordinary success", i.ok == true, tostring(i.reason))
	ok("its realised peak is at or under unity", i.diag.peak1 <= 0,
	   string.format("%+.4f dB (was +0.508 in v0.2.10)", i.diag.peak1))
	ok("its cascade is at or under unity", i.diag.cascadeDb <= 0,
	   string.format("%+.4f dB", i.diag.cascadeDb))
	ok("the section is a real filter, not FLAT", not isFlat(c1), coefStr(c1))
	ok("make-up is still charged normally", (i.attenDb or 0) > 3,
	   string.format("attenDb=%.2f", i.attenDb or 0))
end

print("")
print("=== 5. legitimate designs are not rejected by the gate ===")
do
	-- A spread of ordinary settings: the worst detent (both +15 Q 2.0), full
	-- cuts, mixed cut/boost where section 2 may legitimately sit above SOLO
	-- unity under a cutting section 1, and the worst clipping setting of
	-- v0.2.10. The gate checks the two REAL invariants only, so every one of
	-- these must pass it.
	local cases = {
		{ 100, 15, 2.0, 16000, 15, 2.0 },
		{ 100, -15, 2.0, 1000, 15, 2.0 },
		{ 800, 15, 0.2, 1000, -15, 0.2 },
		{ 150, 6, 0.9, 4000, 6, 0.9 },
		{ 300, -3, 1.0, 7000, 3, 1.5 },
		{ 100, 14, 1.6, 3000, 0, 1.0 },     -- worst clipper of v0.2.10
	}
	local rejected, checked, detail = 0, 0, ""
	for _, t in ipairs(cases) do
		local c1, c2, i = D.designPair(FS,
			{ kind = "lowshelf",  f0 = t[1], gainDb = t[2], shape = t[3] },
			{ kind = "highshelf", f0 = t[4], gainDb = t[5], shape = t[6] })
		checked = checked + 1
		if not i.ok then
			rejected = rejected + 1
			detail = detail .. string.format(" b%d/%+d/%.1f t%d/%+d/%.1f",
			                                 t[1], t[2], t[3], t[4], t[5], t[6])
		end
	end
	ok("no ordinary setting is refused", rejected == 0,
	   string.format("%d settings checked%s", checked, detail))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
