--[[
SBRadioEQ -- test_ordering.lua        cd /tmp && jive test_ordering

THE ORDER OF THE MUTE, THE FILTER AND THE VOLUME -- in one recorded sequence.

Neither of the existing suites can see this. test_faultwrite drives the hardware
function and knows nothing about player volume; test_levelstate drives the volume
arithmetic and knows nothing about the mute. The defect lived exactly between
them: applyBSPMuted restored the PCM volume and THEN returned, and only after
that did the applet bring the player volume down. So every DOWNWARD transition --
Reset Tone, bypassing, reducing a boost, cancelling an edit -- unmuted the output
while it still carried the old make-up, measured at up to 34.41 dB of it.

An ordering can only be asserted against a single ordered record, so the mixer
writes and the volume reconciliation are recorded into ONE list here.

The assertion that matters:
    no PCM restore may appear before a required downward volume adjustment.
]]

local A = require("eqapply")
local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-50s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-50s %s", name, detail or "")) end
end

-- One recorder for both layers. `seq` is the whole story, in order.
local function rig(reconcileVerdict)
	local r = { seq = {} }
	r.bsp = {}
	function r.bsp:setMixer(name, a)
		local what
		if name == A.MUTE_CTL then
			what = (a == 0) and "MUTE" or "UNMUTE"
		elseif name == A.NAME.enable then
			what = (a == A.BYPASS) and "BYPASS" or "ENABLE"
		else
			what = "COEFF"
		end
		r.seq[#r.seq + 1] = what
	end
	r.reconcile = function()
		r.seq[#r.seq + 1] = "VOLUME"
		return reconcileVerdict
	end
	return r
end

local function indexOf(seq, what)
	for i, v in ipairs(seq) do if v == what then return i end end
	return nil
end

local function pair(bg, tg)
	return D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = bg, shape = 1.0 },
		{ kind = "highshelf", f0 = 3000, gainDb = tg, shape = 1.0 })
end

local c1, c2 = pair(12, 6)
local d1, d2 = pair(3, 1)          -- a SMALLER curve: the downward transition
local PREV = { c1 = c1, c2 = c2 }

print("=== the volume is reconciled INSIDE the mute ===")
do
	A.forgetMutePoint(); A.mutePoint()
	local r = rig(true)
	local res = A.applyBSPMuted(r.bsp, d1, d2, PREV, false, false, r.reconcile)

	local iMute   = indexOf(r.seq, "MUTE")
	local iVolume = indexOf(r.seq, "VOLUME")
	local iUnmute = indexOf(r.seq, "UNMUTE")

	ok("the sequence mutes first", iMute == 1, table.concat(r.seq, " "))
	ok("the volume moves while muted", iVolume ~= nil and iMute < iVolume,
	   string.format("mute@%s volume@%s", tostring(iMute), tostring(iVolume)))
	ok("THE UNMUTE COMES AFTER THE VOLUME MOVE",
	   iUnmute ~= nil and iVolume ~= nil and iVolume < iUnmute,
	   string.format("volume@%s unmute@%s", tostring(iVolume), tostring(iUnmute)))
	ok("and the caller is told it was reconciled", res.reconciled == true,
	   "reconciled=" .. tostring(res.reconciled))
end

print("=== a downward move that FAILED must not be unmuted ===")
do
	--[[
	The callback answers "may the output be unmuted?". A downward reconciliation
	that could not happen -- no local player, no volume reading -- answers no,
	because unmuting then is precisely the loud state: attenuation reduced, its
	compensation still in the player volume.
	]]
	A.forgetMutePoint(); A.mutePoint()
	local r = rig(false)
	local res = A.applyBSPMuted(r.bsp, d1, d2, PREV, false, false, r.reconcile)

	ok("no unmute anywhere in the sequence", indexOf(r.seq, "UNMUTE") == nil,
	   table.concat(r.seq, " "))
	ok("reported as still muted", res.stillMuted == true,
	   "stillMuted=" .. tostring(res.stillMuted))
	ok("reported as NOT ok, so a caller cannot treat it as applied",
	   res.ok == false, "ok=" .. tostring(res.ok))
	ok("the hardware state is NOT called unknown -- the filter went in fine",
	   res.hardwareStateUnknown == false,
	   "hardwareStateUnknown=" .. tostring(res.hardwareStateUnknown))
end

print("=== with no callback at all, behaviour is unchanged ===")
do
	-- A caller may omit the reconcile callback -- the no-op early returns take no
	-- callback, and a test driving the low-level transaction directly need not
	-- supply one. The result must then report reconciled=false, so the caller
	-- knows the volume state was NOT handled for it.
	A.forgetMutePoint(); A.mutePoint()
	local r = rig(true)
	local res = A.applyBSPMuted(r.bsp, d1, d2, PREV, false, false, nil)
	ok("still applies and unmutes", res.ok == true and indexOf(r.seq, "UNMUTE") ~= nil,
	   table.concat(r.seq, " "))
	ok("and says it did NOT reconcile, so the caller knows to do it",
	   res.reconciled == false, "reconciled=" .. tostring(res.reconciled))
end

--[[
NEGATIVE CONTROL. The old ordering is reproduced exactly: unmute, then move the
volume. If the assertions above can be satisfied by it, they are not testing the
ordering at all.
]]
print("=== the OLD ordering FAILS the assertion above ===")
do
	local seq = {}
	seq[#seq + 1] = "MUTE"
	seq[#seq + 1] = "BYPASS"
	seq[#seq + 1] = "COEFF"
	seq[#seq + 1] = "ENABLE"
	seq[#seq + 1] = "UNMUTE"        -- applyBSPMuted returned here...
	seq[#seq + 1] = "VOLUME"        -- ...and the applet moved the volume after

	local iVolume = indexOf(seq, "VOLUME")
	local iUnmute = indexOf(seq, "UNMUTE")
	ok("old order puts the unmute BEFORE the volume move", iUnmute < iVolume,
	   table.concat(seq, " "))
	assert(iUnmute < iVolume, "negative control did not fire")
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
