--[[
cd /tmp && jive diag_fonts

The status-bar hint is too small to read on the device. Before bumping it, two
things need measuring rather than estimating:

  * the RENDERED HEIGHT at each candidate size, so the text still fits inside
    the status strip instead of being clipped by the screen edge;
  * the RENDERED WIDTH of the longest hint, because the screen is 320 px and a
    bolder, larger string that overflows is not an improvement -- it is the same
    illegibility with extra steps.

Font:width and Font:height were confirmed present in diag_gfx.
]]

local Font = require("jive.ui.Font")

local SCREEN_W = 320
local PAD      = 6
local AVAIL    = SCREEN_W - PAD * 2

local HINTS = {
	"turn: select   press: edit   hold: bypass",
	"turn: adjust   press: ok   back: cancel",
}

print(string.format("Usable width: %d px (320 minus %d padding each side)", AVAIL, PAD))
print("")
print("  face              size   height   widest hint   fits?")

for _, face in ipairs({ "FreeSans", "FreeSansBold" }) do
	for _, sz in ipairs({ 9, 10, 11, 12, 13, 14 }) do
		local f = Font:load("fonts/" .. face .. ".ttf", sz)
		local h = f:height()
		local widest, which = 0, nil
		for _, s in ipairs(HINTS) do
			local w = f:width(s)
			if w > widest then widest, which = w, s end
		end
		print(string.format("  %-16s %4d   %6d   %11d   %s",
			face, sz, h, widest, widest <= AVAIL and "yes" or "NO -- CLIPS"))
	end
end

--[[
Also check the other small text on the screen, so the fix is not applied to the
one string that was complained about while its neighbours stay unreadable.
]]
print("")
print("Other text currently drawn at FreeSans 9:")
local xs = Font:load("fonts/FreeSans.ttf", 9)
for _, s in ipairs({ "BASS Hz", "TREB dB", "BASS Q", "100", "1k", "10k" }) do
	print(string.format("  %-10s %3d px wide, %d tall", s, xs:width(s), xs:height()))
end

print("")
print("Cell width available for a label:")
local CELL_GAP = 3
local cw = math.floor((SCREEN_W - PAD * 2 - CELL_GAP * 2) / 3)
print(string.format("  cell is %d px; label is drawn at x+4, so %d px usable", cw, cw - 8))
for _, face in ipairs({ "FreeSans", "FreeSansBold" }) do
	for _, sz in ipairs({ 9, 10, 11 }) do
		local f = Font:load("fonts/" .. face .. ".ttf", sz)
		local w = f:width("BASS Hz")
		print(string.format("  %-14s %2d : 'BASS Hz' = %3d px  %s",
			face, sz, w, w <= cw - 8 and "fits" or "CLIPS"))
	end
end
