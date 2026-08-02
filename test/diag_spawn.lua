--[[
cd /tmp && jive diag_spawn

applyBSPMuted reads the PCM volume before muting, so it can restore exactly what
it found rather than hardcoding 127. That read is M.readRaw -> io.popen ->
a full amixer PROCESS SPAWN, and it happens on every knob click, in the apply
path, on a 360 MHz single core that is simultaneously decoding audio.

Read-only measurement: amixer cget touches nothing. Compares the spawn against
the in-process BSP write it sits next to, so the cost is in the units that
matter -- how much of the click's work is the spawn.
]]

local A = require("eqapply")
local bsp = require("baby_bsp")
local Framework = require("jive.ui.Framework")

--[[
os.clock() is CPU time on this platform, not wall time. It scored setMixer at
0.00 ms -- an ioctl that blocks in the kernel burns no user CPU -- and it charges
nothing for the amixer CHILD process either. Both are exactly the costs being
measured, so os.clock() cannot see this at all.

Framework:getTicks() is SDL's millisecond wall clock. Verified below against a
known-slow operation before any conclusion is drawn from it.
]]
local function ms(f, n)
	local t0 = Framework:getTicks()
	for _ = 1, n do f() end
	return (Framework:getTicks() - t0) / n
end

print("PCM Playback Volume reads back as: " .. tostring(A.readRaw(A.NUMID.pcmVolume)))
print("")

--[[
INSTRUMENT CHECK. A clock that reports 0 for everything looks like a fast system,
which is exactly how os.clock() hid a 220 ms spawn.

The first version of this check timed a 20 ms busy-wait AGAINST THE SAME CLOCK,
which cannot detect a wrong clock at all -- and it duly cried wolf, reporting
31 ms for a 20 ms wait. Nothing was wrong with the clock: a tight Lua loop on a
single core that is decoding audio gets descheduled, so it was measuring
scheduler jitter. A check with a false-positive mode is a check that gets
ignored.

So: cross-check against an INDEPENDENT source. os.time() is seconds-resolution
and derived separately, so measuring a ~2 s interval by both is immune to
millisecond jitter and actually falsifies a wrong clock.
]]
do
	local t0, c0 = os.time(), Framework:getTicks()
	while os.time() - t0 < 2 do end
	local wall, ticks = os.time() - t0, (Framework:getTicks() - c0) / 1000
	local sane = math.abs(ticks - wall) <= 0.5
	print(string.format("instrument check: os.time says %.0f s, getTicks says %.2f s %s",
		wall, ticks, sane and "-- clock is sane" or "-- CLOCK IS WRONG, ignore what follows"))
end
print("")

local spawn = ms(function() A.readRaw(A.NUMID.pcmVolume) end, 10)
print(string.format("readRaw (io.popen + amixer cget) : %7.2f ms", spawn))

--[[
The write it sits beside. Timed on a COEFFICIENT control, not on the volume
control: baby_bsp's find_element does a LINEAR search of the control list per
call, so numid=1 is the cheapest possible write and would understate every
coefficient write in the apply path. Each control is written back the value it
already holds, so nothing changes and nothing is audible.
]]
local v = A.readRaw(A.NUMID.pcmVolume) or 127
local volWrite = ms(function() bsp:setMixer(A.MUTE_CTL, v, v) end, 10)

local cName = A.NAME.band2.N2                       -- numid=27, deep in the list
local cRaw  = A.readRaw(A.NUMID.band2.N2) or 0
local write = ms(function() bsp:setMixer(cName, cRaw, cRaw) end, 10)

print(string.format("bsp:setMixer, volume  (numid=1)  : %7.2f ms", volWrite))
print(string.format("bsp:setMixer, coeff  (numid=27)  : %7.2f ms  <- the real cost", write))

print("")
print(string.format("The spawn is %.0fx one write.", spawn / write))
print(string.format("A 9-call bracketed click costs %.1f ms of setMixer;", 9 * write))
print(string.format("the spawn adds %.1f ms on top, i.e. %.0f%% of the click.",
	spawn, 100 * spawn / (spawn + 9 * write)))

--[[
Now the thing that actually matters: what one knob click costs END TO END,
through the real applyBSPMuted, with the cache cold and warm. Cold is what every
click used to be.
]]
local D = require("eqdesign")
local FS = 44100
local function pairAt(g)
	return D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = g, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = 6, shape = 0.9 })
end

-- A stub bsp: this measures the applet's own overhead, not hardware writes,
-- so the comparison is not contaminated by touching the codec mid-playback.
local stubBsp = { setMixer = function() end }

local a1, a2 = pairAt(9.0)
local b1, b2 = pairAt(9.5)

local cold = ms(function()
	A.forgetMutePoint()
	A.applyBSPMuted(stubBsp, b1, b2, { c1 = a1, c2 = a2 }, false, false)
end, 5)

A.forgetMutePoint(); A.mutePoint()
local warm = ms(function()
	A.applyBSPMuted(stubBsp, b1, b2, { c1 = a1, c2 = a2 }, false, false)
end, 5)

print("")
print("One knob click through applyBSPMuted (stub bsp, so this is pure overhead):")
print(string.format("  cache COLD (what every click used to do) : %7.2f ms", cold))
print(string.format("  cache WARM (primed when the screen opens): %7.2f ms", warm))
if cold > 0 then
	print(string.format("  removed from the knob path               : %7.2f ms", cold - warm))
end
