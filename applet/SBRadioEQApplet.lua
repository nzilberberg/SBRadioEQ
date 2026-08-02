--[[
SBRadioEQ -- two-band parametric EQ on the Radio's AIC3104 hardware effects filter.

Controls (on-device; arrows are remote-only so nothing depends on them):
  knob turn    SELECT: move the highlight    EDIT: change the value
  knob press   enter / leave EDIT
  knob hold    bypass on/off
  BACK         EDIT: cancel    SELECT: save and exit

DRAWING RULES THIS FILE LEARNED THE HARD WAY
  1. Surface:drawText(font, colour, str) is a CLASS call that ALLOCATES a new
     surface. Calling it as srf:drawText(...) puts the surface in the font slot.
  2. Every allocated surface must be :release()'d after blitting. Twelve leaked
     surfaces per frame froze the device and tripped the watchdog.
  3. The response curve is computed ONLY when the design changes, into a table of
     dB values. draw() just maps that table to pixels and draws lines -- no
     soft-float trig per frame.
]]

-- module(...) REPLACES the global environment: every global used after it must be
-- captured here. Omitting pcall/require once shipped a menu item that registered
-- and then threw the moment it was opened. Gated by test/test_globals.lua.
local ipairs, pairs, tostring, type, math, string, pcall, require =
      ipairs, pairs, tostring, type, math, string, pcall, require

local oo         = require("loop.simple")
local Applet     = require("jive.Applet")
local Window     = require("jive.ui.Window")
local Canvas     = require("jive.ui.Canvas")
local Surface    = require("jive.ui.Surface")
local Framework  = require("jive.ui.Framework")
local Font       = require("jive.ui.Font")
local Player     = require("jive.slim.Player")
local Timer      = require("jive.ui.Timer")

local log        = require("jive.utils.log").logger("applet.SBRadioEQ")

local D          = require("applets.SBRadioEQ.eqdesign")
local A          = require("applets.SBRadioEQ.eqapply")
local U          = require("applets.SBRadioEQ.uistate")

local EVENT_SCROLL    = jive.ui.EVENT_SCROLL
local EVENT_KEY_PRESS = jive.ui.EVENT_KEY_PRESS
local EVENT_KEY_HOLD  = jive.ui.EVENT_KEY_HOLD
local EVENT_CONSUME   = jive.ui.EVENT_CONSUME
local EVENT_UNUSED    = jive.ui.EVENT_UNUSED
local KEY_GO          = jive.ui.KEY_GO
local KEY_BACK        = jive.ui.KEY_BACK

-- Drawing layers. A window transition draws each layer in its own pass, at its
-- own offset, so a widget has to know which pass it is in. See the note on
-- self.canvas.draw in settingsShow.
local LAYER_CONTENT   = jive.ui.LAYER_CONTENT

local appletManager = appletManager

module(..., Framework.constants)
oo.class(_M, Applet)

local FS = 44100

--[[
NATIVE SKIN. The screen is the stock Radio one with the EQ laid over it, rather
than a black panel that happens to live on the device.

The wallpaper is NOT drawn here. Framework:setBackground puts it beneath every
window on the device, which is why every other screen shows it without painting
it. We only draw the EQ over the top, translucent, so the wallpaper reads
through -- the alpha byte is the whole point of these colour constants.

⛔ We used to blit our own copy of bb_encore.png every frame, believing the
Canvas needed clearing. It does not, and the copy cost a 320x240 blit per frame
for nothing.

That was NOT, however, what broke the slide transitions -- removing it made
sliding OUT work and I wrongly reported it as the cause. The real fault was
Canvas ignoring the draw layer; see the note on self.canvas.draw in
settingsShow. Both changes were needed, and only the second one explains it.
]]
--[[
BUILD STAMP, shown in the corner of the status bar.

"Is the thing on screen the thing I just deployed?" came up after a change that
WAS correctly installed -- md5 matched, the process had restarted -- but the
screen had simply never been reopened, so it was still showing the old render.
Answering that took reading a device log.

A visible build number makes it a glance instead of an investigation, for both
of us. tools/deploy.sh bumps it, so it cannot be forgotten: the number that
reaches the device is the number the deploy printed.
]]
local BUILD = 17

local C_BAR       = 0x000000C4     -- title / status strips
local C_BAR_EDGE  = 0xFFFFFF26
local C_PANEL     = 0x00000075     -- graph box
local C_PANEL_EDGE= 0xFFFFFF2B
local C_GRID      = 0xFFFFFF1F
local C_AXIS      = 0xFFFFFF4D
local C_CURVE     = 0x3FD0C9FF     -- the skin's own teal
local C_TEXT      = 0xFFFFFFD1
local C_HILITE    = 0xFFFFFFFF
local C_LABEL     = 0xFFFFFF8C
local C_DIM       = 0xFFFFFF9C     -- deliberately secondary: the mode word only
--[[
The status hint had been C_DIM at FreeSans 9 and was barely readable on glass.
Alpha 0x9C is 61%, sitting on a bar that is itself translucent -- so the text was
losing contrast twice over. Contrast was the bigger problem, not size.

Fully opaque, and bigger than it sounds like it needs to be. FreeSans 10 was
tried first and still read as tiny on glass -- 9 to 10 is only 10 px to 12 px of
rendered height, a change you have to be told about to notice. 13 renders 14 px
tall and 224 px wide against 308 available, which is a 40% increase over where
this started.
]]
local C_HINT      = 0xFFFFFFFF
local C_WARN      = 0xFFD166FF
local C_MARK_OFF  = 0xFFFFFF40
local C_CELL      = 0x0000005E
local C_CELL_EDGE = 0xFFFFFF1C
local C_OFF       = 0xFFFFFF59
local C_EDIT_INK  = 0x001F1EFF     -- text on the teal editing cell

