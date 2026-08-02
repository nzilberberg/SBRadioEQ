--[[
cd /tmp && jive diag_bootcheck

Does the curve the codec is holding actually MATCH the saved settings?

After a cold boot with the applet never opened, the filter came back enabled with
non-default coefficients. That proves something was written. It does not prove
the RIGHT thing was written -- and "the filter is on" would look identical if the
boot path applied a stale, default, or half-built curve.

So: read the chip, undo the driver's read-path byte swap, and compare against
what designPair produces for the saved settings. Anything other than an exact
integer match means the boot path and the UI path disagree.

Reads are byte-swapped and writes are not (aic3104_get_effect assembles
read(reg) | read(reg+1) << 8 while reg holds the MSB), so the swap must be undone
before comparing or every value looks wrong.
]]

local D = require("eqdesign")
local A = require("eqapply")
local FS = 44100

-- The saved settings, read from the device's own settings file.
local SETTINGS = "/etc/squeezeplay/userpath/settings/SBRadioEQ.lua"

local function loadSaved()
	local fh = io.open(SETTINGS, "r")
	if not fh then return nil, "cannot open " .. SETTINGS end
	local src = fh:read("*a"); fh:close()
	local chunk, err = loadstring(src)
	if not chunk then return nil, "parse: " .. tostring(err) end
	local env = {}
	setfenv(chunk, env)
	local okRun, runErr = pcall(chunk)
	if not okRun then return nil, "run: " .. tostring(runErr) end
	return env.settings
end

local s, err = loadSaved()
if not s then print("FAIL: " .. tostring(err)) return end

print("saved settings:")
print(string.format("  bass  %d Hz  %+.1f dB  Q %.2f", s.bassFreq, s.bassGain, s.bassQ))
print(string.format("  treb  %d Hz  %+.1f dB  Q %.2f", s.trebFreq, s.trebGain, s.trebQ))
print(string.format("  enabled=%s  appliedAtten=%.2f", tostring(s.enabled), s.appliedAtten or 0))
print("")

-- What the design engine says those settings should produce.
local c1, c2, info = D.designPair(FS,
	{ kind = "lowshelf",  f0 = s.bassFreq, gainDb = s.bassGain, shape = s.bassQ },
	{ kind = "highshelf", f0 = s.trebFreq, gainDb = s.trebGain, shape = s.trebQ })

print(string.format("designPair says attenDb = %.2f  (saved appliedAtten = %.2f)",
	info.attenDb or 0, s.appliedAtten or 0))
print("")

local ORDER = { "N0", "N1", "N2", "D1", "D2" }

local function check(label, want, map)
	print(label)
	local bad = 0
	for _, k in ipairs(ORDER) do
		local raw = A.readRaw(map[k])
		if raw == nil then
			print(string.format("  %-3s  READ FAILED", k)); bad = bad + 1
		else
			local got = A.toSigned(A.swap16(raw))
			local exp = want[k]
			local mark = (got == exp) and "" or "   <== MISMATCH"
			if got ~= exp then bad = bad + 1 end
			print(string.format("  %-3s  chip %7d   expected %7d%s", k, got, exp, mark))
		end
	end
	return bad
end

local bad = 0
bad = bad + check("BASS section (numid 22,23,24,28,29):", c1, A.NUMID.band1)
print("")
bad = bad + check("TREBLE section (numid 25,26,27,30,31):", c2, A.NUMID.band2)

print("")
local en = A.readRaw(A.NUMID.enable)
local wantEnable = (s.enabled and not (s.bassGain == 0 and s.trebGain == 0))
                   and A.ENABLE_BOTH or A.BYPASS
print(string.format("enable (numid 21): chip %s   expected %s%s",
	tostring(en), tostring(wantEnable), (en == wantEnable) and "" or "   <== MISMATCH"))
if en ~= wantEnable then bad = bad + 1 end

print("")
if bad == 0 then
	print("MATCH: the codec is holding exactly the saved curve.")
	print("Boot re-apply and the UI path produce identical integers.")
else
	print(string.format("MISMATCH in %d value(s) -- the boot path is NOT applying the saved curve.", bad))
end
