--[[
SBRadioEQ -- test_textfit.lua          cd /tmp && jive test_textfit

THE GATE. No string may be drawn wider than the space it is drawn into.

Changing a font size is a two-line edit with a silent failure mode: the text
grows past its box and the end is simply not there. On a 320 px screen there is
very little slack, and nothing in the code says how much room each string has --
you find out by photographing the device.

So the sizes are READ FROM THE APPLET (not restated here, or the gate would pass
while the screen clipped) and every string is measured with the same Font the
device uses, against the width its region actually gives it.

What this does NOT gate: whether text is legible. That resists a cheap rule --
the concrete false positive is C_DIM at 61% alpha on the title bar's mode word,
which is deliberately secondary and correct, while the same value on the status
hint was unreadable. Same colour, same size, one right and one wrong. Legibility
stays a judgement made by looking at the device.
]]

local Font = require("jive.ui.Font")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-48s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-48s %s", name, detail or "")) end
end

local APPLET = "/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua"

-- Read `self.fontFoo = Font:load("fonts/Face.ttf", N)` out of the applet, so a
-- size change here is picked up rather than mirrored by hand.
local function fontsFrom(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. path end
	local out = {}
	for line in fh:lines() do
		local name, face, size =
			line:match('self%.(font%w+)%s*=%s*Font:load%("fonts/([%w]+)%.ttf",%s*(%d+)%)')
		if name then
			out[name] = { face = face, size = tonumber(size),
			              font = Font:load("fonts/" .. face .. ".ttf", tonumber(size)) }
		end
	end
	fh:close()
	return out
end

local F, err = fontsFrom(APPLET)
if not F then
	print("  FAIL " .. tostring(err))
	print("")
	print("passed=0 failed=1")
	return
end

print("=== the fonts the applet declares ===")
do
	local names = {}
	for k, v in pairs(F) do names[#names + 1] = string.format("%s=%s%d", k, v.face, v.size) end
	table.sort(names)
	ok("all four faces were found", F.fontS and F.fontXS and F.fontTitle and F.fontVal,
	   table.concat(names, " "))
end

-- Geometry, mirroring the applet's layout constants.
local SCREEN_W, PAD, CELL_GAP = 320, 6, 3
local CELL_W = math.floor((SCREEN_W - PAD * 2 - CELL_GAP * 2) / 3)
local CELL_TEXT_W = CELL_W - 8            -- labels/values are drawn at x + 4

--[[
Every string the screen can show, with the room it has. Worst cases only: the
longest hint, the widest cell label, and the widest value each control can
produce (16000 Hz, -15.0 dB, 2.00 Q).
]]
local ITEMS = {
	{ font = "fontHint", avail = SCREEN_W - PAD * 2, what = "status hint",
	  strings = { "turn: select   press: edit   hold: bypass",
	              "turn: adjust   press: ok   back: cancel" } },
	{ font = "fontXS", avail = CELL_TEXT_W, what = "cell label",
	  strings = { "BASS Hz", "BASS dB", "BASS Q", "TREB Hz", "TREB dB", "TREB Q" } },
	{ font = "fontVal", avail = CELL_TEXT_W, what = "cell value",
	  strings = { "16000", "-15.0", "+15.0", "2.00", "0.20", "1.05" } },
	{ font = "fontXS", avail = 40, what = "graph frequency label",
	  strings = { "100", "1k", "10k" } },
}

print("=== every string fits the region it is drawn into ===")
for _, it in ipairs(ITEMS) do
	local f = F[it.font]
	if not f then
		ok(it.what, false, "applet declares no " .. it.font)
	else
		local worst, wstr = 0, ""
		for _, s in ipairs(it.strings) do
			local w = f.font:width(s)
			if w > worst then worst, wstr = w, s end
		end
		ok(it.what .. " fits", worst <= it.avail,
		   string.format('%s%d: widest "%s" = %d px of %d',
		                 f.face, f.size, wstr, worst, it.avail))
	end
end

--[[
The title bar is a COMPOSITE: name, mode and readout share one row, the readout
right-aligned. Fitting individually is not enough -- they must not collide.
]]
print("=== the title bar's three items do not collide ===")
do
	local left  = PAD + F.fontTitle.font:width("Equalizer") + 6 + F.fontS.font:width("bypassed")
	local right = F.fontS.font:width("NO HEADROOM") + PAD
	ok("name + mode + readout fit one row", left + right <= SCREEN_W,
	   string.format("%d left + %d right = %d of %d px", left, right, left + right, SCREEN_W))
end

--[[
Vertical fit. STATUS_H is READ from the applet, not restated: an earlier version
hardcoded 20 here, and raising the strip to 24 would have left this gate
checking a number the applet no longer used -- passing while measuring fiction.
Same reason the font sizes are parsed rather than mirrored.
]]
print("=== vertical: the hint fits inside the status strip ===")
do
	local statusH, offset
	local fh = io.open(APPLET, "r")
	for line in fh:lines() do
		statusH = tonumber(line:match("^local STATUS_H%s*=%s*(%d+)")) or statusH
		offset  = tonumber(line:match("sh %- STATUS_H %+ (%d+)%)")) or offset
	end
	fh:close()

	ok("STATUS_H and the baseline offset were both found",
	   statusH ~= nil and offset ~= nil,
	   string.format("STATUS_H=%s offset=%s", tostring(statusH), tostring(offset)))

	if statusH and offset then
		local room = statusH - offset
		ok("hint height fits the strip", F.fontHint.font:height() <= room,
		   string.format("%d px tall, %d px of room (strip %d, drawn at +%d)",
		                 F.fontHint.font:height(), room, statusH, offset))
	end
end

--[[
NEGATIVE CONTROL. Generated, so it cannot go missing when /tmp is cleared -- that
already silently disarmed test_globals once. An oversized hint font is exactly
the mistake this gate exists to catch.
]]
print("=== the gate FIRES on a font size that would clip ===")
do
	local FIX = "/tmp/fixture_bigfont.lua"
	local fh = io.open(FIX, "w")
	if fh then
		fh:write('\tself.fontHint  = Font:load("fonts/FreeSansBold.ttf", 20)\n')
		fh:write('\tself.fontS     = Font:load("fonts/FreeSans.ttf", 12)\n')
		fh:write('\tself.fontXS    = Font:load("fonts/FreeSans.ttf", 9)\n')
		fh:write('\tself.fontTitle = Font:load("fonts/FreeSansBold.ttf", 14)\n')
		fh:write('\tself.fontVal   = Font:load("fonts/FreeSansBold.ttf", 15)\n')
		fh:close()
	end
	local G = fontsFrom(FIX)
	local caught = false
	if G and G.fontHint then
		local w = G.fontHint.font:width("turn: select   press: edit   hold: bypass")
		caught = w > (SCREEN_W - PAD * 2)
		ok("an oversized hint font is caught", caught,
		   string.format("FreeSansBold20 would need %d px of %d", w, SCREEN_W - PAD * 2))
	else
		ok("fixture readable", false, "could not write or parse the fixture")
	end

	-- A gate that cannot fail is not a gate; abort rather than report a
	-- comfortable pass if the detector has stopped detecting.
	assert(caught, "negative control did not fire: this test can no longer fail")
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