-- Selection bar and editing bar are GRADIENTS in the skin. SDL_gfx has no
-- gradient primitive, so they are drawn as horizontal bands; 8 is enough to read
-- as smooth at this size and costs 8 filledRectangle calls.
local GRAD_BANDS  = 8
local SEL_TOP,  SEL_BOT  = 0x3D3D3D, 0x0B0B0B
local EDIT_TOP, EDIT_BOT = 0x3FD0C9, 0x2A8F8B

-- Layout, in the 320x240 the device actually has.
local TITLE_H  = 28
-- 24, not 20: the hint is 14 px tall at FreeSans 13, and a 20 px strip left it
-- 2 px from the screen edge. The cells give up 1 px per row to pay for it.
local STATUS_H = 24
local PAD      = 6
local GRAPH_H  = 104
local CELL_GAP = 3

local F_LO, F_HI = 40, 16000
local DB_RANGE   = 16
local NPTS       = 80          -- curve resolution; plenty at 300 px wide

-- Each cell carries its own label: the old layout put "BASS"/"TREB" in a margin
-- and "Hz/dB/Q" in a header row, which does not survive a cell being highlighted
-- on its own. Labelling in the cell means the selected cell is self-describing.
local CELLS = {
	{ band = 1, key = "bassFreq", lab = "BASS Hz" },
	{ band = 1, key = "bassGain", lab = "BASS dB" },
	{ band = 1, key = "bassQ",    lab = "BASS Q"  },
	{ band = 2, key = "trebFreq", lab = "TREB Hz" },
	{ band = 2, key = "trebGain", lab = "TREB dB" },
	{ band = 2, key = "trebQ",    lab = "TREB Q"  },
}

---------------------------------------------------------------- design/apply

--[[
Both bands are designed TOGETHER, so the pair is normalised once rather than each
section paying its own way, and designPair() protects the intermediate signal
between the two biquads.

⛔ This used to claim "bass +15 with treble +15 needs 14.9 dB of make-up, not 30".
MEASURED FALSE (diag_ceiling2 / diag_reference): it needs 26.83 dB. Joint
normalisation cannot deliver the 14.9 dB figure, because the COEFFICIENT FORMAT
independently caps each section near unity gain -- so both sections end up
realising their boost as cut, and the midrange, which is "elsewhere" for both,
loses roughly the sum. 14.9 dB is what the response maths alone would allow if
the sections could hold arbitrary gain. They cannot.
]]
function _design(self)
	local s = self:getSettings()
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = s.bassFreq, gainDb = s.bassGain, shape = s.bassQ },
		{ kind = "highshelf", f0 = s.trebFreq, gainDb = s.trebGain, shape = s.trebQ })
	self.c1, self.c2 = c1, c2
	self.ideal1, self.ideal2 = i.ideal1, i.ideal2
	self.attenDb = i.attenDb or 0
	self:_check(i.diag)
	self:_recomputeCurve()
end

--[[
BLACK BOX for the next shriek.

A full-scale high-pitched burst happened at volume 100 and could not be explained
afterwards: by the time the coefficients were read they had been adjusted past,
so there was no record of what the chip was actually holding. A defect capable of
causing it was found later by sweeping the design space -- a treble shelf whose
realised response sat 9.7 dB above full scale, invisible to the normalisation --
but NOTHING connects that measurement to the event. It remains an assumption.

So record the dangerous quantities at the moment they are produced:

  peak    realised output level. Above 0 dB the output clips; clipping a 19 kHz
          resonance is exactly what a shriek sounds like.
  r       pole radius. Near 1 the section rings; ring-down is -1/(fs*ln r) per
          e-fold, so r = 0.999 rings for about 23 ms and r = 0.9999 for 227 ms.
  flat    the non-finite safety net fired, meaning a coefficient came out NaN or
          out of range and the band was replaced with unity.

Silent in normal use -- this writes nothing unless a threshold is crossed, which
keeps syslog off the knob path. When it does fire it records the full settings and
the player volume, which is everything needed to reproduce it.
]]
local PEAK_WARN_DB = 0.5      -- above unity: the output clips
local R_WARN       = 0.995    -- ~90 ms of ring-down
local RING_F_MIN   = 2000     -- ...but only counts as a warning up here

