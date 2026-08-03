--[[
SBRadioEQ -- test_graphtruth.lua       cd /tmp && jive test_graphtruth

THE REQUIREMENT: the curve on screen must be what the chip actually does.

History this encodes, because it was got wrong once already:

The user reported the curve jumping around while adjusting. The intent was to fix
the FILTER so the curve would be smooth and true. What was actually done was to
switch the graph to plot the IDEAL, unquantised design instead of the realised
one. That made the picture smooth by drawing something other than reality -- the
jumping was still there, in the sound, invisible.

It was then "discovered" months later as if it were a new problem.

Measured at bass 100 Hz / +15 dB / Q 2.0, the gap between drawn and realised:
    40 Hz   drawn +16.71   real  +9.38   off by 7.3 dB
    60 Hz   drawn +16.79   real +10.20   off by 6.6 dB
   200 Hz   drawn  -2.18   real  +0.18   off by 2.4 dB

⚠️ THIS TEST IS EXPECTED TO FAIL until the underlying maths is fixed. That is the
point of it. It is the specification, written down so that "make the graph
smooth" can never again be satisfied by drawing the wrong curve. Do not make it
pass by loosening TOL, and do not make it pass by changing what is compared --
either of those is the original mistake again, in a new costume.
]]

local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-46s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-46s %s", name, detail or "")) end
end

--[[
Tolerance. 1 dB is about two volume steps -- the point at which a listener can
tell the picture from the sound. Not a knob to turn when the test is
inconvenient.
]]
local TOL = 1.0

-- The applet's own plotting band and resolution (F_LO/F_HI/NPTS in the applet).
local F_LO, F_HI, NPTS = 40, 16000, 80

--[[
⚠️ WHAT THIS COMPARES, AND WHY IT IS NOT "DRAWN vs REALISED" ANY MORE.

The first version compared the drawn curve against the realised one. That was
right while the applet drew the IDEAL design. It stopped being a test the moment
designPair started returning realised1/realised2 as float VIEWS OF THE QUANTISED
INTEGERS: drawn and realised then came from the same numbers, the comparison read
0.00 dB by construction, and it could no longer fail for any input.

Making the graph draw the truth was the right change. Leaving this test pointed
at it was not -- a test that cannot fail is not evidence, and this one existed
specifically because the defect had once been hidden rather than fixed.

So it now compares the REALISED filter against WHAT WAS REQUESTED: the RBJ design
for the user's own frequency, gain and Q, computed here from designIdeal so it
cannot be affected by anything designPair chooses to return.

The request is a shape at its natural level; the realised filter is that shape
pushed down by attenDb and bought back with volume. Adding attenDb back is what
makes the two comparable.
]]
local function realisedVsRequest(bf, bg, bq, tf, tg, tq)
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	local atten = i.attenDb or 0

	-- what was ASKED FOR, independent of designPair's internals
	local rb = { D.designIdeal("lowshelf",  FS, bf, bg, bq) }
	local rt = { D.designIdeal("highshelf", FS, tf, tg, tq) }

	local worst, worstF = 0, 0
	local l0, l1 = math.log(F_LO), math.log(F_HI)
	for k = 0, NPTS do
		local f = math.exp(l0 + (l1 - l0) * k / NPTS)

		local want = 0
		if bg ~= 0 then want = want + D.responseDb(rb[1], rb[2], rb[3], rb[4], rb[5], f, FS) end
		if tg ~= 0 then want = want + D.responseDb(rt[1], rt[2], rt[3], rt[4], rt[5], f, FS) end

		local got = atten
		for _, c in ipairs({ c1, c2 }) do
			if c then
				local b0, b1, b2, a1, a2 = D.dequantize(c)
				got = got + D.responseDb(b0, b1, b2, a1, a2, f, FS)
			end
		end

		local d = math.abs(got - want)
		if d == d and d > worst then worst, worstF = d, f end
	end
	return worst, worstF
end

