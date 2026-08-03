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
	-- fontTitle and fontHint were REMOVED along with our title and status bars:
	-- the window draws the title itself and the framework owns the iconbar.
	-- Asserting their ABSENCE too, so re-adding a bar has to come back through
	-- this test rather than quietly reappearing over the framework's.
	ok("the three surviving faces were found", F.fontS and F.fontXS and F.fontVal,
	   table.concat(names, " "))
	ok("fontTitle and fontHint are gone", not F.fontTitle and not F.fontHint,
	   "we draw neither bar")
end

-- Geometry, mirroring the applet's layout constants.
local SCREEN_W, PAD, CELL_GAP = 320, 6, 3
local CELL_W = math.floor((SCREEN_W - PAD * 2 - CELL_GAP * 2) / 3)
local CELL_TEXT_W = CELL_W - 4            -- labels/values are drawn at x + 2

--[[
Every string the screen can show, with the room it has. Worst cases only: the
longest hint, the widest cell label, and the widest value each control can
produce (16000 Hz, -15.0 dB, 2.00 Q).
]]
local ITEMS = {
	-- The status hint is gone: it duplicated navigation every screen already
	-- teaches, and it printed across the framework's battery and wifi icons.
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
OUR TITLE-BAR STRINGS MUST NOT REACH THE FRAMEWORK'S TITLE.

We no longer draw a title bar; the window's own 36 px bar carries the screen
name, and we add two right-aligned strings into its empty half -- the headroom
readout and the build stamp. Those are text with no background, so if they grow
they do not overlap a panel, they overlap the TITLE, and the result is the
doubled-text mess this whole change existed to remove.

The framework's face is approximated as FreeSansBold at QVGAbaseSkin's
TITLE_FONT_SIZE (18). That is an approximation and is stated as one: it is the
skin's declared size, but the skin could pick a different face. The margin
checked is generous enough that being a face out does not flip the verdict.
]]
print("=== our title-bar strings clear the framework's title ===")
do
	local TITLE_FONT_SIZE = 18
	local skinTitle = Font:load("fonts/FreeSansBold.ttf", TITLE_FONT_SIZE)
	if skinTitle and F.fontS and F.fontXS then
		local widest = 0
		for _, name in ipairs({ "Equalizer", "Tone" }) do
			local w = skinTitle:width(name)
			if w > widest then widest = w end
		end
		-- ours: "NO HEADROOM" is the longest readout, plus the stamp
		local readout = F.fontS.font:width("NO HEADROOM")
		local stamp   = F.fontXS.font:width("b999")
		local need    = widest + PAD + readout + 8 + stamp + PAD
		ok("title + readout + stamp fit one bar", need <= SCREEN_W,
		   string.format("%d title + %d readout + %d stamp = %d of %d px",
		                 widest, readout, stamp, need, SCREEN_W))
	else
		ok("fonts for the title-bar check loaded", false, "could not load a face")
	end
end

--[[
THE CONTENT MUST NOT REACH EITHER FRAMEWORK BAR.

Replaces the old "does the hint fit our status strip" check, which measured a
strip we no longer draw. The real constraint now is the opposite one: our
drawing has to stay INSIDE the band between the framework's title bar and its
iconbar, because anything outside it lands on their chrome.

Both bounds are READ from the applet, and the graph's extent is computed the way
the applet computes it, so moving GRAPH_H or either skin constant is picked up
here instead of silently overlapping again.
]]
print("=== the content band clears both framework bars ===")
do
	local titleH, iconbarH, graphH
	local fh = io.open(APPLET, "r")
	for line in fh:lines() do
		titleH   = tonumber(line:match("^local SKIN_TITLE_H%s*=%s*(%d+)"))   or titleH
		iconbarH = tonumber(line:match("^local SKIN_ICONBAR_H%s*=%s*(%d+)")) or iconbarH
		graphH   = tonumber(line:match("^local GRAPH_H%s*=%s*(%d+)"))        or graphH
	end
	fh:close()

	ok("both skin bounds and GRAPH_H were found",
	   titleH and iconbarH and graphH,
	   string.format("title=%s iconbar=%s graph=%s",
	                 tostring(titleH), tostring(iconbarH), tostring(graphH)))

	if titleH and iconbarH and graphH then
		local SCREEN_H = 240
		local gy     = titleH + 2
		local top    = gy + graphH + CELL_GAP
		local bottom = SCREEN_H - iconbarH - 2
		local ch     = math.floor((bottom - top - CELL_GAP) / 2)

		ok("the graph starts below the title bar", gy >= titleH,
		   string.format("graph top y=%d, title bar ends y=%d", gy, titleH))
		ok("the cells end above the iconbar", bottom <= SCREEN_H - iconbarH,
		   string.format("cells end y=%d, iconbar starts y=%d",
		                 bottom, SCREEN_H - iconbarH))
		ok("the cells still have usable height", ch >= 30,
		   string.format("cell height %d px", ch))

		-- the value baseline is y + ch - 21 and the face is ~17 px tall
		if F.fontVal then
			local valBottom = (ch - 21) + F.fontVal.font:height()
			ok("the cell value fits its cell", valBottom <= ch,
			   string.format("value bottom at +%d of %d px", valBottom, ch))
		end
	end