--[[
A near-unity pole is NORMAL for a low shelf -- a 100 Hz bass shelf measures
r = 0.998 and always will. Warning on radius alone would fire on ordinary bass
settings, and an alarm that cries wolf is one that gets ignored, which is the
same as not having built it. Only a near-unity pole ABOVE RING_F_MIN is the
signature being watched for.
]]
local function ringing(r, f)
	return r and f and r > R_WARN and f > RING_F_MIN
end

function _check(self, d)
	if not d then return end
	local bad = d.flat1 or d.flat2
	             or (d.peak1 and d.peak1 > PEAK_WARN_DB)
	             or (d.peak2 and d.peak2 > PEAK_WARN_DB)
	             or ringing(d.r1, d.pf1) or ringing(d.r2, d.pf2)
	if not bad then return end

	local s = self:getSettings()
	local player = Player:getLocalPlayer()
	log:warn("SBEQ-ANOMALY",
	         " bassF=", s.bassFreq, " bassG=", s.bassGain, " bassQ=", s.bassQ,
	         " trebF=", s.trebFreq, " trebG=", s.trebGain, " trebQ=", s.trebQ,
	         " | peak1=", d.peak1, " peak2=", d.peak2,
	         " r1=", d.r1, " pf1=", tostring(d.pf1),
	         " r2=", d.r2, " pf2=", tostring(d.pf2),
	         " flat1=", tostring(d.flat1), " flat2=", tostring(d.flat2),
	         " | atten=", self.attenDb,
	         " vol=", tostring(player and player:getVolume()),
	         " build=", BUILD)
end

-- Curve in dB at NPTS log-spaced frequencies, from the QUANTISED coefficients so
-- the graph shows what the chip really does. Recomputed only when the design
-- changes -- never inside draw().
function _recomputeCurve(self)
	if not self.freqs then
		self.freqs = {}
		local l0, l1 = math.log(F_LO), math.log(F_HI)
		for i = 0, NPTS do
			self.freqs[i + 1] = math.exp(l0 + (l1 - l0) * i / NPTS)
		end
	end
	--[[
	self.ideal1/ideal2 are the REALISED sections -- designPair returns float
	views of the exact integers written to the codec -- so this curve is what the
	chip does, by construction (test_graphtruth.lua is the specification). An
	earlier version drew the unquantised design instead; that kept the picture
	smooth while the sound diverged from it by a measured 7.33 dB at 40 Hz
	(bass 100 Hz / +15 dB / S 2.0). Fit-quantisation in eqdesign.lua now keeps
	the realised curve within ~1.1 dB of the request even at the worst corner,
	and whatever gap remains is real and belongs on screen.

	Then ADD THE MAKE-UP BACK before plotting. Each section is peak-normalised so
	its maximum sits at 0 dB -- necessary, because the chip cannot express gain
	above unity -- but plotting that directly draws every boost as a cut, pinning
	the whole curve under the axis and squashing it flat when both bands are
	boosted. Offsetting by attenDb puts unity back on the centre line: boosts read
	above it, cuts below, and the corner figure still reports the true level
	change. Purely a display transform -- the coefficients written to the codec
	are untouched.
	]]
	local p, q = self.ideal1, self.ideal2
	local offset = self.attenDb or 0
	local function at(f)
		local d = offset
		if p then d = d + D.responseDb(p.b0, p.b1, p.b2, p.a1, p.a2, f, FS) end
		if q then d = d + D.responseDb(q.b0, q.b1, q.b2, q.a1, q.a2, f, FS) end
		return d
	end
	local c = {}
	for i = 1, NPTS + 1 do
		c[i] = at(self.freqs[i])
	end
	self.curve = c

	-- Marker heights, computed HERE from the same response as the curve. Drawing
	-- them at the 0 dB axis instead was the "control points float free of the
	-- curve" bug -- the dots must sit ON the line they describe.
	local s = self:getSettings()
	self.markDb = { at(s.bassFreq), at(s.trebFreq) }
end

