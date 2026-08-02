--[[
SBRadioEQ -- test_nospawn.lua          cd /tmp && jive test_nospawn

THE GATE. Nothing in the apply path may spawn a process.

applyBSPMuted used to read the PCM volume before muting, via
M.readRaw -> io.popen -> amixer. diag_spawn.lua measured it on the device:

    amixer spawn      215.50 ms   -- 91% of the click
    all 9 setMixer     20.70 ms   (2.30 ms each)

215 ms of fork/exec per knob click, on a 360 MHz single core that is decoding
audio at the same time. That starves the decoder, and it is what the user heard
as popping. Meanwhile two rounds of optimisation went into the 20 ms of
setMixer calls beside it -- one of which removed a safety bracket and produced
an audible shriek.

The reason it stayed invisible for so long is worth stating: os.clock() on this
platform is CPU time. It scores a blocking ioctl at 0.00 ms and charges nothing
for a child process, so it reports the spawn as nearly free. Any future timing
here must use a wall clock that has been checked against a known duration --
diag_spawn.lua does that before it reports anything.

This gate does not time anything, so it cannot be fooled by a bad clock. It
counts spawns.
]]

local A = require("eqapply")
local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-50s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-50s %s", name, detail or "")) end
end

local function stub()
	local s = { seq = {} }
	function s:setMixer(name, a, b) s.seq[#s.seq + 1] = { name = name, a = a } end
	return s
end

--[[
Count spawns by replacing the FIELDS on the io and os tables, not the globals.
eqapply may hold `local io = io`; the local still points at the same table, so
patching the field is seen either way, while patching the global name would not
be.
]]
local realPopen, realExecute = io.popen, os.execute
local spawns

local function countSpawns(f)
	spawns = {}
	io.popen = function(cmd) spawns[#spawns + 1] = "popen: " .. tostring(cmd); return nil end
	os.execute = function(cmd) spawns[#spawns + 1] = "execute: " .. tostring(cmd); return 0 end
	local okRun, err = pcall(f)
	io.popen, os.execute = realPopen, realExecute
	if not okRun then error(err) end
	return spawns
end

--[[
NEGATIVE CONTROL -- the counter must actually see a spawn. If patching the field
does not intercept eqapply's own call, every other assertion here is vacuous.
]]
print("=== the counter sees a real spawn (negative control) ===")
do
	local s = countSpawns(function() A.readRaw(A.NUMID.pcmVolume) end)
	ok("readRaw is detected as a spawn", #s == 1, s[1] or "NOTHING INTERCEPTED")

	-- and the uncached path, which is the exact regression being guarded
	A.forgetMutePoint()
	s = countSpawns(function() A.mutePoint() end)
	ok("a cold mutePoint() spawns exactly once", #s == 1, s[1] or "none")
end

print("=== once primed, mutePoint never spawns again ===")
do
	A.forgetMutePoint()
	A.mutePoint()                                   -- prime it, off the knob path
	local s = countSpawns(function()
		for _ = 1, 50 do A.mutePoint() end
	end)
	ok("50 calls, zero spawns", #s == 0, tostring(#s) .. " spawns")
end

--[[
THE REAL ARTIFACT. A knob turn is a run of applyBSPMuted calls; sweep one and
require the whole run to be spawn-free.
]]
print("=== a knob sweep through applyBSPMuted spawns nothing ===")
do
	local function pairAt(g)
		return D.designPair(FS,
			{ kind = "lowshelf",  f0 = 150,  gainDb = g, shape = 0.9 },
			{ kind = "highshelf", f0 = 4000, gainDb = 6, shape = 0.9 })
	end

	A.forgetMutePoint()
	A.mutePoint()                                   -- the applet does this on open

	local clicks = 0
	local s = countSpawns(function()
		local c1, c2 = pairAt(0)
		local prev = { c1 = c1, c2 = c2 }
		for g = 0.5, 15.0, 0.5 do
			local n1, n2 = pairAt(g)
			A.applyBSPMuted(stub(), n1, n2, prev, false, false)
			prev = { c1 = n1, c2 = n2 }
			clicks = clicks + 1
		end
	end)
	ok("full gain sweep is spawn-free", #s == 0,
	   string.format("%d clicks, %d spawns %s", clicks, #s, s[1] or ""))
end

print("=== the transitions spawn nothing either ===")
do
	local c1, c2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = 9, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = 6, shape = 0.9 })
	local d1, d2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = 9.5, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = 6, shape = 0.9 })
	A.forgetMutePoint(); A.mutePoint()

	local cases = {
		{ "first write, no history", function() A.applyBSPMuted(stub(), c1, c2, nil, false, nil) end },
		{ "entering bypass",  function() A.applyBSPMuted(stub(), c1, c2, { c1=c1, c2=c2 }, true, false) end },
		{ "leaving bypass",   function() A.applyBSPMuted(stub(), d1, d2, { c1=c1, c2=c2 }, false, true) end },
		{ "no-op",            function() A.applyBSPMuted(stub(), c1, c2, { c1=c1, c2=c2 }, false, false) end },
	}
	for _, c in ipairs(cases) do
		local s = countSpawns(c[2])
		ok(c[1], #s == 0, tostring(#s) .. " spawns " .. (s[1] or ""))
	end
end

--[[
And the value must still be the hardware's, not a hardcoded guess -- that was the
whole reason for reading it. Caching may not quietly turn into assuming.
]]
print("=== the cached value still comes FROM the hardware ===")
do
	A.forgetMutePoint()
	io.popen = realPopen
	local live = A.readRaw(A.NUMID.pcmVolume)
	A.forgetMutePoint()
	ok("mutePoint() equals what the control reports", A.mutePoint() == live,
	   string.format("mutePoint=%s control=%s", tostring(A.mutePoint()), tostring(live)))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
