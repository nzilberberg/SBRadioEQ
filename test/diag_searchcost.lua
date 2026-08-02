--[[
cd /tmp && jive diag_searchcost

The integer search halves the bass jumpiness (7.88 -> 3.51 dB). Whether it can
SHIP depends on what it costs, because designPair runs on every knob click on a
360 MHz core with no FPU.

Budget: a click already costs about 22 ms of setMixer writes. Much beyond
~60-80 ms total and the control starts to feel laggy, which is a real cost --
the debounce that stole live feedback was removed for exactly that reason.

Measured here, with a wall clock that is cross-checked first (os.clock is CPU
time on this platform and reports blocking work as free):
  * one responseDb evaluation
  * one full 125-candidate search on the 64-point grid
  * the same search on reduced grids, since the search does not need the
    display's resolution -- only enough points to rank candidates
]]

local D = require("eqdesign")
local Framework = require("jive.ui.Framework")
local FS = 44100

local function ms(f, n)
	local t0 = Framework:getTicks()
	for _ = 1, n do f() end
	return (Framework:getTicks() - t0) / n
end

do
	local t0, c0 = os.time(), Framework:getTicks()
	while os.time() - t0 < 2 do end
	local wall, ticks = os.time() - t0, (Framework:getTicks() - c0) / 1000
	print(string.format("clock check: os.time %.0f s vs getTicks %.2f s -- %s",
		wall, ticks, (math.abs(ticks - wall) <= 0.5) and "sane" or "WRONG"))
end
print("")

local function subgrid(n)
	local g, src = {}, D.GRID
	local step = #src / n
	for i = 1, n do g[i] = src[math.min(#src, math.floor((i - 1) * step) + 1)] end
	return g
end

local function idealNorm(f0, g, q)
	local b0, b1, b2, a1, a2 = D.designIdeal("lowshelf", FS, f0, g, q)
	local peak = -1 / 0
	for _, f in ipairs(D.GRID) do
		local v = D.responseDb(b0, b1, b2, a1, a2, f, FS); if v > peak then peak = v end
	end
	local k = 10 ^ (-math.max(peak, 0) / 20)
	return b0 * k, b1 * k, b2 * k, a1, a2
end

local ib0, ib1, ib2, ia1, ia2 = idealNorm(114, 15, 2.0)

print(string.format("one responseDb call: %.4f ms",
	ms(function() D.responseDb(ib0, ib1, ib2, ia1, ia2, 1000, FS) end, 2000)))
print("")

local function searchOn(grid, span)
	local base = D.quantize(ib0, ib1, ib2, ia1, ia2)
	local best, bestErr = base, 1 / 0
	for d0 = -span, span do
	for d1 = -span, span do
	for d2 = -span, span do
		local c = { N0 = base.N0 + d0, N1 = base.N1 + d1, N2 = base.N2 + d2,
		            D1 = base.D1, D2 = base.D2 }
		local worst = 0
		local qb0, qb1, qb2, qa1, qa2 = D.dequantize(c)
		for i = 1, #grid do
			local f = grid[i]
			local d = D.responseDb(qb0, qb1, qb2, qa1, qa2, f, FS)
			      - D.responseDb(ib0, ib1, ib2, ia1, ia2, f, FS)
			if d < 0 then d = -d end
			if d > worst then worst = d end
		end
		if worst < bestErr then best, bestErr = c, worst end
	end end end
	return best, bestErr
end

print("  span  grid pts  candidates   time per design")
for _, span in ipairs({ 1, 2 }) do
	for _, n in ipairs({ 64, 32, 16, 8 }) do
		local g = subgrid(n)
		local t = ms(function() searchOn(g, span) end, 3)
		local _, e = searchOn(g, span)
		print(string.format("  %4d  %8d  %10d   %8.1f ms   (err %.2f dB)",
			span, n, (2 * span + 1) ^ 3, t, e))
	end
end

print("")
print("For reference: a knob click already costs ~22 ms of setMixer writes,")
print("and designPair itself runs before any of this.")