--[[
LEVEL MATCHING.

The chip cannot express gain above 0 dB (Q15 numerator), so a "+12 dB bass" is
realised as 0 dB bass and -12 dB everywhere else. Without make-up that reads as
"turning up the bass makes it quieter", which is what it did.

The make-up cannot come from the codec: PCM/Line DAC volume are already pinned at
127 = 0 dB and only go DOWN. The one stage that can go up is SqueezePlay's
software volume -- the player volume itself -- so that is what we move.

Only the DELTA is applied, and the ACHIEVED delta is what gets recorded: volume
steps are 1.48 dB apart below setting 25, so asking for +3.0 and getting +2.96
would otherwise drift a little further out of true on every single adjustment.
appliedAtten persists in settings, so a boot that re-applies the same curve
computes a zero delta and leaves the volume alone instead of jumping it.
]]
--[[
TARGET IS PASSED IN, NOT READ FROM self.attenDb.

self.attenDb is the make-up the CURVE needs. Whether it should be applied right
now is a different question -- while bypassed the answer is zero -- and
_applyNow used to express that by overwriting self.attenDb with 0.

That broke un-bypassing. Toggling bypass calls _applyNow directly, never
_design, so nothing recomputed the value: bypass zeroed it and dropping the
filter correctly lowered the volume, but un-bypassing then read the same zero,
computed a delta of zero, and left the volume down. The curve came back and the
level did not.

So the curve's make-up is now written in exactly one place (_design) and the
momentary target is a parameter. Nothing else may overwrite it.
]]
function _levelMatch(self, target)
	local s = self:getSettings()
	target        = target or self.attenDb or 0
	local applied = s.appliedAtten or 0
	local delta   = target - applied

	local player = Player:getLocalPlayer()
	local cur = player and player:getVolume() or nil

	-- Instrumentation removed 2026-08-01: it was a log:warn per knob click, and
	-- syslog I/O belongs on the knob path no more than a process spawn does.
	-- It did its job -- the level-matching fault it was chasing is recorded in
	-- the project notes.
	delta = U.levelDelta(target, applied)
	if not delta then return end
	if not player or not cur then return end

	local fromDb = D.volumeToDb(cur)
	local newVol = D.dbToVolume(fromDb + delta)
	if newVol == cur then return end
	player:volume(newVol, true)

	-- Record what was ACHIEVED, not what was asked for.
	s.appliedAtten = U.levelAchieved(applied, fromDb, D.volumeToDb(newVol))
end

function _applyNow(self)
	local s = self:getSettings()
	local bypass = (not s.enabled) or (s.bassGain == 0 and s.trebGain == 0)

	-- While bypassed the filter applies no cut, so no make-up is owed. This is a
	-- MOMENTARY target, not a change to the curve's own figure -- overwriting
	-- self.attenDb here is what stopped un-bypass restoring the volume.
	local target = bypass and 0 or (self.attenDb or 0)
	--[[
	⛔ NOTHING ADVANCES UNTIL THE HARDWARE CONFIRMS.

	This used to apply, then unconditionally advance the cache and call
	_levelMatch(). _levelMatch RAISES THE PLAYER VOLUME to compensate for
	attenuation the filter is supposed to be applying -- up to 27 dB at full
	two-band boost. If the write silently failed there was no attenuation to
	compensate for, so the volume went up over unattenuated audio.

	The shell path made that reachable: it discarded os.execute's status and
	returned the command string, which is always truthy. A failed write was
	indistinguishable from a good one.

	So: apply, and only on a confirmed ok do we advance the cache and touch the
	volume. On failure the cache is CLEARED, not left stale -- the next attempt
	must write the full set rather than diff against coefficients that may not be
	in the chip.
	]]
	local res
	if self.bsp then
		res = A.applyBSPMuted(self.bsp, self.c1, self.c2, self.written, bypass, self.writtenBypass)
	else
		res = A.apply(self.c1, self.c2, bypass)
	end

	if res and res.ok then
		self.written = { c1 = self.c1, c2 = self.c2 }
		self.writtenBypass = bypass
		self.hwError = nil
		self:_levelMatch(target)
		return
	end

	-- Failure. Do NOT raise the volume, and do not claim to know the chip's state.
	self.written = nil
	self.writtenBypass = nil
	self.hwError = (res and res.error) or "hardware write failed"
	log:warn("SBEQ-HWFAIL ", self.hwError,
	         " unknownState=", tostring(res and res.hardwareStateUnknown),
	         " stillMuted=", tostring(res and res.stillMuted),
	         " build=", BUILD)
end

-- NO DEBOUNCE. A 260 ms delay was tried to reduce how often the bypass window is
-- heard, and it was the wrong trade: it stole the live feel of the control, making
-- the dial seem dead while being turned. Live feedback wins; the artifact gets
-- fixed at its source instead.
function _flushApply(self)
	self:_applyNow()
end

------------------------------------------------------------------- drawing

-- Allocate, blit, RELEASE. Never skip the release.
local function text(srf, font, colour, str, x, y)
	local t = Surface:drawText(font, colour, str)
	t:blit(srf, x, y)
	t:release()
end

-- Right-aligned, for the title bar readout whose width changes with its value.
-- Font:width was verified present on the device (diag_gfx): 92 px for
-- "NO HEADROOM" at FreeSans 12.
local function textRight(srf, font, colour, str, xRight, y)
	text(srf, font, colour, str, xRight - font:width(str), y)
end

