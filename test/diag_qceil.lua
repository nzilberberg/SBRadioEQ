--[[
cd /tmp && jive diag_qceil

Which (frequency, Q) combinations can the chip actually deliver smoothly?

Established so far:
  * the bass response jumps up to 5.60 dB on one knob click, worst at LOW
    frequency and HIGH Q;
  * the cause is direct-form pole sensitivity near angle zero, and the textbook
    cure (coupled / Gold-Rader form) is a different structure fixed in silicon;
  * searching the integer neighbourhood halves the error but costs 97-3080 ms
    per design against a 22 ms click budget, so it cannot run live.

That leaves the option the project already decided on and never implemented:
"Clamp Q by verification, never by a lookup table. Make the clamp VISIBLE."

This measures the ceiling. For each frequency, the highest Q whose worst
adjacent-click jump stays under a threshold -- verified, not assumed, by
actually stepping the control and looking at what comes out.

Reported at 60 Hz (where the jumps are worst) and at the corner itself.
]]

local D = require("eqdesign")
local FS = 44100
local TOL = 1.5        -- dB; about three volume steps, the point it becomes obvious

local function design(f0, g, q)
	local c1 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = f0, gainDb = g, shape = q },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
	return c1
end

local function respAt(c, f)
	if not c then return 0 end
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	return D.responseDb(b0, b1, b2, a1, a2, f, FS)
end

--[[
Worst jump at 60 Hz between adjacent UI clicks (4% in frequency) in a window
around f0. Only the neighbourhood matters: the question is what happens when the
user nudges the control from here.
]]
local function worstJumpNear(f0, g, q)
	local worst = 0
	local prev = nil
	local f = f0 / (1.04 ^ 3)
	for _ = 1, 7 do
		local r = respAt(design(math.floor(f + 0.5), g, q), 60)
		if prev then
			local d = math.abs(r - prev)
			if d > worst then worst = d end
		end
		prev = r
		f = f * 1.04
	end
	return worst
end

local QS = { 0.2, 0.3, 0.4, 0.5, 0.7, 0.9, 1.2, 1.5, 1.8, 2.0 }

print(string.format("Highest Q whose worst adjacent-click jump at 60 Hz stays under %.1f dB.", TOL))
print("(UI currently allows Q from 0.2 to 2.0 at every frequency.)")
print("")
print("    f0     gain +6   gain +12   gain +15")

for _, f0 in ipairs({ 100, 120, 150, 180, 220, 266, 330, 400, 500, 650, 800 }) do
	local cells = {}
	for _, g in ipairs({ 6, 12, 15 }) do
		local best = nil
		for _, q in ipairs(QS) do
			if worstJumpNear(f0, g, q) <= TOL then best = q end
		end
		cells[#cells + 1] = best and string.format("%8.1f", best) or "    none"
	end
	print(string.format("  %5d   %s   %s   %s", f0, cells[1], cells[2], cells[3]))
end

print("")
print("And the cost of the clamp: how much of the control surface it removes.")
local total, allowed = 0, 0
for _, f0 in ipairs({ 100, 120, 150, 180, 220, 266, 330, 400, 500, 650, 800 }) do
	for _, g in ipairs({ 6, 12, 15 }) do
		for _, q in ipairs(QS) do
			total = total + 1
			if worstJumpNear(f0, g, q) <= TOL then allowed = allowed + 1 end
		end
	end
end
print(string.format("  %d of %d combinations pass (%.0f%%)", allowed, total, 100 * allowed / total))
