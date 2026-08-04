--[[
SBRadioEQ -- test_faultwrite.lua       cd /tmp && jive test_faultwrite

WHAT HAPPENS WHEN A HARDWARE WRITE FAILS.

Two audio-safety defects were found by external review on 2026-08-02, and both
were guarded by tests that could not have caught them:

1. `applyBSPMuted` was a bare sequence -- mute, write, restore. Any throw in the
   middle skipped the restore and left the Radio MUTED with no message. The test
   alongside it asserted the mute "must ALWAYS be undone", and passed, because
   its stub had no way to throw. It proved the happy path and called it a
   guarantee.

2. The shell path ended `M.execute(cmd); return cmd` -- discarding the exit
   status and returning a string, which is always truthy. The applet then
   advanced its cache and called _levelMatch(), which RAISES THE PLAYER VOLUME to
   compensate for attenuation that may not exist. Up to 34 dB of make-up over
   unattenuated audio.

So this file's stubs THROW. A stub that cannot fail cannot test failure handling,
and every assertion below is about the failure path.
]]

local A = require("eqapply")
local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-52s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-52s %s", name, detail or "")) end
end

--[[
A stub that records every write and throws on the Nth one. failAt = 0 never
throws, which gives the control case.
]]
local function stub(failAt, failAlwaysOn)
	local s = { seq = {}, n = 0 }
	function s:setMixer(name, a, b)
		s.n = s.n + 1
		s.seq[#s.seq + 1] = { name = name, a = a, n = s.n }
		-- a control that is broken for good, not just once: the restore is
		-- retried, so a single-shot fault there RECOVERS and must report success
		if failAlwaysOn and name == failAlwaysOn then
			error("injected permanent fault on " .. name, 0)
		end
		if failAt and failAt > 0 and s.n == failAt then
			error("injected mixer fault at write " .. s.n, 0)
		end
	end
	return s
end

local function pair(bg, tg)
	return D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = bg, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = tg, shape = 0.9 })
end

local c1, c2 = pair(12, 6)
local d1, d2 = pair(12.5, 6)
local PREV = { c1 = c1, c2 = c2 }

local function restoreWrites(s)
	local n = 0
	for _, e in ipairs(s.seq) do
		if e.name == A.MUTE_CTL and e.a ~= 0 then n = n + 1 end
	end
	return n
end

-- how many writes a clean run takes, so the fault sweep covers all of them
local baseline
do
	A.forgetMutePoint(); A.mutePoint()
	local s = stub(0)
	A.applyBSPMuted(s, d1, d2, PREV, false, false)
	baseline = s.n
end

print(string.format("=== a clean run takes %d writes; faulting each in turn ===", baseline))

