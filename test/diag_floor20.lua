--[[
cd /tmp && jive diag_floor20

What would moving the evaluation floor from 40 Hz to 20 Hz cost in make-up volume?

The design normalises against M.GRID, which spans 40..16000 Hz. Below 40 Hz a low
shelf's realised response can rise above unity -- measured +3.49 dB at 20 Hz for
bass 100 / +15 / Q 0.2 -- because 16-bit quantisation wrecks the pole/zero
cancellation down there. That overshoot clips, and clipping at 20 Hz produces
harmonics at 40, 60, 80 Hz which ARE audible even though 20 Hz is not.

Including 20 Hz in the normalisation would prevent it, at the price of pulling
every bass-heavy curve further down and charging the difference as make-up.

designPair reads M.GRID at call time, so both floors can be measured by swapping
the grid -- same code, same settings, only the evaluation band differs.
]]

local D = require("eqdesign")
local FS = 44100

local function buildGrid(n, lo, hi)
	local g, l0, l1 = {}, math.log(lo), math.log(hi)
	for i = 0, n - 1 do g[#g + 1] = math.exp(l0 + (l1 - l0) * i / (n - 1)) end
	return g
end

local GRID40 = D.GRID                                   -- as shipped
local GRID20 = buildGrid(#D.GRID, 20, D.F_EVAL_HI)

local function attenAndPeak(bf, bg, bq, tf, tg, tq)
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = tq })
	-- realised peak measured on a DENSE grid down to 20 Hz, independent of
	-- whichever grid the design normalised against
	local function densePeak(c)
		if not c then return -1 / 0 end
		local b0, b1, b2, a1, a2 = D.dequantize(c)
		local best, l0, l1 = -1 / 0, math.log(20), math.log(20000)
		for k = 0, 800 do
			local f = math.exp(l0 + (l1 - l0) * k / 800)
			local v = D.responseDb(b0, b1, b2, a1, a2, f, FS)
			if v == v and v > best then best = v end
		end
		return best
	end
	local p = math.max(densePeak(c1) + 0, densePeak(c2) + 0)
	-- the cascade is what actually clips
	local pc = -1 / 0
	do
		local B1 = { D.dequantize(c1) }
		local B2 = { D.dequantize(c2) }
		local l0, l1 = math.log(20), math.log(20000)
		for k = 0, 800 do
			local f = math.exp(l0 + (l1 - l0) * k / 800)
			local v = D.responseDb(B1[1],B1[2],B1[3],B1[4],B1[5], f, FS)
			        + D.responseDb(B2[1],B2[2],B2[3],B2[4],B2[5], f, FS)
			if v == v and v > pc then pc = v end
		end
	end
	return i.attenDb or 0, pc
end

print("Cost of lowering the evaluation floor from 40 Hz to 20 Hz.")
print("'over' is the realised cascade peak above full scale on a dense 20 Hz-20 kHz grid.")
print("")
print("  bass f0  gain   Q  |  40 Hz floor        |  20 Hz floor        | extra")
print("                     |  make-up   over     |  make-up   over     | make-up")

local worstExtra, worstAt = 0, nil
local worstOver40 = 0

for _, bf in ipairs({ 100, 150, 266, 400, 800 }) do
	for _, bg in ipairs({ 6, 12, 15 }) do
		for _, bq in ipairs({ 0.2, 0.9, 2.0 }) do
			D.GRID = GRID40
			local a40, o40 = attenAndPeak(bf, bg, bq, 4000, 0, 0.9)
			D.GRID = GRID20
			local a20, o20 = attenAndPeak(bf, bg, bq, 4000, 0, 0.9)
			D.GRID = GRID40

			local extra = a20 - a40
			if extra > worstExtra then worstExtra, worstAt = extra, string.format("bass %d /%+d / Q%.1f", bf, bg, bq) end
			if o40 > worstOver40 then worstOver40 = o40 end

			if bq ~= 0.9 or bg ~= 12 then      -- keep the table readable
				print(string.format("  %7d  %+4d %4.1f | %8.2f %+7.2f    | %8.2f %+7.2f    | %+.2f",
					bf, bg, bq, a40, o40, a20, o20, extra))
			end
		end
	end
end

print("")
print(string.format("worst extra make-up: %+.2f dB  (%s)", worstExtra, worstAt or "-"))
print(string.format("worst overshoot left by the 40 Hz floor: %+.2f dB", worstOver40))
print("")
print("Both bands boosted, the case where make-up is already scarce:")
for _, g in ipairs({ 6, 12, 15 }) do
	D.GRID = GRID40
	local a40, o40 = attenAndPeak(150, g, 0.9, 4000, g, 0.9)
	D.GRID = GRID20
	local a20, o20 = attenAndPeak(150, g, 0.9, 4000, g, 0.9)
	D.GRID = GRID40
	print(string.format("  bass/treb %+d: make-up %.2f -> %.2f dB (%+.2f), overshoot %+.2f -> %+.2f",
		g, a40, a20, a20 - a40, o40, o20))
end