end

--[[
THE TONE SCREEN'S SCALE LABELS MUST FIT THEIR ROW.

"-15" and "+15" sit below the fader bar, inside the row panel. Their baseline is
`ty + N` where `ty = y + 42`, and the panel ends at `y + ROW_H`. FreeSans 9
renders about 11 px tall, so the glyph bottoms land at 42 + N + height.

This shipped at N = 18: bottoms at y + 71 against a row ending at y + 70. The
labels ran past the panel edge -- not clipped, not warned about, just touching
the border with no margin, which is only visible if you go looking at that
corner. Constants are READ from the applet, never restated, so moving the row or
the baseline is picked up here rather than silently diverging.
]]
print("=== the Tone screen's scale labels fit inside their row ===")
do
	local rowH, trackOff, labelOff
	local fh = io.open(APPLET, "r")
	if fh then
		for line in fh:lines() do
			rowH     = tonumber(line:match("^local ROW_H%s*=%s*(%d+)"))            or rowH
			trackOff = tonumber(line:match("^%s*local ty = y %+ (%d+)"))           or trackOff
			labelOff = tonumber(line:match('"%-15", TRK_X, ty %+ (%d+)%)'))        or labelOff
		end
		fh:close()
	end

	ok("ROW_H, the track offset and the label baseline were all found",
	   rowH and trackOff and labelOff,
	   string.format("ROW_H=%s ty=y+%s baseline=ty+%s",
	                 tostring(rowH), tostring(trackOff), tostring(labelOff)))

	if rowH and trackOff and labelOff and F.fontXS then
		local bottom = trackOff + labelOff + F.fontXS.font:height()
		local MARGIN = 1
		ok("scale labels leave a margin inside the row", bottom + MARGIN <= rowH,
		   string.format("bottom at y+%d, row ends y+%d", bottom, rowH))
	end
end

