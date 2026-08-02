--[[
SBRadioEQ -- test_anomaly.lua          cd /tmp && jive test_anomaly

THE BLACK BOX. designPair must report the quantities that make a filter
dangerous, and the report must distinguish dangerous from ordinary.

A full-scale high-pitched burst happened at volume 100 and could not be
explained: by the time the chip was read, the coefficients had been adjusted
past. A defect capable of causing it was found afterwards by sweeping the design
space -- a treble shelf realising 9.7 dB above full scale, invisible to the
normalisation -- but nothing ever connected that measurement to the event. It
stays an assumption. This exists so a recurrence is evidence instead.

Two ways this instrumentation could be worthless, and both are tested:

  * it never fires, so a recurrence looks like a quiet log;
  * it fires constantly, so a recurrence looks like more of the same noise.

The second is the likelier failure here. A near-unity pole is NORMAL for a low
shelf -- 100 Hz measures r = 0.998 -- so radius alone would flag ordinary bass.
]]

local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-50s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-50s %s", name, detail or "")) end
end

-- the applet's thresholds, mirrored
local PEAK_WARN_DB, R_WARN, RING_F_MIN = 0.5, 0.995, 2000
local function ringing(r, f) return r and f and r > R_WARN and f > RING_F_MIN end
local function anomalous(d)
	if not d then return false end
	return (d.flat1 or d.flat2
	        or (d.peak1 and d.peak1 > PEAK_WARN_DB)
	        or (d.peak2 and d.peak2 > PEAK_WARN_DB)
	        or ringing(d.r1, d.pf1) or ringing(d.r2, d.pf2)) and true or false
end

local function design(bf, bg, bq, tf, tg, tq)
	local _, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	return i.diag, i
end

print("=== designPair reports the quantities at all ===")
do
	local d = design(150, 9, 0.9, 4000, 6, 0.9)
	ok("diag is present", d ~= nil, "")
	if d then
		local have = d.peak1 and d.peak2 and d.r1 and d.r2
		             and d.flat1 ~= nil and d.flat2 ~= nil
		ok("peaks, radii and the flat flags are all set", have and true or false,
		   string.format("peak1=%.2f peak2=%.2f r1=%.4f r2=%.4f", d.peak1, d.peak2, d.r1, d.r2))
	end
end

--[[
Only settings the CONTROL can actually produce. _nudge clamps bass frequency to
100..800 and treble to 1000..16000, so sweeping 80 Hz tested a filter no user can
reach -- and it reported a real +3.71 dB overshoot there, which looked like a
false alarm and was neither. Below about 100 Hz the shelf's pole sits so close to
the unit circle that 16-bit rounding destroys the pole/zero cancellation, and no
amount of scaling repairs it; that is why the evaluation band stops at 40 Hz.

Testing outside the reachable range would either force the gate to be loosened
for a setting nobody can select, or leave it permanently red.
]]
print("=== it stays QUIET across ordinary settings ===")
do
	local noisy, checked = {}, 0
	for _, bf in ipairs({ 100, 150, 266, 500, 800 }) do
	for _, bg in ipairs({ -12, -6, 0, 6, 12 }) do
	for _, tg in ipairs({ -12, 0, 12 }) do
		local d = design(bf, bg, 0.9, 4000, tg, 0.9)
		checked = checked + 1
		if anomalous(d) and #noisy < 4 then
			noisy[#noisy + 1] = string.format("bass %d/%+d treb %+d: peak1=%.2f peak2=%.2f r1=%.4f pf1=%s",
				bf, bg, tg, d.peak1, d.peak2, d.r1, tostring(d.pf1))
		end
	end end end
	ok("no false alarms on everyday curves", #noisy == 0,
	   #noisy > 0 and table.concat(noisy, " | ") or (checked .. " settings, silent"))
end

print("=== a 100 Hz bass shelf does NOT trip the ring test ===")
do
	--[[
	The specific false positive the frequency condition exists to prevent: this
	setting genuinely sits at r ~ 0.998, and it is a perfectly good bass shelf.
	]]
	local d = design(100, 15, 0.2, 4000, 0, 0.9)
	ok("r is indeed near unity", d.r1 > R_WARN,
	   string.format("r1=%.6f at %s Hz", d.r1, tostring(d.pf1 and math.floor(d.pf1))))
	ok("but it is NOT reported, because the pole is low", not ringing(d.r1, d.pf1),
	   string.format("pole at %s Hz is below the %d Hz threshold",
	                 tostring(d.pf1 and math.floor(d.pf1)), RING_F_MIN))
end

--[[
NEGATIVE CONTROLS. The detector must fire on the two shapes that actually
matter, or its silence means nothing.
]]
print("=== it FIRES on a filter that clips ===")
do
	local d = { peak1 = -0.1, peak2 = 9.69, r1 = 0.5, r2 = 0.8, pf1 = 100, pf2 = 18762,
	            flat1 = false, flat2 = false }
	ok("the +9.69 dB overshoot that was found is reported", anomalous(d),
	   "peak2 = +9.69 dB, the measured defect")

	local e = { peak1 = 0.6, peak2 = -1, r1 = 0.5, r2 = 0.5, pf1 = 60, pf2 = 4000,
	            flat1 = false, flat2 = false }
	ok("even a small overshoot is reported", anomalous(e), "peak1 = +0.6 dB")
end

print("=== it FIRES on a high-frequency ringing pole ===")
do
	local d = { peak1 = -1, peak2 = -1, r1 = 0.5, r2 = 0.9995, pf1 = 60, pf2 = 15000,
	            flat1 = false, flat2 = false }
	ok("r=0.9995 at 15 kHz is reported", anomalous(d), "227 ms of ring at 15 kHz")
end

print("=== it FIRES when the non-finite net catches something ===")
do
	local d = { peak1 = -1, peak2 = -1, r1 = 0.5, r2 = 0.5, pf1 = 60, pf2 = 4000,
	            flat1 = false, flat2 = true }
	ok("a NaN coefficient replaced by FLAT is reported", anomalous(d),
	   "this is how the silent 4 kHz band would have announced itself")
end

print("=== a benign report is NOT anomalous (the detector can be silent) ===")
do
	local d = { peak1 = -0.2, peak2 = -0.3, r1 = 0.98, r2 = 0.8, pf1 = 60, pf2 = 4000,
	            flat1 = false, flat2 = false }
	ok("ordinary values produce no alarm", not anomalous(d), "")

	-- if this were always-true or always-false the tests above would be vacuous
	assert(anomalous({ peak1 = 9, peak2 = -1, r1 = 0, r2 = 0, flat1 = false, flat2 = false })
	       and not anomalous(d),
	       "negative control did not fire: the detector does not discriminate")
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