--[[
The old comparison, kept ONLY as a guard that the graph still draws the realised
filter. It is expected to be ~0 and proves nothing about accuracy -- if it ever
goes large again, someone has repointed the curve back at an idealised design.
]]
local function drawnVsRealised(bf, bg, bq, tf, tg, tq)
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	local worst = 0
	local l0, l1 = math.log(F_LO), math.log(F_HI)
	for k = 0, NPTS do
		local f = math.exp(l0 + (l1 - l0) * k / NPTS)
		local drawn, real = 0, 0
		for _, id in ipairs({ i.realised1, i.realised2 }) do
			if id then drawn = drawn + D.responseDb(id.b0, id.b1, id.b2, id.a1, id.a2, f, FS) end
		end
		for _, c in ipairs({ c1, c2 }) do
			if c then
				local b0, b1, b2, a1, a2 = D.dequantize(c)
				real = real + D.responseDb(b0, b1, b2, a1, a2, f, FS)
			end
		end
		local d = math.abs(real - drawn)
		if d == d and d > worst then worst = d end
	end
	return worst
end

local drawnVsReal = realisedVsRequest

print("=== the drawn curve matches the realised one, at ordinary settings ===")
do
	local bad = {}
	local checked = 0
	for _, bf in ipairs({ 220, 330, 500, 800 }) do
	for _, bg in ipairs({ -12, -6, 6, 12, 15 }) do
	for _, bq in ipairs({ 0.2, 0.9, 2.0 }) do
		local w, wf = drawnVsReal(bf, bg, bq, 4000, 6, 0.9)
		checked = checked + 1
		if w > TOL and #bad < 4 then
			bad[#bad + 1] = string.format("bass %d/%+d/Q%.1f: %.2f dB at %.0f Hz", bf, bg, bq, w, wf)
		end
	end end end
	ok("bass corner 220 Hz and above", #bad == 0,
	   #bad > 0 and table.concat(bad, " | ") or (checked .. " settings, all within " .. TOL .. " dB"))
end

print("=== ...and at the low corners too (THIS IS THE OPEN BUG) ===")
do
	local bad = {}
	local worstAll, worstDesc = 0, ""
	for _, bf in ipairs({ 100, 120, 150, 180 }) do
	for _, bg in ipairs({ 6, 12, 15 }) do
	for _, bq in ipairs({ 0.2, 0.9, 2.0 }) do
		local w, wf = drawnVsReal(bf, bg, bq, 4000, 0, 0.9)
		if w > worstAll then
			worstAll = w
			worstDesc = string.format("bass %d/%+d/Q%.1f at %.0f Hz", bf, bg, bq, wf)
		end
		if w > TOL and #bad < 3 then
			bad[#bad + 1] = string.format("bass %d/%+d/Q%.1f: %.2f dB", bf, bg, bq, w)
		end
	end end end
	ok("bass corner below 200 Hz", #bad == 0,
	   #bad > 0 and string.format("worst %.2f dB (%s) | %s", worstAll, worstDesc,
	                              table.concat(bad, " | "))
	            or "all within tolerance")
end

print("=== the specific setting the user asked about ===")
do
	local w, wf = drawnVsReal(100, 15, 2.0, 4000, 0, 0.9)
	ok("bass 100 Hz / +15 dB / Q 2.0", w <= TOL,
	   string.format("graph differs from reality by %.2f dB at %.0f Hz", w, wf))
end

--[[
The graph must still be drawing the realised filter, not an idealised one. This
is a structural guard, not an accuracy measure -- it reads ~0 because the drawn
curve is derived from the same integers, and that is exactly the property being
protected.
]]
print("=== the drawn curve is still the realised filter, not an idealisation ===")
do
	local worst = 0
	for _, s in ipairs({ { 100, 15, 2.0 }, { 150, 12, 0.9 }, { 400, 6, 1.5 }, { 800, -12, 0.2 } }) do
		local w = drawnVsRealised(s[1], s[2], s[3], 4000, 6, 0.9)
		if w > worst then worst = w end
	end
	ok("graph is drawn from the chip's own coefficients", worst < 0.01,
	   string.format("worst drawn-vs-realised %.4f dB", worst))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
if fail > 0 then
	print("")
	print("A failure here is the SPECIFICATION being unmet, not the test being wrong.")
	print("The graph now draws the realised filter honestly; what remains is that the")
	print("realised filter cannot match the REQUEST at the lowest corners. A brute-force")
	print("search over the integer neighbourhood put the floor at about 1.13 dB there,")
	print("so 1.0 dB may not be reachable at those settings by any choice of integers.")
	print("Resolve that by restricting the control range -- NOT by raising TOL.")
end
