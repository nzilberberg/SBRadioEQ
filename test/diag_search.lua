--[[
cd /tmp && jive diag_search

PROPOSED FIX 2: SEARCH the numerator integers instead of rounding them.

Fix 1 (refit the numerator against the quantised denominator) changed almost
nothing: 2 rows out of 31, worst adjacent step still 7.88 dB. That was worth
knowing, because it says the pairing is not the dominant error.

What is: at 60 Hz the numerator EVALUATES to about one LSB of its own
coefficients -- b0 + b1*cos(w) + b2*cos(2w) is a near-total cancellation down
there. Rounding any one coefficient by half a step therefore changes the result
by tens of percent, i.e. several dB.

And this is precisely the situation where rounding is the wrong move. The
least-squares problem is ill-conditioned, so the rounded continuous optimum is
nowhere near the best INTEGER point. But we have three integers and only need
their weighted sum to come out right, so they can trade against each other:
b0 up one, b1 down one, and the low-frequency sum is restored while the rest of
the band barely moves.

So: enumerate the neighbourhood and pick the best integer triple by realised
error. 5x5x5 = 125 candidates, no cleverness required.

If this works the remaining question is CPU, which is a solvable problem.
If it does not work, the hardware genuinely cannot sweep bass smoothly and the
control should say so.
]]

local D = require("eqdesign")
local FS = 44100
local GRID = D.GRID

local function respOfInts(c, f)
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	return D.responseDb(b0, b1, b2, a1, a2, f, FS)
end

local function idealNorm(f0, g, q)
	local b0, b1, b2, a1, a2 = D.designIdeal("lowshelf", FS, f0, g, q)
	local peak = -1 / 0
	for _, f in ipairs(GRID) do
		local v = D.responseDb(b0, b1, b2, a1, a2, f, FS); if v > peak then peak = v end
	end
	local k = 10 ^ (-math.max(peak, 0) / 20)
	return b0 * k, b1 * k, b2 * k, a1, a2
end

--[[
Error of a candidate integer set against the ideal response, as the worst
deviation over the grid. Worst-case rather than mean: one bad frequency is what
the ear notices, and averaging hides it.
]]
local function errOf(c, ib0, ib1, ib2, ia1, ia2)
	local worst = 0
	for _, f in ipairs(GRID) do
		local want = D.responseDb(ib0, ib1, ib2, ia1, ia2, f, FS)
		local got  = respOfInts(c, f)
		local d = math.abs(got - want)
		if d ~= d then return 1 / 0 end
		if d > worst then worst = d end
	end
	return worst
end

local SPAN = 2       -- +/- this many LSB on each numerator integer

local function searched(f0, g, q)
	local ib0, ib1, ib2, ia1, ia2 = idealNorm(f0, g, q)
	local base = D.quantize(ib0, ib1, ib2, ia1, ia2)
	local best, bestErr = base, errOf(base, ib0, ib1, ib2, ia1, ia2)
	for d0 = -SPAN, SPAN do
	for d1 = -SPAN, SPAN do
	for d2 = -SPAN, SPAN do
		local c = { N0 = base.N0 + d0, N1 = base.N1 + d1, N2 = base.N2 + d2,
		            D1 = base.D1, D2 = base.D2 }
		if c.N0 <= 32767 and c.N0 >= -32768
		   and c.N1 <= 32767 and c.N1 >= -32768
		   and c.N2 <= 32767 and c.N2 >= -32768 then
			local e = errOf(c, ib0, ib1, ib2, ia1, ia2)
			if e < bestErr then best, bestErr = c, e end
		end
	end end end
	return best, bestErr, base
end

local BG, BQ = 15, 2.0

print(string.format("Lowshelf %+d dB, Q %.1f -- response at 60 Hz, and worst-case", BG, BQ))
print("error against the ideal across the whole band.")
print("")
print("   f0  | naive 60Hz  err  | searched 60Hz  err | ideal 60Hz")

local pn, ps = nil, nil
local worstN, worstS = 0, 0
local errN, errS = 0, 0
for f0 = 100, 130 do
	local ib0, ib1, ib2, ia1, ia2 = idealNorm(f0, BG, BQ)
	local best, bErr, base = searched(f0, BG, BQ)
	local nErr = errOf(base, ib0, ib1, ib2, ia1, ia2)
	local rn, rs = respOfInts(base, 60), respOfInts(best, 60)
	local ri = D.responseDb(ib0, ib1, ib2, ia1, ia2, 60, FS)
	if pn then
		local dn, ds = math.abs(rn - pn), math.abs(rs - ps)
		if dn > worstN then worstN = dn end
		if ds > worstS then worstS = ds end
	end
	if nErr > errN then errN = nErr end
	if bErr > errS then errS = bErr end
	pn, ps = rn, rs
	print(string.format("  %4d | %+8.2f %6.2f | %+10.2f %6.2f | %+6.2f",
		f0, rn, nErr, rs, bErr, ri))
end

print("")
print("worst step between adjacent 1 Hz targets, at 60 Hz:")
print(string.format("   naive rounding : %6.2f dB", worstN))
print(string.format("   integer search : %6.2f dB", worstS))
print("")
print("worst-case error against the ideal, anywhere in the band:")
print(string.format("   naive rounding : %6.2f dB", errN))
print(string.format("   integer search : %6.2f dB", errS))
print("")
print(string.format("candidates tried per design: %d", (2 * SPAN + 1) ^ 3))
