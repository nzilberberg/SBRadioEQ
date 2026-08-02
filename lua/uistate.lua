--[[
SBRadioEQ -- uistate.lua

Pure UI decisions, kept out of the draw code so they can be tested.

The graph markers used to turn white when their band's cell was highlighted. The
native-skin port rewrote _redraw and silently dropped it -- the rule lived inside
a filledCircle argument, so nothing referenced it, nothing tested it, and losing
it broke no check. It came back only because the user noticed on the device.

Anything in this file is a rule about WHAT the screen should say, expressed
without reference to how it is painted: no colours, no coordinates, no jive
imports. That makes it requireable from the test bench, which cannot load the
applet (module(...) plus the whole UI stack).

The applet maps these states to colours; the tests assert the states.
]]

local M = {}

--[[
What a band's marker on the graph should look like.

  "selected"  the highlight is on one of THIS band's cells, whether the user is
              merely on it or actively editing it. Drawn white: it tells you
              which dot you are about to move, which is the question you have
              when your hand is on the knob.
  "active"    the band is doing something (gain is not zero) but the highlight
              is elsewhere. Drawn in the curve colour.
  "idle"      gain is zero, so the dot marks a band that is not affecting the
              sound. Drawn dim.

selBand is the band owning the currently highlighted cell (1 = bass,
2 = treble). Editing state deliberately does NOT appear here: a band is
"selected" in both modes, because the cell belongs to it either way.
]]
function M.markerState(selBand, band, gainDb)
	if selBand == band then return "selected" end
	if gainDb ~= 0 then return "active" end
	return "idle"
end

--[[
Moving the highlight: ONE cell per scroll event, never more.

A fast twist was skipping options. The handler applied the event's scroll value
directly -- `cell = (cell - 1 + delta) % 6 + 1` -- and a quick turn delivers a
delta bigger than 1, so the highlight jumped over cells you could never land on.

Clamping the STEP rather than debouncing on time is the right shape here. A
time debounce drops input, which reads as an unresponsive control -- the same
complaint that killed the apply-debounce earlier in this project. Clamping keeps
every event, it just makes each one worth exactly one cell. With six options
there is nothing acceleration could usefully buy.

This applies to SELECTION only. Editing a value keeps the raw delta, because
sweeping a frequency from 40 Hz to 16 kHz one step per event would be unusable.
]]
function M.selectStep(delta)
	if delta > 0 then return 1 end
	if delta < 0 then return -1 end
	return 0
end

-- Next highlighted cell, wrapping. count is the number of cells.
function M.nextCell(cell, delta, count)
	return ((cell - 1 + M.selectStep(delta)) % count) + 1
end

return M
