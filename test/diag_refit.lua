--[[
cd /tmp && jive diag_refit

PROPOSED FIX: fit the numerator to the QUANTISED denominator.

Measured problem: the realised bass response is chaotic in the target frequency.
Consecutive 1 Hz targets give -1.42, -7.46, -13.66, -3.30 dB at 60 Hz. There are
701 distinct realisable filters between 100 and 800 Hz, so the hardware is NOT
short of resolution -- we are choosing badly from it.

Why we choose badly: a shelf works by near-exact cancellation between numerator
and denominator. We compute both from the ideal design, then round each to
integers independently. The rounded denominator is a slightly DIFFERENT filter,
and the numerator it is now paired with was never meant for it, so the
cancellation that the whole shelf depends on is broken -- by an amount that
depends on which side of a rounding boundary each coefficient fell, which is why
the result looks random.

Research rules out the textbook cure: direct-form poles are most sensitive to
quantisation at angles near zero, and the fix is a coupled / Gold-Rader topology
-- a different structure, fixed in the AIC3104's silicon.

But nothing stops us choosing the numerator to suit the denominator we actually
got. Quantise the denominator first, then solve for the numerator that best
reproduces the IDEAL response given THAT denominator:

    minimise  sum_w | B(w) - Hideal(w) * Ahat(w) |^2      over b0, b1, b2

which is linear least squares in three real unknowns -- a 3x3 normal equation,
solved in closed form. No search, no iteration, O(1) per design.
]]

local D = require("eqdesign")
local FS = 44100

----------------------------------------------------------------- helpers

local function cplxResp(b0, b1, b2, a1, a2, f)
	local w = 2 * math.pi * f / FS
	local c1, s1 = math.cos(w), math.sin(w)
	local c2, s2 = math.cos(2 * w), math.sin(2 * w)
	local nr, ni = b0 + b1 * c1 + b2 * c2, -(b1 * s1 + b2 * s2)
	local dr, di = 1 + a1 * c1 + a2 * c2,  -(a1 * s1 + a2 * s2)
	local den = dr * dr + di * di
	return (nr * dr + ni * di) / den, (ni * dr - nr * di) / den
end

-- Solve a 3x3 symmetric system by Gaussian elimination with partial pivoting.
local function solve3(A, y)
	local m = { { A[1][1], A[1][2], A[1][3], y[1] },
	            { A[2][1], A[2][2], A[2][3], y[2] },
	            { A[3][1], A[3][2], A[3][3], y[3] } }
	for col = 1, 3 do
		local piv, best = col, math.abs(m[col][col])
		for r = col + 1, 3 do
			if math.abs(m[r][col]) > best then piv, best = r, math.abs(m[r][col]) end
		end
		if best < 1e-18 then return nil end
		m[col], m[piv] = m[piv], m[col]
		for r = 1, 3 do
			if r ~= col then
				local fct = m[r][col] / m[col][col]
				for k = col, 4 do m[r][k] = m[r][k] - fct * m[col][k] end
			end
		end
	end
	return { m[1][4] / m[1][1], m[2][4] / m[2][2], m[3][4] / m[3][3] }
end

--[[
Fit b0,b1,b2 so that B(w) best matches Hideal(w)*Ahat(w) over the grid.
Basis is [1, z^-1, z^-2] at each w; everything is real because b is real.
]]
local function refitNumerator(ib0, ib1, ib2, ia1, ia2, qa1, qa2, grid)
	local A = { {0,0,0}, {0,0,0}, {0,0,0} }
	local y = { 0, 0, 0 }
	for _, f in ipairs(grid) do
		local w = 2 * math.pi * f / FS
		-- basis vectors (real, imag) for b0, b1, b2
		local pr = { 1, math.cos(w), math.cos(2 * w) }
		local pi = { 0, -math.sin(w), -math.sin(2 * w) }
		-- target = Hideal * Ahat
		local hr, hi = cplxResp(ib0, ib1, ib2, ia1, ia2, f)
		local ar = 1 + qa1 * math.cos(w) + qa2 * math.cos(2 * w)
		local ai = -(qa1 * math.sin(w) + qa2 * math.sin(2 * w))
		local tr, ti = hr * ar - hi * ai, hr * ai + hi * ar
		for r = 1, 3 do
			for c = 1, 3 do
				A[r][c] = A[r][c] + pr[r] * pr[c] + pi[r] * pi[c]
			end
			y[r] = y[r] + pr[r] * tr + pi[r] * ti
		end
	end
	return solve3(A, y)