--[[
A vertical gradient, as horizontal bands.

The stock selection bar is a gradient and SDL_gfx has no gradient primitive.
Interpolating each channel across GRAD_BANDS strips reads as smooth at 38 px
tall. Colours are passed as 0xRRGGBB with the alpha supplied separately, because
interpolating a packed RGBA would drag the alpha along with it.
]]
local function gradient(srf, x, y, w, h, top, bot, alpha)
	local tr, tg, tb = math.floor(top / 65536) % 256, math.floor(top / 256) % 256, top % 256
	local br, bg, bb = math.floor(bot / 65536) % 256, math.floor(bot / 256) % 256, bot % 256
	for i = 0, GRAD_BANDS - 1 do
		local f  = i / (GRAD_BANDS - 1)
		local r  = math.floor(tr + (br - tr) * f)
		local g  = math.floor(tg + (bg - tg) * f)
		local b  = math.floor(tb + (bb - tb) * f)
		local y0 = y + math.floor(h * i / GRAD_BANDS)
		local y1 = y + math.floor(h * (i + 1) / GRAD_BANDS)
		srf:filledRectangle(x, y0, x + w, y1,
		                    r * 16777216 + g * 65536 + b * 256 + alpha)
	end
end

local function xForFreq(f, x0, w)
	local l0, l1 = math.log(F_LO), math.log(F_HI)
	return x0 + w * (math.log(f) - l0) / (l1 - l0)
end

function _fmt(self, key)
	local v = self:getSettings()[key]
	if string.find(key, "Freq") then
		if v >= 1000 then return string.format("%.1fk", v / 1000) end
		return string.format("%d", v)
	elseif string.find(key, "Gain") then
		return string.format("%+.1f", v)
	end
	return string.format("%.2f", v)
end

function _redraw(self, srf)
	local sw, sh = srf:getSize()
	local s  = self:getSettings()
	local on = s.enabled and not (s.bassGain == 0 and s.trebGain == 0)

	--[[
	⛔ DO NOT PAINT THE WALLPAPER HERE. The framework already does.

	This used to blit bb_encore.png full-screen every frame, on the belief that
	the Canvas needed clearing. It does not: Framework:setBackground (C side)
	draws the wallpaper beneath every window, every frame -- which is why every
	other screen on the device shows it without drawing it.

	Removing it also saves a 320x240 blit every frame.

	⛔ It did NOT fix the slide transitions, though it was reported that way at
	the time. Removing it made sliding OUT work, which looked like the answer;
	sliding IN was still broken, and the actual cause was Canvas ignoring the
	draw layer -- see the note on self.canvas.draw in settingsShow. Both changes
	were needed; only that one explains the fault.
	]]

	---------------------------------------------------------------- title bar
	srf:filledRectangle(0, 0, sw, TITLE_H, C_BAR)
	srf:hline(0, sw, TITLE_H, C_BAR_EDGE)

	text(srf, self.fontTitle, C_HILITE, "Equalizer", PAD, 6)
	local nameW = self.fontTitle:width("Equalizer")
	local mode  = (not on) and "bypassed" or (self.editing and "editing" or "select")
	text(srf, self.fontS, C_DIM, mode, PAD + nameW + 6, 8)

	--[[
	Report the make-up against what is left to pay it with, not on its own. "-27"
	means nothing by itself; "-27/32" says the boost is affordable and roughly how
	much further it can go. When a step has just been refused, say so plainly --
	otherwise a dead-feeling knob reads as the bug the last one actually was.
	]]
	if self.limited then
		textRight(srf, self.fontS, C_WARN, "NO HEADROOM", sw - PAD, 8)
	elseif not on then
		textRight(srf, self.fontS, C_DIM, "BYP", sw - PAD, 8)
	elseif self.attenDb and self.attenDb > 0.05 then
		textRight(srf, self.fontS, C_TEXT,
		          string.format("-%.0f/%.0f", self.attenDb, self:_headroomDb()),
		          sw - PAD, 8)
	end

	------------------------------------------------------------------- graph
	local gx, gy = PAD, TITLE_H + 2
	local gw, gh = sw - PAD * 2, GRAPH_H
	local midY   = gy + gh / 2

	srf:filledRectangle(gx, gy, gx + gw, gy + gh, C_PANEL)

	for _, f in ipairs({ 100, 1000, 10000 }) do
		local x = xForFreq(f, gx, gw)
		srf:vline(x, gy, gy + gh, C_GRID)
		text(srf, self.fontXS, C_OFF,
		     (f >= 1000) and ((f / 1000) .. "k") or tostring(f), x + 2, gy + gh - 12)
	end
	srf:hline(gx, gx + gw, midY, C_AXIS)

	-- curve: straight from the precomputed dB table
	local scale = (gh / 2) / DB_RANGE
	local px, py
	for i = 1, NPTS + 1 do
		local db = self.curve[i]
		if db >  DB_RANGE then db =  DB_RANGE end
		if db < -DB_RANGE then db = -DB_RANGE end
		local x = gx + (gw * (i - 1) / NPTS)
		local y = midY - db * scale
		if px then srf:line(px, py, x, y, on and C_CURVE or C_MARK_OFF) end
		px, py = x, y
	end

	--[[
	Marker colour says WHICH DOT THE KNOB IS ABOUT TO MOVE -- the question you
	have with a hand on the control. White whenever the highlight is on any of
	that band's three cells, selected or editing alike.

	The rule lives in uistate.markerState, not in this expression: it was written
	inline once, silently lost in the native-skin rewrite, and nothing caught it
	because a colour argument is not something a test can see.
	]]
	local MARKER_COLOUR = {
		selected = C_HILITE,
		active   = C_CURVE,
		idle     = C_MARK_OFF,
	}
	local selBand = CELLS[self.cell].band
	local function marker(f, db, band, gainDb)
		if db >  DB_RANGE then db =  DB_RANGE end
		if db < -DB_RANGE then db = -DB_RANGE end
		srf:filledCircle(xForFreq(f, gx, gw), midY - db * scale, 3,
		                 MARKER_COLOUR[U.markerState(selBand, band, gainDb)])
	end
	marker(s.bassFreq, self.markDb[1], 1, s.bassGain)
	marker(s.trebFreq, self.markDb[2], 2, s.trebGain)

	-- border last, so the curve cannot paint over it
	srf:rectangle(gx, gy, gx + gw, gy + gh, C_PANEL_EDGE)

	------------------------------------------------------------ parameter grid
	local top    = gy + gh + CELL_GAP
	local bottom = sh - STATUS_H - 2
	local cw     = math.floor((sw - PAD * 2 - CELL_GAP * 2) / 3)
	local ch     = math.floor((bottom - top - CELL_GAP) / 2)

	for i = 1, 6 do
		local r = (i <= 3) and 0 or 1
		local c = (i - 1) % 3
		local x = PAD + c * (cw + CELL_GAP)
		local y = top + r * (ch + CELL_GAP)

		if i == self.cell and self.editing then
			gradient(srf, x, y, cw, ch, EDIT_TOP, EDIT_BOT, 0xFF)
			srf:rectangle(x, y, x + cw, y + ch, 0xFFFFFFB0)
		elseif i == self.cell then
			gradient(srf, x, y, cw, ch, SEL_TOP, SEL_BOT, 0xEE)
			srf:rectangle(x, y, x + cw, y + ch, 0xFFFFFF5C)
		else
			srf:filledRectangle(x, y, x + cw, y + ch, C_CELL)
			srf:rectangle(x, y, x + cw, y + ch, C_CELL_EDGE)
		end

		local editing = (i == self.cell and self.editing)
		text(srf, self.fontXS, editing and 0x00302EFF or C_LABEL,
		     CELLS[i].lab, x + 4, y + 3)
		text(srf, self.fontVal, editing and C_EDIT_INK or C_HILITE,
		     self:_fmt(CELLS[i].key), x + 4, y + ch - 19)
	end

	--------------------------------------------------------------- status bar
	srf:filledRectangle(0, sh - STATUS_H, sw, sh, C_BAR)
	srf:hline(0, sw, sh - STATUS_H, C_BAR_EDGE)
	text(srf, self.fontHint, C_HINT,
	     self.editing and "turn: adjust   press: ok   back: cancel"
	                   or "turn: select   press: edit   hold: bypass",
	     PAD, sh - STATUS_H + 5)
	textRight(srf, self.fontXS, C_LABEL, "b" .. BUILD, sw - PAD, sh - STATUS_H + 8)
