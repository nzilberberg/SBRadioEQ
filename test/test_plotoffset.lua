--[[
SBRadioEQ -- test_plotoffset.lua      cd /tmp && jive test_plotoffset

The plotted curve must put unity on the centre line: a boost reads ABOVE it, a
cut BELOW it, and both-bands-boosted must not pin the whole curve under the axis.
This checks the display transform (design response + attenDb) that the applet
applies, independently of the applet's drawing code.
]]

local D  = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-46s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-46s %s", name, detail or "")) end
end

-- Exactly what the applet plots.
local function plotted(bassG, bassF, trebG, trebF)
	local _, i1 = D.design("lowshelf",  FS, bassF, bassG, 0.9)
	local _, i2 = D.design("highshelf", FS, trebF, trebG, 0.9)
	local off = (i1.attenDb or 0) + (i2.attenDb or 0)
	return function(f)
		local d = off
		local p, q = i1.ideal, i2.ideal
		if p then d = d + D.responseDb(p.b0, p.b1, p.b2, p.a1, p.a2, f, FS) end
		if q then d = d + D.responseDb(q.b0, q.b1, q.b2, q.a1, q.a2, f, FS) end
		return d
	end, off
end

print("=== bass boost reads ABOVE the line, mids stay at unity ===")
local c = plotted(12, 150, 0, 4000)
ok("50 Hz is boosted",      c(50)  >  6, string.format("%+.1f dB", c(50)))
ok("1 kHz sits near unity", math.abs(c(1000)) < 1.0, string.format("%+.1f dB", c(1000)))

print("=== bass CUT still reads below the line ===")
c = plotted(-12, 150, 0, 4000)
ok("50 Hz is cut",          c(50)  < -6, string.format("%+.1f dB", c(50)))
ok("1 kHz sits near unity", math.abs(c(1000)) < 1.0, string.format("%+.1f dB", c(1000)))

print("=== BOTH boosted -- the case that was crushed flat ===")
c = plotted(12, 150, 6, 4000)
ok("bass end above the line",  c(50)   >  6, string.format("%+.1f dB", c(50)))
ok("treble end above the line", c(12000) >  3, string.format("%+.1f dB", c(12000)))
ok("mids near unity",           math.abs(c(700)) < 2.0, string.format("%+.1f dB", c(700)))
-- The old behaviour: everything at or below 0, mids worst. Guard against regressing.
ok("NOT pinned under the axis", not (c(50) <= 0 and c(12000) <= 0),
   string.format("bass %+.1f, treble %+.1f", c(50), c(12000)))

print("=== mixed: bass boost + treble cut ===")
c = plotted(12, 150, -6, 4000)
ok("bass above", c(50) > 6, string.format("%+.1f dB", c(50)))
ok("treble below", c(12000) < -3, string.format("%+.1f dB", c(12000)))

print("=== flat stays flat ===")
c = plotted(0, 150, 0, 4000)
local worst = 0
for _, f in ipairs({ 40, 100, 1000, 8000, 16000 }) do
	if math.abs(c(f)) > worst then worst = math.abs(c(f)) end
end
ok("flat is within 0.01 dB of the line", worst < 0.01, string.format("%.4f dB", worst))

print("")
print(string.format("passed=%d failed=%d", pass, fail))