end

----------------------------------------------------------------- experiment

local BG, BQ = 15, 2.0
local GRID = D.GRID

local function naive(f0)
	local b0, b1, b2, a1, a2 = D.designIdeal("lowshelf", FS, f0, BG, BQ)
	-- peak-normalise as designPair does
	local peak = -1/0
	for _, f in ipairs(GRID) do
		local v = D.responseDb(b0,b1,b2,a1,a2,f,FS); if v > peak then peak = v end
	end
	local k = 10 ^ (-math.max(peak,0) / 20)
	return D.quantize(b0*k, b1*k, b2*k, a1, a2)
end

local function refit(f0)
	local b0, b1, b2, a1, a2 = D.designIdeal("lowshelf", FS, f0, BG, BQ)
	local peak = -1/0
	for _, f in ipairs(GRID) do
		local v = D.responseDb(b0,b1,b2,a1,a2,f,FS); if v > peak then peak = v end
	end
	local k = 10 ^ (-math.max(peak,0) / 20)
	b0, b1, b2 = b0*k, b1*k, b2*k

	-- quantise the DENOMINATOR first, then see what it really is
	local c = D.quantize(b0, b1, b2, a1, a2)
	local _, _, _, qa1, qa2 = D.dequantize(c)

	-- refit the numerator against THAT denominator
	local nb = refitNumerator(b0, b1, b2, a1, a2, qa1, qa2, GRID)
	if not nb then return c end
	return D.quantize(nb[1], nb[2], nb[3], a1, a2)
end

local function respAt(c, f)
	local b0,b1,b2,a1,a2 = D.dequantize(c)
	return D.responseDb(b0,b1,b2,a1,a2,f,FS)
end

print(string.format("Lowshelf %+d dB, Q %.1f. Response at 60 Hz for each 1 Hz target.", BG, BQ))
print("")
print("   f0    naive     refit   | ideal")
local pn, pr = nil, nil
local worstN, worstR = 0, 0
for f0 = 100, 130 do
	local cn, cr = naive(f0), refit(f0)
	local rn, rr = respAt(cn, 60), respAt(cr, 60)
	local ib0, ib1, ib2, ia1, ia2 = D.designIdeal("lowshelf", FS, f0, BG, BQ)
	local peak = -1/0
	for _, f in ipairs(GRID) do
		local v = D.responseDb(ib0,ib1,ib2,ia1,ia2,f,FS); if v > peak then peak = v end
	end
	local ri = D.responseDb(ib0,ib1,ib2,ia1,ia2,60,FS) - math.max(peak,0)
	if pn then
		local dn, dr = math.abs(rn - pn), math.abs(rr - pr)
		if dn > worstN then worstN = dn end
		if dr > worstR then worstR = dr end
	end
	pn, pr = rn, rr
	print(string.format("  %4d  %+7.2f  %+8.2f   | %+6.2f", f0, rn, rr, ri))
end

print("")
print(string.format("worst step between adjacent 1 Hz targets, at 60 Hz:"))
print(string.format("   naive rounding : %6.2f dB", worstN))
print(string.format("   refitted       : %6.2f dB", worstR))
print("")

-- and across the whole bass range
local wn2, wr2 = 0, 0
pn, pr = nil, nil
for f0 = 100, 800 do
	local rn = respAt(naive(f0), 60)
	local rr = respAt(refit(f0), 60)
	if pn then
		local dn, dr = math.abs(rn - pn), math.abs(rr - pr)
		if dn > wn2 then wn2 = dn end
		if dr > wr2 then wr2 = dr end
	end
	pn, pr = rn, rr
end
print("Across the whole 100-800 Hz range, worst adjacent step at 60 Hz:")
print(string.format("   naive rounding : %6.2f dB", wn2))
print(string.format("   refitted       : %6.2f dB", wr2))