end

------------------------------------------------------------------- editing

function _nudge(self, delta)
	local s   = self:getSettings()
	local key = CELLS[self.cell].key
	local v   = U.stepValue(key, s[key], delta)

	--[[
	THE REAL CEILING: headroom, not the coefficient format.

	The chip cannot express gain above unity, so every boost is realised as a cut
	elsewhere and bought back with volume. The midrange is "elsewhere" for BOTH
	bands, so two boosts cut it by roughly their SUM -- measured 26.6 dB at
	bass +15 / treble +15 (diag_reference.lua). The make-up that restores it is
	exact to within 0.28 dB across the control surface, so the arithmetic is not
	the problem; the problem is that the make-up has to come from somewhere.

	It comes from volume, and volume runs out at 100. Past that point the curve is
	still designed and still written, but the level cannot be restored -- so the
	music just gets quieter, which is what the user reported as boosting a second
	band killing the volume.

	So refuse the step that cannot be paid for, and let the UI say why. Clamping
	the visible control is the honest form of this: a limit you can see beats a
	curve that is silently rewritten, and beats a level that silently sags.

	Only boosts are checked -- a cut never demands make-up, and must always remain
	available as the way OUT of a limited state.
	]]
	local before = s[key]
	s[key] = v
	if U.mustCheckAffordability(key, v, before) then
		local budget = self:_headroomDb()
		local _, _, i = D.designPair(FS,
			{ kind = "lowshelf",  f0 = s.bassFreq, gainDb = s.bassGain, shape = s.bassQ },
			{ kind = "highshelf", f0 = s.trebFreq, gainDb = s.trebGain, shape = s.trebQ })
		if not U.affordable(i.attenDb, budget) then
			s[key]       = before
			self.limited = true
			return
		end
	end
	self.limited = false
end

--[[
How much make-up the volume control can still give.

The current volume ALREADY contains appliedAtten dB of make-up, so the ceiling is
measured from the user's own base level: everything between here and volume 100,
plus whatever make-up is already in place.
]]
function _headroomDb(self)
	local s      = self:getSettings()
	local player = Player:getLocalPlayer()
	local cur    = player and player:getVolume()
	if not cur then return 96 end          -- no player: do not clamp on a guess
	return (s.appliedAtten or 0) - D.volumeToDb(cur)
