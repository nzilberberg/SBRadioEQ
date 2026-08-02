--[[
cd /tmp && jive diag_qceiling

The volume ceiling got worse because fitCoeffs scales the WHOLE filter down when a
coefficient will not fit (|b1| < 2.0 is the binding one), and that scaling is
charged as make-up. bass+15/treble+15 went from 14.9 dB of make-up to 26.8.

The alternative is to stop the user reaching settings that do not fit -- clamp the
steepness control, visibly, instead of silently buying level. This measures whether
that is actually worth it: for each frequency and gain, the highest shape that
needs NO scaling, and the make-up saved by staying there.
]]

local D = require("eqdesign")
local FS = 44100

-- how much extra attenuation fitCoeffs would impose for this design
local function fitPenalty(kind, f0, g, s)
	if g == 0 then return 0, 0 end
	local b0,b1,b2,a1,a2 = D.designIdeal(kind, FS, f0, g, s)
	-- peak-normalise the way designPair does
	local peak = -1/0
	for _, f in ipairs(D.GRID) do
		local v = D.responseDb(b0,b1,b2,a1,a2,f,FS)
		if v > peak then peak = v end
	end
	if peak > 0 then
		local k = 10 ^ (-peak/20)
		b0,b1,b2 = b0*k, b1*k, b2*k
	end
	local worst = math.max(math.abs(b0)*32768, math.abs(b1)*16384, math.abs(b2)*32768)
	if worst <= 32000 then return 0, math.max(peak,0) end
	return -20 * (math.log(32000/worst)/math.log(10)), math.max(peak,0)
end

local function maxFittingShape(kind, f0, g)
	local best = nil
	for s = 2.0, 0.2, -0.05 do
		local pen = fitPenalty(kind, f0, g, s)
		if pen <= 0.01 then best = s break end
	end
	return best
end

print("BASS (lowshelf) -- highest steepness that needs no scaling, and the penalty at S=0.9")
print("  f0   gain   maxS    penalty@0.9")
for _, f0 in ipairs({ 100, 150, 266, 400, 800 }) do
	for _, g in ipairs({ 6, 12, 15 }) do
		local ms = maxFittingShape("lowshelf", f0, g)
		local pen = fitPenalty("lowshelf", f0, g, 0.9)
		print(string.format("%5d  %+4d   %s   %6.2f dB", f0, g,
			ms and string.format("%.2f", ms) or " none", pen))
	end
end

print("")
print("TREBLE (highshelf)")
print("  f0   gain   maxS    penalty@0.9")
for _, f0 in ipairs({ 1500, 2500, 4384, 8000, 14000 }) do
	for _, g in ipairs({ 6, 12, 15 }) do
		local ms = maxFittingShape("highshelf", f0, g)
		local pen = fitPenalty("highshelf", f0, g, 0.9)
		print(string.format("%5d  %+4d   %s   %6.2f dB", f0, g,
			ms and string.format("%.2f", ms) or " none", pen))
	end
end
