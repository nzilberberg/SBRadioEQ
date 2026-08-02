--[[
cd /tmp && jive diag_floorcheck

INDEPENDENT CHECK of a claim I relayed without verifying: that ~1.13 dB is the
HARDWARE FLOOR at bass 100 Hz / +15 dB / Q 2.0 -- i.e. no choice of the five
integers does better, so the 1.0 dB spec is unreachable there.

That number came from the agent's brute-force search. I repeated it to the user
as fact. If it is optimistic, the shipped filter is worse than it needed to be;
if pessimistic, the spec is reachable and we stopped early. Either way it should
not be quoted unchecked.

Deliberately NOT the agent's method: search the integer lattice over the
DENOMINATOR (which places the poles) and, for each candidate, fit the numerator
to the requested DC gain. Score = worst error against the REQUESTED RBJ design
after the best uniform level shift, since level is paid by the volume make-up and
only SHAPE is constrained.
]]

local D = require("eqdesign")
local FS = 44100

local BF, BG, BQ = 100, 15, 2.0

local rb0, rb1, rb2, ra1, ra2 = D.designIdeal("lowshelf", FS, BF, BG, BQ)

local FR, WANT = {}, {}
do
	local l0, l1 = math.log(40), math.log(16000)
	for i = 0, 23 do FR[#FR + 1] = math.exp(l0 + (l1 - l0) * i / 23) end
end
for i, f in ipairs(FR) do
	WANT[i] = D.responseDb(rb0, rb1, rb2, ra1, ra2, f, FS)
end

-- worst |error| after the best uniform level shift; level is free, shape is not
local function score(c)
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	if D.poleRadius(a1, a2) >= 0.99999 then return 1 / 0 end
	local lo, hi = 1 / 0, -1 / 0
	for i, f in ipairs(FR) do
		local v = D.responseDb(b0, b1, b2, a1, a2, f, FS)
		if v ~= v then return 1 / 0 end
		local e = v - WANT[i]
		if e < lo then lo = e end
		if e > hi then hi = e end
	end
	return (hi - lo) / 2
end

local nom = D.quantize(rb0, rb1, rb2, ra1, ra2)

print(string.format("target: bass %d Hz / %+d dB / Q %.1f", BF, BG, BQ))
print(string.format("nominal: N0=%d N1=%d N2=%d D1=%d D2=%d",
	nom.N0, nom.N1, nom.N2, nom.D1, nom.D2))
print(string.format("plain rounding scores: %.3f dB", score(nom)))

-- what designPair actually ships now
local shipped = D.designPair(FS,
	{ kind = "lowshelf",  f0 = BF, gainDb = BG, shape = BQ },
	{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
print(string.format("what SHIPS today scores : %.3f dB", score(shipped)))
print("")

local dsumNom = 32768 - 2 * nom.D1 - nom.D2
local dcWant  = 10 ^ ((BG) / 20)

local best, bestC, tried = 1 / 0, nil, 0

for dD1 = -12, 12 do
	for dsum = math.max(1, dsumNom - 4), dsumNom + 4 do
		local D1 = nom.D1 + dD1
		local D2 = 32768 - 2 * D1 - dsum
		if D1 >= -32768 and D1 <= 32767 and D2 >= -32768 and D2 <= 32767 then
			--[[
			N1 must range FAR wider than instinct suggests. The nominal N0 is
			already clamped at 32767, so a narrow window around the nominal N1
			produces only overflowing candidates -- the first version of this
			search evaluated ZERO and reported a confident verdict on nothing.
			N0+N2 = nsum - 2*N1, so N1 has to move by roughly +100 before N0
			comes back inside the field at all. Sweep the whole feasible band
			and let the range checks below do the filtering.
			]]
			for dnsum = -3, 3 do
				local nsum = math.floor(dcWant * dsum + 0.5) + dnsum
				for dN1 = -60, 600, 2 do
					local N1   = nom.N1 + dN1
					local rest = nsum - 2 * N1
					for _, skew in ipairs({ nom.N0 - nom.N2, 0, 200, 400, 800 }) do
					local N0   = math.floor((rest + skew) / 2 + 0.5)
					local N2   = rest - N0
					if N0 >= -32768 and N0 <= 32767
					   and N1 >= -32768 and N1 <= 32767
					   and N2 >= -32768 and N2 <= 32767 then
						local c = { N0 = N0, N1 = N1, N2 = N2, D1 = D1, D2 = D2 }
						local s = score(c)
						tried = tried + 1
						if s < best then best, bestC = s, c end
					end
					end
				end
			end
		end
	end
end

-- A search that evaluated nothing must not be reported as a result. This is the
-- exact failure the first version made.
if tried == 0 then
	print("SEARCH EVALUATED ZERO CANDIDATES -- bounds are wrong, no conclusion possible.")
	return
end

print(string.format("candidates evaluated : %d", tried))
print(string.format("BEST found by this search: %.3f dB", best))
if bestC then
	print(string.format("  N0=%d N1=%d N2=%d D1=%d D2=%d",
		bestC.N0, bestC.N1, bestC.N2, bestC.D1, bestC.D2))
end
print("")
print("relayed claim: the floor is about 1.13 dB.")
if best < 1.00 then
	print("=> CLAIM WRONG. Something under the 1.0 dB spec exists; we stopped early.")
elseif best < 1.08 then
	print("=> claim mildly PESSIMISTIC, same order of magnitude.")
elseif best <= 1.30 then
	print("=> CORROBORATED. An independent search finds essentially the same floor.")
else
	print("=> claim OPTIMISTIC. This search could not even reach 1.13 dB.")
end