print("=== the mute is ALWAYS restored, whichever write throws ===")
do
	local notRestored, threw = {}, {}
	for k = 2, baseline do            -- 1 is the mute itself, covered separately
		A.forgetMutePoint(); A.mutePoint()
		local s = stub(k)
		local okCall, res = pcall(A.applyBSPMuted, s, d1, d2, PREV, false, false)
		if not okCall then
			threw[#threw + 1] = tostring(k)
		elseif restoreWrites(s) == 0 then
			notRestored[#notRestored + 1] = tostring(k)
		end
	end
	ok("no fault position escapes as an exception", #threw == 0,
	   #threw > 0 and ("threw at write " .. table.concat(threw, ",")) or
	   string.format("%d positions, all handled", baseline - 1))
	ok("the mute is restored at every fault position", #notRestored == 0,
	   #notRestored > 0 and ("left MUTED at write " .. table.concat(notRestored, ","))
	                     or "restore attempted in every case")
end

print("=== a failed write reports ok=false, never a silent success ===")
do
	--[[
	Positions 2..baseline-1 are the coefficient write itself; a fault there is
	unrecoverable and must be reported. The LAST position is the mute restore,
	which is retried -- a one-shot fault there genuinely recovers, and reporting
	failure for a recovered operation would be wrong. That case is covered
	separately below with a permanently broken control.
	]]
	local silent = {}
	for k = 2, baseline - 1 do
		A.forgetMutePoint(); A.mutePoint()
		local s = stub(k)
		local _, res = pcall(A.applyBSPMuted, s, d1, d2, PREV, false, false)
		if type(res) ~= "table" or res.ok ~= false then
			silent[#silent + 1] = tostring(k)
		end
	end
	ok("every write-path fault returns ok=false", #silent == 0,
	   #silent > 0 and ("reported success at " .. table.concat(silent, ",")) or
	   string.format("%d positions, no silent successes", baseline - 2))

	-- and the recovered case is a SUCCESS, not a failure
	A.forgetMutePoint(); A.mutePoint()
	local s = stub(baseline)
	local _, rec = pcall(A.applyBSPMuted, s, d1, d2, PREV, false, false)
	ok("a restore that succeeds on retry reports success",
	   type(rec) == "table" and rec.ok == true,
	   "the retry recovered it, so it did not fail")
end

print("=== the filter is left BYPASSED after a partial write ===")
do
	--[[
	A partial coefficient set is the +42 dB resonance measured on 2026-08-01.
	Unmuting into it is the worst outcome available, so bypass must come first.
	]]
	--[[
	Scoped to genuinely PARTIAL writes, i.e. the ones where the coefficient write
	itself failed (hardwareStateUnknown). The last fault position is the mute
	RESTORE, by which time the filter is complete and correctly enabled -- leaving
	it enabled there is right, and an earlier version of this assertion wrongly
	flagged it. Testing the complete-write case as if it were partial would have
	forced a wrong "fix" into the production path.
	]]
	--[[
	⛔ SELECT ON "THE COEFFICIENT WRITE FAILED", NOT ON hardwareStateUnknown.

	This loop used to pick its rows with res.hardwareStateUnknown, which was then
	set on every write failure. It now means something stricter and more useful --
	"nobody can vouch for the chip's state" -- and is FALSE when the recovery
	bypass is confirmed, which is exactly what happens in these single-fault
	fixtures. The selector therefore matched zero rows and the assertion failed on
	`partials > 0` while the property it guards still held.

	ok == false with writes == 0 is the real predicate: the write did not
	complete. (A restore failure returns ok == false with writes == n, and the
	no-op path returns ok == true.)
	]]
	local bad, partials = {}, 0
	for k = 3, baseline do
		A.forgetMutePoint(); A.mutePoint()
		local s = stub(k)
		local _, res = pcall(A.applyBSPMuted, s, d1, d2, PREV, false, false)
		if type(res) == "table" and res.ok == false and res.writes == 0 then
			partials = partials + 1
			local lastEnable
			for _, e in ipairs(s.seq) do
				if e.name == A.NAME.enable then lastEnable = e.a end
			end
			if lastEnable ~= nil and lastEnable ~= A.BYPASS then
				bad[#bad + 1] = string.format("k=%d left enable=%s", k, tostring(lastEnable))
			end
		end
	end
	ok("never left enabled after a partial write", #bad == 0 and partials > 0,
	   #bad > 0 and table.concat(bad, " | ")
	            or string.format("%d partial-write faults, all left bypassed", partials))
end

print("=== an UNRECOVERABLE unmute is reported, not left silently muted ===")
do
	--[[
	The mute control is broken for good, so every retry fails too. The device
	really is left silent -- which must be REPORTED, because silence with no
	message is the one failure the user cannot diagnose.

	Note the mute-control writes are the first and last of the sequence, so this
	also exercises "could not even mute", which must not proceed to write
	coefficients into a live filter.
	]]
	A.forgetMutePoint(); A.mutePoint()
	local s = stub(0, A.MUTE_CTL)
	local _, res = pcall(A.applyBSPMuted, s, d1, d2, PREV, false, false)
	ok("a permanently broken mute control is reported",
	   type(res) == "table" and res.ok == false,
	   type(res) == "table" and tostring(res.error) or type(res))
	ok("it does not write coefficients into a live filter",
	   (function()
		   for _, e in ipairs(s.seq) do
			   if e.name ~= A.MUTE_CTL then return false end
		   end
		   return true
	   end)(), string.format("%d writes, mute control only", s.n))
end

--[[
COMPOUND FAULT -- the case the single-fault sweep above cannot reach.

Every fixture so far breaks ONE write, so the recovery bypass that follows always
succeeds and the device is safely unmuted. The dangerous combination is a write
that fails while the enable control is broken FOR GOOD: then the recovery cannot
be confirmed, and restoring the volume would unmute into a filter nobody can
vouch for -- possibly a partial coefficient set, which is the +42.1 dB
intermediate diag_shriek measured.

Silence is the correct outcome here, and it must be REPORTED (stillMuted) so the
screen can explain it. Silence with a cause is a different thing from silence
with none.
]]
print("=== COMPOUND FAULT: recovery bypass fails too -> stay muted ===")
do
	A.forgetMutePoint(); A.mutePoint()
	local s = stub(0, A.NAME.enable)      -- the enable control never works
	local _, res = pcall(A.applyBSPMuted, s, d1, d2, PREV, false, false)
	local t = (type(res) == "table") and res or {}

	ok("reports failure", t.ok == false, tostring(t.error))
	ok("does NOT claim the bypass was confirmed", not t.safeBypassed,
	   "safeBypassed=" .. tostring(t.safeBypassed))
	ok("reports the hardware state as unknown", t.hardwareStateUnknown == true,
	   "hardwareStateUnknown=" .. tostring(t.hardwareStateUnknown))
	ok("leaves the device MUTED rather than unmuting into it",
	   t.stillMuted == true and restoreWrites(s) == 0,
	   string.format("stillMuted=%s, restore writes=%d",
	                 tostring(t.stillMuted), restoreWrites(s)))
end

print("=== a clean run still reports ok=true and writes ===")
do
	A.forgetMutePoint(); A.mutePoint()
	local s = stub(0)
	local res = A.applyBSPMuted(s, d1, d2, PREV, false, false)
	ok("ok=true on success", type(res) == "table" and res.ok == true,
	   type(res) == "table" and tostring(res.ok) or type(res))
	ok("reports how many coefficients were written",
	   type(res) == "table" and type(res.writes) == "number" and res.writes > 0,
	   type(res) == "table" and tostring(res.writes) or "?")
	ok("the no-op path also reports ok", (function()
		local r = A.applyBSPMuted(stub(0), c1, c2, PREV, false, false)
		return type(r) == "table" and r.ok == true and r.writes == 0
	end)(), "nothing to write -> ok=true, writes=0")
end

print("=== the SHELL path reports failure instead of a truthy string ===")
do
	local realExecute = A.execute

	A.execute = function() return 1 end                     -- non-zero exit
	local r = A.apply(c1, c2, false)
	ok("non-zero exit is a failure", type(r) == "table" and r.ok == false,
	   type(r) == "table" and tostring(r.error) or type(r) .. " (was: the command string)")

	A.execute = function() error("amixer missing", 0) end   -- throws
	r = A.apply(c1, c2, false)
	ok("a throwing execute is a failure", type(r) == "table" and r.ok == false,
	   type(r) == "table" and tostring(r.error) or type(r))

	A.execute = function() return 0 end                     -- success
	r = A.apply(c1, c2, false)
	ok("exit 0 is a success", type(r) == "table" and r.ok == true, "")

	A.execute = realExecute
end

--[[
NEGATIVE CONTROL. The old implementation is reproduced exactly. If these
assertions can be satisfied by it, they are not testing anything.
]]
print("=== the OLD implementations FAIL these assertions ===")
do
	local function oldMuted(bsp)
		bsp:setMixer(A.MUTE_CTL, 0, 0)
		bsp:setMixer(A.NAME.enable, A.BYPASS)
		bsp:setMixer(A.NAME.band1.N0, 1, 1)      -- throws here in the fixture
		bsp:setMixer(A.MUTE_CTL, 127, 127)
		return 3
	end
	local s = stub(3)
	local okCall = pcall(oldMuted, s)
	ok("old mute path escapes as an exception", not okCall, "unprotected sequence")
	ok("old mute path leaves the device MUTED", restoreWrites(s) == 0,
	   "restore never reached")

	local function oldApply() local cmd = "amixer ..." ; return cmd end
	local r = oldApply()
	ok("old shell path returns a truthy string, not a result",
	   type(r) == "string" and r and true, "any caller reads this as success")

	assert(not okCall and restoreWrites(s) == 0 and type(oldApply()) == "string",
	       "negative control did not fire: these tests would pass on the old code")
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
