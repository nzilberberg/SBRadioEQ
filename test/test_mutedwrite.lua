--[[
SBRadioEQ -- test_mutedwrite.lua      cd /tmp && jive test_mutedwrite

The bypass window cannot be avoided: partial coefficient writes measured +28 dB at
50 Hz, so the filter MUST be off while the set goes in. applyBSPMuted silences that
window instead, using the DAC digital volume (soft-stepped in hardware, so the
ramps cannot click).

Two things must hold or this is worse than what it replaces:
  * the mute must ALWAYS be undone -- a stuck mute is silent audio forever;
  * it must not mute when there is nothing to write -- a dip for no reason is
    exactly the stutter this is trying to avoid.

Stub bsp: touches no hardware.
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
	function s:setMixer(name, a, b)
		s.seq[#s.seq + 1] = { name = name, a = a }
	end
	return s
end

local function pair(bg, tg)
	local c1, c2 = D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150,  gainDb = bg, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = tg, shape = 0.9 })
	return c1, c2
end

local function muteEvents(s)
	local out = {}
	for _, e in ipairs(s.seq) do
		if e.name == A.MUTE_CTL then out[#out + 1] = e.a end
	end
	return out
end

print("=== a real change is wrapped in mute / restore ===")
local c1, c2 = pair(12, 6)
local d1, d2 = pair(12.5, 6)
local b = stub()
A.applyBSPMuted(b, d1, d2, { c1 = c1, c2 = c2 }, false, false)
local m = muteEvents(b)
ok("exactly two mute-control writes", #m == 2, table.concat(m, ","))
ok("muted first, restored last", m[1] == 0 and m[2] > 0, table.concat(m, " -> "))
ok("mute is the FIRST thing written", b.seq[1] and b.seq[1].name == A.MUTE_CTL, "")
ok("restore is the LAST thing written",
   b.seq[#b.seq] and b.seq[#b.seq].name == A.MUTE_CTL, "")

--[[
The mute is IN ADDITION TO the bracket, never instead of it.

Skipping the bracket while muted was tried, to save 2 of 9 setMixer calls, on the
reasoning that a partial filter is inaudible while muted. The device produced a
half-second 11 kHz shriek. Mute silences the filter's OUTPUT; audio still flows
into it, so a running intermediate is still excited and stores energy that the
restore then plays back. diag_shriek.lua measures the intermediate at +42.1 dB
against a +2.5 dB endpoint.

test_bracketed.lua is the structural gate; this just pins the shape here too.
]]
print("=== the bracket is KEPT even though we are muted ===")
local enables = {}
for _, e in ipairs(b.seq) do
	if e.name == A.NAME.enable then enables[#enables + 1] = e.a end
end
ok("exactly two enable writes", #enables == 2, table.concat(enables, ","))
ok("bypassed first, re-enabled after", enables[1] == A.BYPASS and enables[2] == A.ENABLE_BOTH,
   table.concat(enables, " -> "))
ok("every coefficient write sits inside the bracket",
   b.seq[2] and b.seq[2].name == A.NAME.enable and b.seq[2].a == A.BYPASS
   and b.seq[#b.seq - 1] and b.seq[#b.seq - 1].name == A.NAME.enable,
   tostring(#b.seq) .. " calls: mute, bypass, coeffs, enable, restore")

print("=== NO mute when there is nothing to write (this is the stutter guard) ===")
b = stub()
-- applyBSPMuted returns a RESULT now, not a bare count: a caller has to be able
-- to tell a successful write from a failed one before it raises the volume.
-- See test_faultwrite.lua for the failure paths.
local r = A.applyBSPMuted(b, c1, c2, { c1 = c1, c2 = c2 }, false, false)
ok("no writes at all", r.ok == true and r.writes == 0 and #b.seq == 0,
   string.format("ok=%s writes=%s seq=%d", tostring(r.ok), tostring(r.writes), #b.seq))

print("=== already bypassed and asked to bypass: nothing happens ===")
b = stub()
A.applyBSPMuted(b, c1, c2, { c1 = c1, c2 = c2 }, true, true)
ok("silent no-op", #b.seq == 0, tostring(#b.seq) .. " writes")

print("=== entering bypass mutes, bypasses, restores ===")
b = stub()
A.applyBSPMuted(b, c1, c2, { c1 = c1, c2 = c2 }, true, false)
m = muteEvents(b)
ok("wrapped in mute/restore", #m == 2 and m[1] == 0 and m[2] > 0, table.concat(m, " -> "))

print("=== first write with no history is still wrapped ===")
b = stub()
A.applyBSPMuted(b, c1, c2, nil, false, nil)
m = muteEvents(b)
ok("wrapped in mute/restore", #m == 2 and m[1] == 0 and m[2] > 0, table.concat(m, " -> "))
ok("no history: writes the full set, bracketed", #b.seq == 2 + 2 + 10,
   tostring(#b.seq) .. " calls (mute + bypass + 10 coeffs + enable + restore)")

print("")
print(string.format("passed=%d failed=%d", pass, fail))
