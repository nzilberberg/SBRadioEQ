--[[
SBRadioEQ -- test_clipinvariant.lua      cd /tmp && jive test_clipinvariant

THE INVARIANT: no reachable setting sends the chip a section that realises
ABOVE 0 dB. Above unity the output clips, and clipping is what the black box in
SBRadioEQApplet's _check exists to catch AFTER the fact. This is the same
property checked BEFORE the fact, across the whole control space.

WHY THIS FILE EXISTS

The device logged SBEQ-ANOMALY peak1=+0.50794 dB at bass 100 Hz / +6 dB / Q 2.0
while the owner was adjusting the EQ, and reported a loud crack followed by a
half-second high-pitched burst. The bench reproduced that number to five
decimals, so it is deterministic design arithmetic, not a race.

The cause is an ORDER OF OPERATIONS, and it is worth stating precisely because
the previous fix in this area corrected a different thing and left this alive:

  designPair normalises the UNQUANTISED design so its peak sits at 0 dB.
  The chip runs the QUANTISED coefficients.
  Normalising before quantising cannot enforce a property of the result of
  quantising.

The earlier fix (see designPair's peakOf) corrected the PEAK SEARCH -- a 16 kHz
shelf that measured 0.00 dB while really peaking +9.69 dB between grid points.
That was a real defect and the fix was right, but it made the UNQUANTISED peak
trustworthy. It did not move the normalisation to the other side of the
quantiser, so quantisation error still lands on top of a 0 dB target and goes
over.

WHY A SWEEP, AND NOT A FEW CASES

Every case anyone would think to write by hand -- the extremes, the defaults --
passes. The 269 bass settings that fail are interior points, scattered by
quantisation, and the worst of them (+0.626 dB) is not at any boundary: it is
100 Hz / +14 dB / Q 1.6. A hand-picked test cannot find those, and a test
written by reading the code would have been written from the same belief that
produced the bug. So sweep the control space -- a sweep can fail for a reason
the author did not already have in mind. (It is a coarse SAMPLE of the
reachable settings, not an enumeration -- see the note at the grids below --
which is why the sweep is regression evidence and the production boundary
itself fails closed in designPair.)

⛔ THE THRESHOLD IS 0 dB, NOT PEAK_WARN_DB. The applet's black box warns above
0.5 dB to keep syslog off the knob path, which is the right call for a runtime
detector. It is the WRONG number for this gate: of the 269 bass settings that
clip, only 3 exceed 0.5 dB. A gate calibrated to the detector would have passed
this bug with 266 clipping settings left in place. Guard the property, not the
alarm.

COST: about 4700 designPair calls. Roughly a minute on an idle Radio, which is
why the grids below are coarse in frequency and fine in gain and Q -- gain and Q
are where the quantiser moves the peak.
]]

local D = require("eqdesign")

local FS      = 44100
local CEILING = 0          -- dB. Above this the chip clips. Not negotiable.

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-46s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-46s %s", name, detail or "")) end
end

local function diagOf(bf, bg, bq, tf, tg, tq)
	local _, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	return i.diag
end

--[[
Ranges mirror uistate.M.RANGE. ⚠️ EVERY axis is SAMPLED, not enumerated. The
real control steps (uistate.stepValue) are 0.5 dB per gain click, 0.05 per Q
click, and 4% rounded to integer Hz per frequency click; this sweep walks gain
at 1.0 dB (2x coarse), Q at 0.2 (4x coarse) and a handful of frequencies. So it
visits a SAMPLE of the reachable settings -- REGRESSION EVIDENCE, not the
safety mechanism. An earlier version of this comment claimed gain and Q were
walked "at the real control step"; that was false, and it let this sampled
sweep be trusted as the guarantee that correction exhaustion is unreachable.
The invariant itself is enforced where it must be: designPair's FINAL CLIP GATE
measures section 1 and the full cascade on the final quantised coefficients and
refuses anything above unity (see eqdesign.lua and test_clipgate.lua). This
sweep stays sampled for runtime reasons -- that is affordable precisely because
the boundary fails closed.
]]
local BASS_F = { 100, 150, 200, 300, 400, 600, 800 }
local TREB_F = { 1000, 1500, 2000, 3000, 4500, 7000, 11000, 16000 }

local function sweep(label, freqs, isBass)
	local over, total, worst, worstAt = 0, 0, -1 / 0, ""
	for _, f in ipairs(freqs) do
		for g = -15, 15 do
			local q = 0.2
			while q <= 2.0001 do
				local d = isBass and diagOf(f, g, q, 3000, 0, 1.0)
				                 or  diagOf(150, 0, 1.0, f, g, q)
				local pk = isBass and d.peak1 or d.peak2
				total = total + 1
				-- pk ~= pk rejects NaN, which must not read as "not over".
				if pk == nil or pk ~= pk then
					over = over + 1
					if worst < 1 / 0 then worst, worstAt = 1 / 0,
						string.format("f=%d g=%+d Q=%.1f (non-finite peak)", f, g, q) end
				elseif pk > CEILING then
					over = over + 1
					if pk > worst then
						worst   = pk
						worstAt = string.format("f=%d g=%+d Q=%.1f", f, g, q)
					end
				end
				q = q + 0.2
			end
		end
	end
	ok(label .. ": every setting realises at or below 0 dB",
	   over == 0,
	   over == 0 and string.format("%d settings, worst %+.3f dB", total, worst)
	             or  string.format("%d of %d CLIP; worst %+.3f dB at %s",
	                               over, total, worst, worstAt))
	return over
end

print("=== the realised peak never exceeds 0 dB ===")
sweep("bass  (lowshelf) ", BASS_F, true)
sweep("treble(highshelf)", TREB_F, false)

--[[
NEGATIVE CONTROL. If this file ever stops being able to SEE a clipping section,
every assertion above becomes vacuous and the suite still reads green. The
applet's own peak is what the gate reads, so feed the reader a design that is
known to sit above unity and require it to say so.

A raw shelf with no normalisation at all peaks at its full gain -- the +6 dB
case the device logged measures +6.51 dB unnormalised. Quantise that directly,
bypassing designPair, and realisedPeakDb must report it above the ceiling.
]]
print("")
print("=== negative control: the reader can still see a clipping section ===")
local b0, b1, b2, a1, a2 = D.designIdeal("lowshelf", FS, 100, 6, 2.0)
local raw  = D.quantize(b0, b1, b2, a1, a2)
local rawPk = D.realisedPeakDb(raw, FS)
ok("an unnormalised +6 dB shelf reads above the ceiling",
   rawPk ~= nil and rawPk == rawPk and rawPk > CEILING,
   string.format("%+.3f dB", rawPk or 0 / 0))

print("")
print(string.format("passed=%d failed=%d", pass, fail))
