--[[
cd /tmp && jive diag_shrink

Each setMixer costs ~3.25 ms, so the mute window is dominated by CALL COUNT:
  mute + bypass + 5 coefficients + enable + restore = 9 calls = ~29 ms

Two candidate savings, both measured here rather than assumed:
  1. Drop the enable bracket (-2 calls). Safe only because we are muted AND the
     ordered intermediates were already measured stable.
  2. Skip coefficient updates too small to matter (-0..2 calls). Only worth it if
     the response error stays negligible -- measured across the control range,
     against the coefficients ACTUALLY LEFT IN THE CHIP, so error cannot
     accumulate silently.
]]

local D = require("eqdesign")
local FS = 44100

local function resp(c, f)
	local b0,b1,b2,a1,a2 = D.dequantize(c)
	return D.responseDb(b0,b1,b2,a1,a2,f,FS)
end
local FREQS = {}
do local l0,l1 = math.log(40), math.log(16000)
   for i=0,24 do FREQS[#FREQS+1] = math.exp(l0+(l1-l0)*i/24) end end

local function maxErr(a, b)
	local m = 0
	for _, f in ipairs(FREQS) do
		local d = math.abs(resp(a,f) - resp(b,f))
		if d > m then m = d end
	end
	return m
end

local function bassAt(g, f0, q)
	local c1 = D.designPair(FS,
		{ kind="lowshelf",  f0=f0, gainDb=g, shape=q },
		{ kind="highshelf", f0=4000, gainDb=6, shape=0.9 })
	return c1
end

print("threshold = skip a coefficient whose change is <= N LSB")
print("")
print(" N   avg writes/click   worst response error")
for _, thresh in ipairs({ 0, 2, 5, 10, 20, 50, 100 }) do
	local totalWrites, steps, worst = 0, 0, 0
	for _, f0 in ipairs({ 120, 266, 500 }) do
	for _, q in ipairs({ 0.5, 0.9, 1.5 }) do
		-- walk a gain sweep one UI click at a time, tracking what is really in the chip
		local inChip = bassAt(0.5, f0, q)
		for g = 1.0, 15.0, 0.5 do
			local want = bassAt(g, f0, q)
			local n = 0
			local applied = { N0=inChip.N0, N1=inChip.N1, N2=inChip.N2, D1=inChip.D1, D2=inChip.D2 }
			for _, k in ipairs({ "N0","N1","N2","D1","D2" }) do
				if math.abs(want[k] - inChip[k]) > thresh then
					applied[k] = want[k]; n = n + 1
				end
			end
			local e = maxErr(applied, want)
			if e > worst then worst = e end
			totalWrites = totalWrites + n
			steps = steps + 1
			inChip = applied
		end
	end end
	print(string.format("%3d   %8.2f          %8.3f dB", thresh, totalWrites/steps, worst))
end

print("")
print("Window cost at 3.25 ms per setMixer call:")
for _, n in ipairs({ 9, 7, 5, 4, 3 }) do
	print(string.format("  %d calls -> %5.1f ms", n, n * 3.25))
end
