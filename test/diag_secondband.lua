--[[
cd /tmp && jive diag_secondband

From the live log, the exact transition the user reports as "adding a second boost
drops the overall volume":

  bassG=8 trebG=0   atten=8.065   volume 47
  bassG=8 trebG=15  atten=14.961  volume 61   (level match moved it +6.9 dB)

Compute the ABSOLUTE output level in both states -- filter response plus the
player volume -- and compare per frequency. If the midband falls, the make-up is
referenced to the wrong thing.
]]

local D  = require("eqdesign")
local FS = 44100

local function state(bg, tg, vol)
	local _, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 266,  gainDb = bg, shape = 1.2  },
		{ kind = "highshelf", f0 = 4384, gainDb = tg, shape = 0.95 })
	local volDb = D.volumeToDb(vol)
	return function(f)
		local d = volDb
		if i.ideal1 then
			d = d + D.responseDb(i.ideal1.b0, i.ideal1.b1, i.ideal1.b2, i.ideal1.a1, i.ideal1.a2, f, FS)
		end
		if i.ideal2 then
			d = d + D.responseDb(i.ideal2.b0, i.ideal2.b1, i.ideal2.b2, i.ideal2.a1, i.ideal2.a2, f, FS)
		end
		return d
	end, i.attenDb, volDb
end

local before, aB, vB = state(8, 0,  47)
local after,  aA, vA = state(8, 15, 61)

print(string.format("before: bass+8  treb+0   atten %.2f  vol 47 = %.2f dB", aB, vB))
print(string.format("after : bass+8  treb+15  atten %.2f  vol 61 = %.2f dB", aA, vA))
print(string.format("volume moved %+.2f dB, atten moved %+.2f dB", vA - vB, aA - aB))
print("")
print("   freq     before      after     change")
for _, f in ipairs({ 50, 100, 200, 400, 800, 1500, 3000, 6000, 12000 }) do
	local b, a = before(f), after(f)
	print(string.format("%7.0f   %8.2f   %8.2f   %+8.2f", f, b, a, a - b))
end

print("")
print("A rough loudness proxy: unweighted mean across the band.")
local sb, sa, n = 0, 0, 0
for _, f in ipairs({ 50, 80, 125, 200, 315, 500, 800, 1250, 2000, 3150, 5000, 8000, 12500 }) do
	sb = sb + before(f); sa = sa + after(f); n = n + 1
end
print(string.format("mean before %.2f dB, after %.2f dB, change %+.2f dB", sb/n, sa/n, sa/n - sb/n))
