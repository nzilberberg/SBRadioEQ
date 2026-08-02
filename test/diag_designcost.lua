--[[
cd /tmp && jive diag_designcost

A verified Q clamp cannot use a lookup table -- the failures are non-monotonic
(120 Hz is worse than 100 Hz). So it has to actually design candidate filters and
look at them, on every edit, on a 360 MHz core.

That makes its cost a function of how many designPair calls it needs:
  * checking whether the CURRENT setting is smooth means designing its
    neighbours too, since "smooth" is about the step between adjacent clicks;
  * if it fails, each Q it steps down to needs the same check again.

Measured here against the 22 ms a knob click already spends on setMixer writes.
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
	print(string.format("clock check: %.2f s measured for 2 s -- %s",
		(Framework:getTicks() - c0) / 1000,
		(math.abs((Framework:getTicks() - c0) / 1000 - 2) <= 0.6) and "sane" or "WRONG"))
end
print("")

local function one(f0, g, q)
	D.designPair(FS,
		{ kind = "lowshelf",  f0 = f0, gainDb = g, shape = q },
		{ kind = "highshelf", f0 = 4000, gainDb = 6, shape = 0.9 })
end

local t1 = ms(function() one(150, 12, 0.9) end, 20)
print(string.format("one designPair                     : %6.1f ms", t1))
print(string.format("a knob click today (design+writes) : %6.1f ms", t1 + 22))
print("")
print("What a verified clamp would add:")
for _, n in ipairs({ 3, 7, 14, 21 }) do
	print(string.format("  %2d extra designs (%s) : %6.1f ms  -> click becomes %6.1f ms",
		n,
		(n == 3 and "current + 2 neighbours") or
		(n == 7 and "a 7-point neighbourhood") or
		(n == 14 and "7-point, one Q step down") or
		"7-point, three Q steps down",
		n * t1, t1 + 22 + n * t1))
end
