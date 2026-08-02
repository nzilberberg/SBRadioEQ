--[[
cd /tmp && jive diag_lurch

Does moving the evaluation floor to 20 Hz make the MAKE-UP VOLUME lurch?

eqdesign documents why the floor is 40 Hz: below it the response is dominated by
cancellation. At 20 Hz the numerator evaluates to 0.00006 and one LSB is 0.00003,
and the measured response swung +5.01, -12.66, +4.85, -12.50 dB on consecutive
1 Hz steps of the corner frequency.

attenDb is derived from the peak. If the peak is taken over a region where the
response swings like that, attenDb swings too -- and attenDb drives the player
volume through _levelMatch. A lurching make-up is a volume control that jumps
while you turn the knob, which is worse than the 20 Hz clipping it prevents.

So: walk the bass frequency control one UI step at a time and measure the
BIGGEST JUMP in make-up between adjacent settings, under both floors. The UI step
is v * 1.04^d, so adjacent settings are 4% apart.
]]

local D = require("eqdesign")
local FS = 44100

local function buildGrid(n, lo, hi)
	local g, l0, l1 = {}, math.log(lo), math.log(hi)
	for i = 0, n - 1 do g[#g + 1] = math.exp(l0 + (l1 - l0) * i / (n - 1)) end
	return g
end

local GRID40 = D.GRID
local GRID20 = buildGrid(#D.GRID, 20, D.F_EVAL_HI)

local function atten(bf, bg, bq)
	local _, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
	return i.attenDb or 0
end

--[[
One UI click is 4% in frequency. Volume steps are ~0.49 dB apart above setting
25, so a make-up jump beyond about 1 dB is a visible lurch of two or more volume
steps from a single click.
]]
local function sweep(grid, bg, bq)
	D.GRID = grid
	local prev, worst, at = nil, 0, 0
	local f = 100
	while f <= 800 do
		local a = atten(math.floor(f + 0.5), bg, bq)
		if prev then
			local jump = math.abs(a - prev)
			if jump > worst then worst, at = jump, math.floor(f + 0.5) end
		end
		prev = a
		f = f * 1.04
	end
	D.GRID = GRID40
	return worst, at
end

print("Biggest make-up jump between ADJACENT settings (one knob click, 4% in f0).")
print("A volume step is ~0.49 dB, so >1 dB is a visible lurch.")
print("")
print("  gain   Q   |  40 Hz floor          |  20 Hz floor")
print("             |  worst jump  at Hz    |  worst jump  at Hz")

local worst40, worst20 = 0, 0
for _, bg in ipairs({ 6, 12, 15 }) do
	for _, bq in ipairs({ 0.2, 0.5, 0.9, 1.5, 2.0 }) do
		local w40, a40 = sweep(GRID40, bg, bq)
		local w20, a20 = sweep(GRID20, bg, bq)
		if w40 > worst40 then worst40 = w40 end
		if w20 > worst20 then worst20 = w20 end
		print(string.format("  %+4d  %.1f  | %8.2f dB %6d    | %8.2f dB %6d %s",
			bg, bq, w40, a40, w20, a20,
			(w20 > w40 + 0.5) and "  <== WORSE" or ""))
	end
end

print("")
print(string.format("worst jump, 40 Hz floor: %.2f dB  (%.1f volume steps)", worst40, worst40 / 0.4933))
print(string.format("worst jump, 20 Hz floor: %.2f dB  (%.1f volume steps)", worst20, worst20 / 0.4933))
print("")
if worst20 > worst40 + 0.5 then
	print("The 20 Hz floor makes the make-up LURCH. Normalising against a region")
	print("whose response is cancellation-noise puts that noise into the volume.")
else
	print("The 20 Hz floor does not make the make-up noticeably jumpier.")
end