--[[
THE LEVEL MATCHING SCREEN MUST NOT SCROLL.

The user's constraint was "make sure it all fits on one screen (no scrolling
required)", which is measurable, so it is measured rather than eyeballed.

Everything here is the SKIN'S own number, read from QVGAbaseSkin rather than
restated, and the description is the SHIPPED string read out of strings.txt --
so lengthening the copy, changing the face, or the skin changing its row height
all redden this instead of quietly producing a screen that scrolls.
]]
print("=== the Level Matching screen fits one screen ===")
do
	local SKIN = "/usr/share/jive/applets/QVGAbaseSkin/QVGAbaseSkinApplet.lua"
	local STRINGS = "/usr/share/jive/applets/SBRadioEQ/strings.txt"

	-- skin metrics
	local itemH, helpSize, padTop, padBot, padL, padR
	local sfh = io.open(SKIN, "r")
	if sfh then
		for line in sfh:lines() do
			itemH    = tonumber(line:match("LANDSCAPE_LINE_ITEM_HEIGHT%s*=%s*(%d+)")) or itemH
			helpSize = tonumber(line:match("HELP_TEXT_FONT_SIZE%s*=%s*(%d+)"))        or helpSize
			local a, b, c2, d2 = line:match("^%s*HELP_TEXT_PADDING%s*=%s*{%s*(%d+),%s*(%d+),%s*(%d+),%s*(%d+)")
			if a then padL, padTop, padR, padBot = tonumber(a), tonumber(b), tonumber(c2), tonumber(d2) end
		end
		sfh:close()
	end

	-- the shipped description
	local desc
	local tfh = io.open(STRINGS, "r")
	if tfh then
		local armed = false
		for line in tfh:lines() do
			if line:match("^SBRADIOEQ_LEVEL_MATCH_DESC") then armed = true
			elseif armed then
				local v = line:match("^\tEN\t(.+)$")
				if v then desc = v; armed = false end
			end
		end
		tfh:close()
	end

	ok("skin metrics and the shipped string were all found",
	   itemH and helpSize and padTop and padBot and padL and padR and desc,
	   string.format("item=%s help=%s pad=%s/%s/%s/%s desc=%s chars",
	                 tostring(itemH), tostring(helpSize), tostring(padL),
	                 tostring(padTop), tostring(padR), tostring(padBot),
	                 desc and #desc or "nil"))

	if itemH and helpSize and desc and padTop then
		local BAND   = 240 - 36 - 24            -- content between the two framework bars
		local avail  = BAND - itemH - padTop - padBot
		local lineH  = helpSize + 4             -- the skin's own lineHeight rule
		local maxLn  = math.floor(avail / lineH)
		local wrapW  = (320 - 20) - padL - padR -- help_text w = screenWidth - 20

		local f = Font:load("fonts/FreeSans.ttf", helpSize)
		local lines, cur = 0, ""
		for word in string.gmatch(desc, "%S+") do
			local try = (cur == "") and word or (cur .. " " .. word)
			if f:width(try) <= wrapW then cur = try
			else lines = lines + 1; cur = word end
		end
		if cur ~= "" then lines = lines + 1 end

		ok("the description fits without scrolling", lines <= maxLn,
		   string.format("%d line(s) of %d (%d px for text, %d px lines, wrap %d px)",
		                 lines, maxLn, avail, lineH, wrapW))
	end
end

--[[
NEGATIVE CONTROL. Generated, so it cannot go missing when /tmp is cleared -- that
already silently disarmed test_globals once. An oversized cell value is the
mistake this half of the gate exists to catch: the cells lost a pixel to the
graph's clearance, so the value face is the thing with the least room left.
]]
print("=== the gate FIRES on a font size that would clip ===")
do
	local FIX = "/tmp/fixture_bigfont.lua"
	local fh = io.open(FIX, "w")
	if fh then
		fh:write('\tself.fontS     = Font:load("fonts/FreeSans.ttf", 12)\n')
		fh:write('\tself.fontXS    = Font:load("fonts/FreeSans.ttf", 9)\n')
		fh:write('\tself.fontVal   = Font:load("fonts/FreeSansBold.ttf", 28)\n')
		fh:close()
	end
	--[[
	VERTICALLY, not horizontally. The first version of this control measured
	WIDTH and did not fire: FreeSansBold 28 renders "16000" in 80 px against 96
	available, so it fits fine across. Height is the axis that got tight -- the
	cells gave up a pixel to the graph's clearance -- and height is what the
	real check above measures. The assert below is what caught the mismatch
	rather than letting a comfortable pass through.
	]]
	local G = fontsFrom(FIX)
	local caught = false
	if G and G.fontVal then
		local CELL_H  = 36                       -- as computed by the layout above
		local h       = G.fontVal.font:height()
		local bottom  = (CELL_H - 21) + h
		caught = bottom > CELL_H
		ok("an oversized cell value is caught", caught,
		   string.format("FreeSansBold28 is %d px tall, bottom at +%d of %d",
		                 h, bottom, CELL_H))
	else
		ok("fixture readable", false, "could not write or parse the fixture")
	end

	-- A gate that cannot fail is not a gate; abort rather than report a
	-- comfortable pass if the detector has stopped detecting.
	assert(caught, "negative control did not fire: this test can no longer fail")
end

--[[
NEGATIVE CONTROL for the Level Matching fit: a description long enough to
scroll. Without this the fit check would pass just as happily on a screen with
no description at all.
]]
print("=== the fit gate FIRES on a description that would scroll ===")
do
	local BAND, ITEM, HELP = 240 - 36 - 24, 45, 16
	local avail  = BAND - ITEM - 10 - 8
	local maxLn  = math.floor(avail / (HELP + 4))
	local wrapW  = (320 - 20) - 10 - 5
	local f = Font:load("fonts/FreeSans.ttf", HELP)
	local long = "Turning bass or treble up makes everything else quieter. " ..
	             "Level Matching raises the volume to compensate, so only the tone " ..
	             "changes and not the loudness. Switch it off if you would rather " ..
	             "the volume stayed exactly where you put it and did not move on " ..
	             "its own when you adjust the tone controls at all."
	local lines, cur = 0, ""
	for word in string.gmatch(long, "%S+") do
		local try = (cur == "") and word or (cur .. " " .. word)
		if f:width(try) <= wrapW then cur = try else lines = lines + 1; cur = word end
	end
	if cur ~= "" then lines = lines + 1 end

	local caught = lines > maxLn
	ok("an over-long description is caught", caught,
	   string.format("%d line(s) of %d allowed", lines, maxLn))
	assert(caught, "fit gate did not fire on a description that overflows")
end

--[[
NEGATIVE CONTROL for the row check: the baseline this actually shipped at.
Recomputed here rather than trusted, because the whole point is that ty + 18 was
plausible enough to ship.
]]
print("=== the row gate FIRES on the baseline that shipped ===")
do
	local ROW_H_REAL, TRACK_OFF = 70, 42
	local BAD = 18
	local bottom = TRACK_OFF + BAD + (F.fontXS and F.fontXS.font:height() or 11)
	local caught = (bottom + 1) > ROW_H_REAL
	ok("ty + 18 is caught as overflowing", caught,
	   string.format("bottom at y+%d, row ends y+%d", bottom, ROW_H_REAL))
	assert(caught, "row gate did not fire on the known-bad baseline")
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