end

------------------------------------------------------------------- window

function settingsShow(self, menuItem)
	local window = Window("text_list", menuItem and menuItem.text or "Equalizer",
	                      'settingstitle')

	self.cell    = 1
	self.editing = false
	self.fontS     = Font:load("fonts/FreeSans.ttf", 12)
	self.fontXS    = Font:load("fonts/FreeSans.ttf", 9)
	self.fontHint  = Font:load("fonts/FreeSans.ttf", 13)
	self.fontTitle = Font:load("fonts/FreeSansBold.ttf", 14)
	self.fontVal   = Font:load("fonts/FreeSansBold.ttf", 15)

	-- No wallpaper is loaded here any more: the framework draws the background
	-- beneath every window. See the note in _redraw -- our own copy of it was
	-- what broke the slide transitions.

	--[[
	FAIL CLOSED WITHOUT baby_bsp.

	The in-process BSP write is ~20 ms for a full apply. The amixer fallback is
	about 1.1 SECONDS, because every coefficient costs a process spawn -- and
	_applyNow runs on every knob detent, so the fallback would stall the UI and
	starve the audio decoder for roughly a second per click. It also cannot
	report failure usefully, which is how a failed write used to raise the
	volume.

	It was selected SILENTLY when the module was missing, so a firmware without
	it would present a control that looks fine and behaves terribly. Refuse
	instead, and say why: an EQ that says it cannot run here is better than one
	that appears to work and fights the audio thread.

	The shell path is kept for diagnostics and the boot-time re-apply, where a
	one-off second does not matter and nothing is being dragged interactively.
	]]
	local okbsp, bsp = pcall(require, "baby_bsp")
	self.bsp = okbsp and bsp or nil
	if not self.bsp then
		log:warn("SBRadioEQ: baby_bsp unavailable -- refusing to open the editor")
		local Textarea = require("jive.ui.Textarea")
		local w = Window("text_list", menuItem and menuItem.text or "Equalizer",
		                 'settingstitle')
		w:addWidget(Textarea("text",
			"Hardware EQ unavailable on this firmware.\n\n" ..
			"The in-process mixer module (baby_bsp) is missing, and the fallback " ..
			"is roughly a second per adjustment -- too slow to edit with, and it " ..
			"cannot confirm a write succeeded.\n\n" ..
			"Any EQ already saved is still applied at startup."))
		self:tieAndShowWindow(w)
		return w
	end

	--[[
	Prime the mute-restore level HERE, once, while the screen is opening --
	never on the knob path. It costs a 220 ms amixer process spawn (measured,
	diag_spawn.lua), which on this single 360 MHz core starves the audio
	decoder. Paid once on entry it is unnoticeable; it was previously paid on
	every knob click, and that was the popping.
	]]
	A.forgetMutePoint()
	A.mutePoint()

	self:_design()

	self.canvas = Canvas('debug_canvas', function(srf) self:_redraw(srf) end)

	--[[
	⛔ Canvas:draw DROPS THE LAYER ARGUMENT, so it paints in every pass.

	jive/ui/Canvas.lua is `function draw(self, surface) self.render(surface) end`
	-- it never looks at the layer the framework passes. Every other widget is
	drawn selectively.

	A transition renders one layer per pass, each at its own offset
	(Window.lua _transitionPushLeft):

	    offset 0             newWindow:draw(LAYER_LOWER)
	    offset -x            oldWindow:draw(LAYER_CONTENT | ... | LAYER_TITLE)
	    offset screenW - x   newWindow:draw(LAYER_CONTENT | ON_STAGE | TITLE)
	    offset 0             newWindow:draw(LAYER_FRAME)

	Painting in all four means the LAST pass wins, and it is at offset 0 -- so
	the incoming window appeared instantly at its final position while the old
	menu slid out from behind it. Exactly what was reported.

	Sliding OUT looked right only by luck: as the OLD window we are drawn once,
	in the offset pass, so there was nothing to overwrite it.

	Draw only in the content passes -- the ones the transition offsets. The layer
	is nil-checked so any caller that omits it still gets a paint rather than a
	blank screen.
	]]
	local applet = self
	self.canvas.draw = function(_, surface, layer)
		if layer and (layer & LAYER_CONTENT) == 0 then return end
		applet:_redraw(surface)
	end

	window:addWidget(self.canvas)

	--[[ INPUT OWNERSHIP ----------------------------------------------------
	The knob was dead until an unrelated volume press, then live for a second or
	two, then dead again. Cause: ScreenSaversApplet registers a GLOBAL listener
	on ACTION|EVENT_KEY_PRESS|EVENT_KEY_HOLD|EVENT_SCROLL (line 101) and eats
	input to wake from idle. The Radio idles within seconds, so almost every knob
	turn was being consumed before it reached this window. Declaring that this
	window owns the screen stops the idle handler taking our input.
	--]]
	window:setAllowScreensaver(false)

	-- canvas:reDraw() only marks the widget dirty; the draw loop does not
	-- reliably wake for it on its own. Force the frame.
	local function repaint(self)
		self.canvas:reDraw()
		Framework:reDraw(nil)
	end

	local function scrolled(event)
		local d = event:getScroll()

		--[[
		TEMPORARY, and only when it has something to say: how big a scroll value
		does a fast twist actually deliver? If the knob emits one event per
		detent, |d| is always 1 and clamping costs nothing. If it coalesces
		detents into one large event, clamping discards real motion and the
		control will feel sluggish -- in which case the remainder needs
		carrying rather than dropping.

		Logging only |d| > 1 keeps syslog off the input path in the normal case.
		]]
		if d > 1 or d < -1 then
			log:warn("SBEQ-SCROLL d=", d, " editing=", tostring(self.editing))
		end

		if self.editing then
			-- raw delta: acceleration is wanted when sweeping 40 Hz to 16 kHz
			self:_nudge(d)
			self:_design()
			self:_applyNow()
		else
			-- one cell per event, so a fast twist cannot jump over an option
			self.cell = U.nextCell(self.cell, d, #CELLS)
		end
		repaint(self)
		return EVENT_CONSUME
	end

	window:addListener(EVENT_SCROLL, scrolled)

	-- Measured on the device: KEY_GO == 1 and the knob press arrives as a raw
	-- EVENT_KEY_PRESS. addActionListener("go") was registered too and fired ZERO
	-- times, so the raw key path is the real one here.
	window:addListener(EVENT_KEY_PRESS, function(event)
		local k = event:getKeycode()
		if k == KEY_GO then
			if not self.editing then
				-- Entering EDIT. Snapshot first: edits apply live, so cancelling
				-- has to mean "put it back", and there is nothing to put back
				-- unless it was captured before the first click.
				self.snap = U.snapshot(self:getSettings())
				self.editing = true
			else
				-- Leaving EDIT by accepting.
				self.editing = false
				self.snap = nil
				self:_flushApply()
				self:storeSettings()
			end
			repaint(self)
			return EVENT_CONSUME

		elseif k == KEY_BACK and self.editing then
			--[[
			BACK CANCELS -- which it did not used to.

			It only cleared self.editing, and since every scroll had already
			written the new value into settings and pushed it to the codec, the
			changed value was then saved on window close. Back was documented as
			cancel and behaved as accept.

			Restoring the values is not enough on its own: the live edits also
			moved the player volume, so appliedAtten comes back with them and the
			curve is re-applied to put the hardware where the numbers say it is.
			]]
			local s = self:getSettings()

			--[[
			PUT THE VOLUME BACK TOO, not just the numbers.

			appliedAtten is bookkeeping ABOUT the player volume, not a copy of
			it. Live editing moves the real volume -- drop a +15 band to 0 and
			the volume comes down ~15 dB to match -- so restoring appliedAtten
			while leaving the volume down asserts 15 dB of make-up that is not
			there. Reported from the device: "the gain level comes back but
			without the volume match adjustment."

			Undo exactly what this edit applied, rather than snapping to a
			remembered volume, so a manual volume change made mid-edit survives.
			]]
			local player     = Player:getLocalPlayer()
			local cur        = player and player:getVolume()
			local appliedNow = s.appliedAtten or 0

			U.restoreSnapshot(s, self.snap)

			if player and cur then
				local wantDb = U.cancelVolumeDb(D.volumeToDb(cur), appliedNow,
				                                s.appliedAtten or 0)
				local newVol = D.dbToVolume(wantDb)
				if newVol ~= cur then player:volume(newVol, true) end
			end

			self.snap    = nil
			self.editing = false
			self:_design()
			self:_flushApply()
			self:storeSettings()
			repaint(self)
			return EVENT_CONSUME
		end
		return EVENT_UNUSED
	end)

	window:addListener(EVENT_KEY_HOLD, function(event)
		if event:getKeycode() == KEY_GO then
			local s = self:getSettings()
			s.enabled = not s.enabled
			self:_flushApply()
			self:storeSettings()
			repaint(self)
			return EVENT_CONSUME
		end
		return EVENT_UNUSED
	end)

	window:addListener(EVENT_WINDOW_POP, function()
		self:_flushApply()
		self:storeSettings()
	end)

	self:tieAndShowWindow(window)
	return window
end

--[[
The service is registered by the META, not here -- see SBRadioEQMeta.lua.

Registering it from init() could never have worked: applets load lazily, so this
does not run until something opens the screen, while the boot-time re-apply
happens long before that. It also passed `self` where an applet NAME was
expected, so even once loaded the service resolved to nothing.
]]
function init(self)
end

function sbRadioEQApply(self)
	local okbsp, bsp = pcall(require, "baby_bsp")
	self.bsp = okbsp and bsp or nil
	A.forgetMutePoint()
	A.mutePoint()
	self:_design()
	self:_applyNow()
end
