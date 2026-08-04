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
local SimpleMenu = require("jive.ui.SimpleMenu")
local Checkbox   = require("jive.ui.Checkbox")
local Textarea   = require("jive.ui.Textarea")
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
local BUILD = 48

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
THE STATUS HINT IS GONE, and with it C_HINT and fontHint.

It said "turn: select   press: edit   hold: bypass", which is how every screen
on this device already works -- and it was printed across the framework's own
battery and wifi icons, because we were drawing a bar exactly on top of theirs.
Bypass has a real menu item now, so even that half stopped earning its line.

The sizing lesson it taught is worth keeping for any small text here: FreeSans 9
at 61% alpha, on a translucent bar, lost contrast TWICE and read as unusable on
glass. Contrast was the bigger problem, not size -- and going 9 to 10 is only
10 px to 12 px of rendered height, a change you have to be told about to notice.
Anything meant to be read at arm's length wants to be opaque first, then bigger
than it sounds like it needs to be.
]]
local C_WARN      = 0xFFD166FF
local C_MARK_OFF  = 0xFFFFFF40
local C_CELL      = 0x0000005E
local C_CELL_EDGE = 0xFFFFFF1C
-- The UNSELECTED fader row. Lighter than C_PANEL (0x75) on purpose: an
-- unselected row is background, and at 0x75 it read as a second solid slab
-- competing with the selected one. At 0x45 the wallpaper carries it and the
-- selection is what the eye lands on.
local C_ROW_OFF   = 0x00000045
local C_OFF       = 0xFFFFFF59
local C_EDIT_INK  = 0x001F1EFF     -- text on the teal editing cell

-- Selection bar and editing bar are GRADIENTS in the skin. SDL_gfx has no
-- gradient primitive, so they are drawn as horizontal bands; 8 is enough to read
-- as smooth at this size and costs 8 filledRectangle calls.
local GRAD_BANDS  = 8
local SEL_TOP,  SEL_BOT  = 0x3D3D3D, 0x0B0B0B
local EDIT_TOP, EDIT_BOT = 0x3FD0C9, 0x2A8F8B

--[[
Layout, in the 320x240 the device actually has.

⛔ WE DRAW NEITHER A TITLE BAR NOR A STATUS BAR. The window already has both,
and painting our own translucent copies over them is what produced a doubled
title -- our 28 px bar and its text sitting on the framework's 36 px bar and
ITS text -- and a hint line printed across the battery and wifi icons.

These two numbers are MEASURED, on the device, off a stock screen (Settings >
Brightness > Manual Brightness) by scanning the framebuffer for the bar edges,
rather than assumed:

    rows   0..35   framework title bar   (separator on row 35)
    rows  36..215  content -- ours
    rows 216..239  framework iconbar     (clock, battery, wifi)

36 agrees with QVGAbaseSkin's TITLE_HEIGHT, which is the cross-check; the
iconbar has no constant in the skin, so the measurement is the only source.

We draw ONLY into the content band, plus two small right-aligned strings in the
title bar's empty half (the headroom readout and the build stamp) -- text with
no background, so the framework's bar shows through and stays single.
]]
local SKIN_TITLE_H   = 36
local SKIN_ICONBAR_H = 24
local PAD      = 6
-- 98, was 104. The graph used to start at 30 and ran under the framework's
-- 36 px title bar. Six pixels back buys the clearance; the option cells give up
-- one more each, which the tightened label-to-value gap inside them pays back.
local GRAPH_H  = 98
local CELL_GAP = 3

local F_LO, F_HI = 40, 16000
--[[
VERTICAL RANGE. Half-span in dB, so the plot covers -DB_RANGE..+DB_RANGE.

18. Sized so MAXED-OUT CONTROLS FILL THE PLOT, which is the point of drawing one.

MEASURED: with both bands at +15 dB and Q 2.0, the drawn peak is 15.55..17.57 dB
across EVERY frequency pair. 18 puts that at 98% of the upper half, so the hump
reaches the top at maximum settings.

⛔ TWO EARLIER VALUES WERE WRONG, IN OPPOSITE DIRECTIONS, and both were argued
for confidently:

  36 came from sizing against attenDb (34.76), WHICH THE GRAPH NEVER PLOTS. The
     two sections are peak-normalised independently at different frequencies, so
     the top of the curve is attenDb minus the other band's floor.

  24 came from the global sweep maximum of 22.32 dB. That value is real, but it
     occurs at bass 800 Hz with treble 1000 Hz and treble Q 0.2 -- the two
     shelves OVERLAPPING into one broad boost. Sizing for that corner left a
     third of the plot unreachable at every ordinary setting.

So 18 accepts that the overlapping-shelf corner clips, by up to 4.33 dB. That is
a deliberate trade, confirmed with the user: a curve that fills the graph where
people actually work, against a flat top at a setting that makes the bass and
treble controls into the same filter.

COUNTERINTUITIVE, worth stating because it was assumed backwards twice: the peak
RISES AS Q FALLS. At bass 100 / treble 3k, +15 both, it runs 14.10 dB at Q 0.2
up to 17.57 at Q 2.0 -- a WIDE shelf overlapping the other band is what makes
the 22.32 extreme, not a sharp one.

At 16 the curve CLIPPED at ordinary settings too: the drawing code pins anything
beyond the range to the frame, so it went flat-topped and stopped showing shape.

⛔ THE PLOTTED PEAK IS NOT attenDb. That mistake set this constant to 36 and
wasted half the plot. _recomputeCurve draws

    d(f) = attenDb + response(realised1, f) + response(realised2, f)

and the two sections are peak-normalised INDEPENDENTLY, at DIFFERENT
frequencies. Where bass sits at its maximum, treble sits at its floor, so the
top of the curve is attenDb minus that floor -- never attenDb itself.

MEASURED over 729 combinations of the whole control range: the highest point
ever drawn is +22.32 dB and the lowest -22.33 dB. At bass 100/+15/Q2.0 with
treble 3000/+15/Q2.0 the make-up is 34.76 dB while the CURVE spans only
-1.85..+17.57 -- which at DB_RANGE 36 filled just half the upper half and
left the rest of the plot unreachable by any setting.

24 covers +/-22.33 with 1.67 dB spare, at 2.04 px/dB.

Gated by test/test_graphrange.lua, which sweeps the control range and fails if
any reachable setting would clip.
]]
local DB_RANGE   = 18
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
	self.realised1, self.realised2 = i.realised1, i.realised2
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
	self.realised1/realised2 are the REALISED sections -- designPair returns float
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
	local p, q = self.realised1, self.realised2
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

	--[[
	⛔ LEVEL MATCHING OFF MEANS TARGET ZERO -- NOT "return early".

	Returning here would leave whatever make-up is already folded into the
	volume sitting there with nothing compensating for it: turn the feature off
	after a +15 boost and the music stays 15 dB loud over a curve whose cut the
	user has just stopped paying for. Same shape as the bypass bug.

	Forcing the target to 0 instead runs the SAME delta/deadband/achieved
	machinery in reverse, so switching off UNWINDS the existing make-up and none
	is ever added while it stays off. The move is always downward, which is the
	safe direction to be wrong in.
	]]
	if not s.levelMatch then target = 0 end

	local applied = s.appliedAtten or 0
	local delta   = target - applied

	local player = Player:getLocalPlayer()
	local cur = player and player:getVolume() or nil

	-- Instrumentation removed 2026-08-01: it was a log:warn per knob click, and
	-- syslog I/O belongs on the knob path no more than a process spawn does.
	-- It did its job -- the level-matching fault it was chasing is recorded in
	-- the project notes.
	--[[
	⛔ EVERY EXIT REPORTS. THIS FUNCTION USED TO HAVE THREE BARE `return`s.

	A caller could not tell "the volume is now where it should be" from "there is
	no local player, so nothing moved at all". That distinction is the whole
	safety question on a DOWNWARD move: if the make-up could not be taken out, the
	output must not be unmuted, because unmuting plays the old make-up over an
	attenuation that has already gone.

	Two of the three exits are genuine successes -- a delta inside the deadband and
	a delta that quantises to the same volume setting both mean "already correct".
	Only a missing player or volume is a failure. They were indistinguishable
	before because all three returned nothing.
	]]
	delta = U.levelDelta(target, applied)
	if not delta then
		return { ok = true, noop = true, reason = "within deadband",
		         appliedAtten = applied }
	end
	if not player or not cur then
		return { ok = false, error = "no local player or volume",
		         requestedDelta = delta, appliedAtten = applied }
	end

	local fromDb = D.volumeToDb(cur)
	local newVol = D.dbToVolume(fromDb + delta)
	if newVol == cur then
		return { ok = true, noop = true, reason = "quantises to the same volume",
		         requestedDelta = delta, appliedAtten = applied }
	end
	player:volume(newVol, true)

	-- Record what was ACHIEVED, not what was asked for.
	s.appliedAtten = U.levelAchieved(applied, fromDb, D.volumeToDb(newVol))
	return { ok = true, requestedDelta = delta,
	         achievedDelta = D.volumeToDb(newVol) - fromDb,
	         appliedAtten = s.appliedAtten }
end

function _applyNow(self, allowShell)
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
	attenuation the filter is supposed to be applying -- up to 34 dB at full
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
	--[[
	⛔ THE VOLUME MOVE HAPPENS INSIDE THE MUTE, VIA THIS CALLBACK.

	It used to happen after applyBSPMuted returned -- i.e. after the output had
	already been unmuted -- so every DOWNWARD transition briefly played
	unattenuated audio at the old, compensated volume. Reset Tone, bypassing,
	reducing a boost and cancelling an edit all take that path, not just failures.

	The callback answers one question: may the output be unmuted? A downward move
	that did not actually happen must answer NO.
	]]
	local levelRes = nil
	local function reconcile(hw)
		local t
		if hw.ok then
			t = target                    -- the curve went in; pay for it
		else
			t = 0                         -- confirmed bypassed; owe nothing
		end
		local appliedBefore = (self:getSettings().appliedAtten or 0)
		local downward      = t < appliedBefore

		levelRes = self:_levelMatch(t)

		-- Upward or unchanged: unmuting is safe whatever happened, because the
		-- error can only be that the output is too QUIET.
		if not downward then return true end
		return (levelRes and levelRes.ok) and true or false
	end

	--[[
	⛔ THE SHELL PATH IS BOOT-ONLY. IT HAS NO MUTE BRACKET.

	A.apply bypasses the filter as its first amixer command and takes about a
	second to run. There is no PCM mute around it, because the mute lives in the
	BSP path -- so if make-up gain is currently folded into the player volume, that
	whole second plays UNATTENUATED audio at the compensated level. Up to 34.41 dB
	of it. That is the same loud state the ordering fix exists to prevent, just
	reached through the fallback instead.

	Every interactive route already refuses to open without baby_bsp (both editors
	and the Tone menu that carries the checkboxes and Reset), so in practice only
	the boot service reaches this. `allowShell` makes that explicit rather than
	incidental: a future caller that loses the baby_bsp guard fails closed with a
	message instead of quietly taking the loud path.

	Boot is the one place it is the right trade: nothing is playing yet, and a
	silent failure to restore the curve would be worse than a slow write.
	]]
	local res
	if self.bsp then
		res = A.applyBSPMuted(self.bsp, self.c1, self.c2, self.written, bypass,
		                      self.writtenBypass, reconcile)
	elseif allowShell then
		res = A.apply(self.c1, self.c2, bypass)
	else
		res = { ok = false, error = "no baby_bsp; refusing the unmuted shell path",
		        hardwareStateUnknown = false, refused = true }
	end

	if res and res.ok then
		self.written = { c1 = self.c1, c2 = self.c2 }
		self.writtenBypass = bypass
		self.hwError = nil
		self.hwMuted = false
		-- Only when the muted path did not already do it: the no-op early returns
		-- and the shell fallback never take the callback. Calling twice would
		-- compute a second delta against an appliedAtten the first call moved.
		--[[
		⛔ A VOLUME-ONLY CHANGE CAN FAIL WHILE THE HARDWARE SUCCEEDS.

		applyBSPMuted returns a no-op success when the coefficients and bypass
		state already match what is in the chip, and in that case it never runs the
		reconcile callback -- so the volume move happens here instead. Its result
		used to be DISCARDED, and the hardware's success returned as the whole
		operation's success.

		The reachable case is the Level Matching checkbox: no coefficient changes
		at all, but switching it demands a volume move. With no local player that
		move fails, and the setting was stored as applied. Switching it OFF is part
		of returning the Radio to an uncompensated state, which makes a false
		success there exactly the wrong lie.

		audioSafe and ok are different questions. Failing to RAISE the volume
		leaves the output quieter than asked -- disappointing, not dangerous.
		Failing to LOWER it leaves old make-up standing over less attenuation,
		which is the loud state.
		]]
		if not res.reconciled then
			local before = s.appliedAtten or 0
			local lr     = self:_levelMatch(target)
			res.levelResult  = lr
			res.fullyApplied = (lr == nil) or (lr.ok and true or false)
			if lr and not lr.ok then
				res.ok        = false
				res.audioSafe = (target >= before)
				res.error     = lr.error
				self.hwError  = lr.error
				log:warn("SBEQ-LEVELFAIL err=", tostring(lr.error),
				         " target=", tostring(target), " before=", tostring(before),
				         " audioSafe=", tostring(res.audioSafe), " build=", BUILD)
			end
		end
		return res
	end

	-- Failure. Do NOT raise the volume, and do not claim to know the chip's state.
	self.written = nil
	self.writtenBypass = nil
	self.hwError = (res and res.error) or "hardware write failed"
	self.hwMuted = (res and res.stillMuted) or false

	--[[
	⛔ REFUSING TO RAISE THE VOLUME IS ONLY HALF OF IT. UNWIND WHAT IS ALREADY IN.

	Not calling _levelMatch on failure stops NEW make-up going in, and that was
	correct as far as it went. But the make-up from the PREVIOUS curve is already
	folded into the player volume, and the failure path has very likely just
	dropped the filter -- applyBSPDiff bypasses before it writes, and the recovery
	bypasses again. So the attenuation is gone while its compensation, up to about
	34 dB of it, is still there. That is the loud-audio bug this project already
	shipped once, arriving by a different road.

	The worst instance is Reset Tone: it flattens the curve, and if the write
	fails it would store flat settings, log success, and leave the volume high
	over a flat curve -- while being the very action documented as the safe thing
	to do before uninstalling.

	CONDITION: only when the bypass was CONFIRMED. Unwinding means lowering the
	volume by the make-up, which is right when the cut is definitely gone and
	merely quiet when it is not -- but "merely quiet" is still the wrong answer to
	give confidently, and where the state is unknown applyBSPMuted has kept the
	output muted anyway. So: confirmed-bypassed unwinds; unknown stays silent and
	says so.
	]]
	if res and res.safeBypassed and not res.reconciled then
		levelRes = self:_levelMatch(0)
	end

	--[[
	⛔ `unwound=` USED TO BE LOGGED FROM safeBypassed, WHICH IS A DIFFERENT FACT.
	It said the unwind had happened whenever the BYPASS was confirmed, even when
	_levelMatch had silently done nothing -- no local player, no volume reading.
	It now reports what _levelMatch actually returned, and its reason.
	]]
	local unwound = (levelRes and levelRes.ok) and true or false
	self.hwUnwound = unwound

	log:warn("SBEQ-HWFAIL ", self.hwError,
	         " unknownState=", tostring(res and res.hardwareStateUnknown),
	         " safeBypassed=", tostring(res and res.safeBypassed),
	         " stillMuted=", tostring(res and res.stillMuted),
	         " reconciled=", tostring(res and res.reconciled),
	         " unwound=", tostring(unwound),
	         " why=", tostring(levelRes and (levelRes.error or levelRes.reason or "moved")),
	         " build=", BUILD)
	return res or { ok = false, error = self.hwError }
end

-- NO DEBOUNCE. A 260 ms delay was tried to reduce how often the bypass window is
-- heard, and it was the wrong trade: it stole the live feel of the control, making
-- the dial seem dead while being turned. Live feedback wins; the artifact gets
-- fixed at its source instead.
function _flushApply(self, allowShell)
	return self:_applyNow(allowShell)
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

	------------------------------------------- readout, in the framework's bar
	-- No bar and no title of our own: the window already draws "Equalizer" in
	-- the skin's own style, and ours underneath it was the doubled text. Only
	-- the right-hand strings are ours, drawn with NO background so the
	-- framework's bar shows through unbroken.
	--
	-- The mode word ("select"/"editing") is gone with the hint line: turning to
	-- select and pressing to edit is how every screen on this device works and
	-- does not need saying.
	local stamp = "b" .. BUILD
	textRight(srf, self.fontXS, C_DIM, stamp, sw - PAD, 12)
	local readoutRight = sw - PAD - self.fontXS:width(stamp) - 8

	--[[
	Report the make-up against what is left to pay it with, not on its own. "-27"
	means nothing by itself; "-27/32" says the boost is affordable and roughly how
	much further it can go. When a step has just been refused, say so plainly --
	otherwise a dead-feeling knob reads as the bug the last one actually was.
	]]
	-- A hardware failure outranks the make-up readout: see the note in
	-- _redrawTone. The graph below still draws the REQUESTED curve, so without
	-- this the screen actively asserts a filter that is not running.
	if self.hwError then
		textRight(srf, self.fontS, C_WARN,
		          self.hwMuted and "MUTED" or "EQ FAILED", readoutRight, 11)
	elseif self.limited then
		textRight(srf, self.fontS, C_WARN, "NO HEADROOM", readoutRight, 11)
	elseif not on then
		textRight(srf, self.fontS, C_DIM, "BYP", readoutRight, 11)
	elseif s.levelMatch and self.attenDb and self.attenDb > 0.05 then
		-- "-14/82" is make-up spent over make-up available. With level matching
		-- off neither number is real: nothing is being spent and there is no
		-- budget, so showing it would be a readout about a mechanism that is
		-- switched off.
		textRight(srf, self.fontS, C_TEXT,
		          string.format("-%.0f/%.0f", self.attenDb, self:_headroomDb()),
		          readoutRight, 11)
	end

	------------------------------------------------------------------- graph
	-- SKIN_TITLE_H, not our own: the graph used to start at TITLE_H + 2 = 30 and
	-- ran six pixels underneath the framework's 36 px bar.
	local gx, gy = PAD, SKIN_TITLE_H + 2
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
	-- The framework's iconbar owns the last 24 rows. Stopping at our own
	-- STATUS_H happened to be the same number, which is why the collision was
	-- invisible: we were drawing a bar exactly on top of theirs.
	local bottom = sh - SKIN_ICONBAR_H - 2
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
		     CELLS[i].lab, x + 2, y + 2)
		-- ch - 21, was ch - 19. The cells lost a pixel of height to the graph's
		-- clearance and the label-to-value gap had two spare, so tightening it
		-- pays that back rather than squeezing the value against the border.
		text(srf, self.fontVal, editing and C_EDIT_INK or C_HILITE,
		     self:_fmt(CELLS[i].key), x + 2, y + ch - 21)
	end

	-- NO STATUS BAR. The framework's iconbar (clock, battery, wifi) lives in the
	-- last 24 rows and is what should be visible there. The hint line that used
	-- to be here printed straight across the battery icon, and said nothing that
	-- needed saying: turn to select and press to edit is how the whole device
	-- works, and bypass now has a real menu item.
end

------------------------------------------------------------------- editing

-- _nudge edits the cell the EQ screen has selected; _nudgeKey edits a NAMED
-- setting, which is what the Tone screen needs -- it has no cell grid, just bass
-- and treble gain.
--
-- Deliberately one implementation. The affordability rule below is the whole
-- reason a boost can be refused, and a second copy of it on the Tone screen
-- would be a copy that drifts: the two screens edit the SAME bassGain and
-- trebGain, so they must refuse the same steps for the same reasons.
function _nudge(self, delta)
	return self:_nudgeKey(CELLS[self.cell].key, delta)
end

function _nudgeKey(self, key, delta)
	local s   = self:getSettings()
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
	--[[
	The affordability clamp exists ONLY because make-up comes out of the volume
	control, and volume runs out at full scale. With level matching off nothing
	is being paid for, so there is nothing to run out of -- refusing a boost
	then would be a limit with no cause behind it, and it would trap the user at
	a setting for a reason that no longer applies.
	]]
	if s.levelMatch and U.mustCheckAffordability(key, v, before) then
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

------------------------------------------------------------- tone faders

--[[
THE TONE SCREEN -- "easy mode" for the same two numbers the EQ screen edits.

It edits bassGain and trebGain DIRECTLY, in the same settings table, through the
same _nudgeKey / _design / _applyNow path. It is not a second filter and not a
second set of values: frequency and Q are left exactly as they are, so whatever
the EQ screen was showing still holds when you come back to it.

That is the whole point of the screen. Someone who wants "more bass" gets one
fader and a number, and never has to meet a shelf frequency or a Q. Someone who
does can open the Equalizer and find their change already there.

WHY A CUSTOM WIDGET. The Radio's stock Slider is a pill that fills from the
left, which is right for brightness -- 0 is the floor and more is further along.
Gain is signed: 0 is the MIDDLE, and -15 is as far from flat as +15. A
left-filling bar at -15 dB would be drawn empty, and empty reads as "off"
rather than "cut". So the track is centre-zero with a needle, drawn here.

The +15 end of the fader is a CONTROL range, not a promise. The chip cannot
express gain above 0 dB, so a boost is realised as cut-elsewhere plus make-up
volume, and the make-up runs out -- see _nudgeKey. Because this screen goes
through the same clamp, a step that cannot be paid for is refused here exactly
as it is on the EQ screen, and self.limited says so on screen.
]]

local TONE_ROWS = {
	{ key = "bassGain", lab = "BASS"   },
	{ key = "trebGain", lab = "TREBLE" },
}

-- Geometry, in the 320x240 the device actually has. Centre-zero: the track runs
-- TRK_X..TRK_X+TRK_W and 0 dB sits exactly at its midpoint.
local TRK_X, TRK_W = 20, 280
local TRK_MID      = TRK_X + TRK_W / 2
local ROW_H        = 70
local ROW1_Y       = 42
local ROW_GAP      = 14
local GAIN_MAX     = 15

local function toneRowY(i)
	return ROW1_Y + (i - 1) * (ROW_H + ROW_GAP)
end

-- dB -> pixel. Clamped, so a value outside the range cannot draw the needle
-- outside the track and quietly imply a position the control cannot reach.
local function xForGain(db)
	if db >  GAIN_MAX then db =  GAIN_MAX end
	if db < -GAIN_MAX then db = -GAIN_MAX end
	return TRK_MID + (db / GAIN_MAX) * (TRK_W / 2)
end

function _redrawTone(self, srf)
	local sw, sh = srf:getSize()
	local s = self:getSettings()

	-- ⛔ The wallpaper is NOT painted here. Framework:setBackground draws it
	-- beneath every window; painting our own copy is what broke the slide
	-- transitions on the EQ screen. See the note in _redraw.

	-- No title bar and no title of our own -- the window draws "Tone" already.
	-- Only these right-aligned strings are ours, and they carry no background so
	-- the framework's bar stays a single unbroken bar.
	local stamp = "b" .. BUILD
	textRight(srf, self.fontXS, C_DIM, stamp, sw - PAD, 12)
	local readoutRight = sw - PAD - self.fontXS:width(stamp) - 8

	-- Bypass takes the corner when it is on. It has to be VISIBLE, not implied:
	-- bypassed with a big boost still showing on the faders would otherwise look
	-- like the filter is simply not working.
	--[[
	⛔ A HARDWARE FAILURE OUTRANKS EVERY OTHER READOUT, so it is tested first.

	self.hwError was set and logged and read by NOTHING -- the user got silence or
	a wrong-sounding EQ and no indication at all, while the graph and the faders
	carried on showing the curve that had been REQUESTED. Those are three
	different things (desired, last applied, actual), and showing only the first
	while the third has failed is what made the failure invisible.
	]]
	if self.hwError then
		textRight(srf, self.fontS, C_WARN,
		          self.hwMuted and "MUTED" or "EQ FAILED", readoutRight, 11)
	elseif not s.enabled then
		textRight(srf, self.fontS, C_WARN, "BYPASS", readoutRight, 11)
	elseif self.limited then
		textRight(srf, self.fontS, C_WARN, "NO HEADROOM", readoutRight, 11)
	elseif s.levelMatch and self.attenDb and self.attenDb > 0.05 then
		-- same figure the EQ screen shows, same corner, and gated the same way:
		-- two screens editing one value must not disagree about what is
		-- affordable, nor about whether affordability applies at all
		textRight(srf, self.fontS, C_LABEL,
		          string.format("-%.0f/%.0f", self.attenDb, self:_headroomDb()),
		          readoutRight, 11)
	end

	for i, row in ipairs(TONE_ROWS) do
		local y        = toneRowY(i)
		local selected = (self.toneRow == i)
		local editing  = selected and self.toneEditing
		local db       = s[row.key] or 0

		-- The row panel itself does not change when editing.
		if selected then
			gradient(srf, 8, y, sw - 16, ROW_H, SEL_TOP, SEL_BOT, 0xEB)
			srf:rectangle(8, y, sw - 8, y + ROW_H, C_CURVE)
		else
			srf:filledRectangle(8, y, sw - 8, y + ROW_H, C_ROW_OFF)
			srf:rectangle(8, y, sw - 8, y + ROW_H, C_CELL_EDGE)
		end

		-- Editing recolours the TEXT itself to the skin's teal. No panel, no box
		-- behind it: the label and the value simply turn blue on the row's own
		-- dark background, which is already high contrast.
		local inkLab, inkVal
		if editing then
			inkLab, inkVal = C_CURVE, C_CURVE
		else
			inkLab = selected and C_TEXT or C_LABEL
			inkVal = selected and C_HILITE or C_TEXT
		end

		text(srf, self.fontS, inkLab, row.lab, TRK_X, y + 8)
		textRight(srf, self.fontVal, inkVal,
		          string.format("%+.1f dB", db), sw - TRK_X, y + 6)

		--[[
		EDIT STATE: THE FADER BAR ONLY.

		The bar fills with the skin's teal -- EDIT_TOP -> EDIT_BOT, the same
		constants the EQ screen's editing cell uses -- so the thing the knob is
		about to move is the thing that lights up.

		⛔ Whatever is drawn ON the bar must invert with it. The centre-out fill
		sits entirely inside the bar and is translucent teal normally; on a teal
		bar it would vanish completely. The needle and the centre detent CROSS
		the bar, dark panel above and below, so neither one colour works for the
		whole length -- the needle gets a light halo with a dark core, which
		reads on both.

		The 5 dB ticks and the end labels are BELOW the bar, on the panel, and
		are deliberately left light: they never touch the teal.
		]]
		local ty = y + 42
		local fillCol, axisCol, needleCol

		if editing then
			gradient(srf, TRK_X, ty, TRK_W, 8, EDIT_TOP, EDIT_BOT, 0xFF)
			srf:rectangle(TRK_X, ty, TRK_X + TRK_W, ty + 8, 0xFFFFFFB0)
			fillCol   = 0x00201FA8
			axisCol   = 0x00201FE0
			needleCol = C_EDIT_INK
		else
			srf:filledRectangle(TRK_X, ty, TRK_X + TRK_W, ty + 8, C_PANEL)
			srf:rectangle(TRK_X, ty, TRK_X + TRK_W, ty + 8, C_PANEL_EDGE)
			fillCol   = 0x3FD0C961
			axisCol   = C_AXIS
			needleCol = C_HILITE
		end

		-- Fill from the CENTRE to the needle, not from the left edge. At 0 dB it
		-- has zero width and vanishes, which is the honest picture of "flat".
		local nx = xForGain(db)
		if nx > TRK_MID then
			srf:filledRectangle(TRK_MID, ty, nx, ty + 8, fillCol)
		elseif nx < TRK_MID then
			srf:filledRectangle(nx, ty, TRK_MID, ty + 8, fillCol)
		end

		-- ticks every 5 dB, below the bar on the dark panel -- always light
		for v = -15, 15, 5 do
			local tx = xForGain(v)
			local h  = (v == 0) and 5 or 3
			srf:filledRectangle(tx, ty + 12, tx + 1, ty + 12 + h,
			                    (v == 0) and C_AXIS or C_GRID)
		end
		-- centre detent, inside the bar where it has to be found
		srf:filledRectangle(TRK_MID, ty, TRK_MID + 1, ty + 8, axisCol)

		-- The needle crosses the bar. A light halo with a dark core reads
		-- against the dark panel above and below AND against the teal between.
		if editing then
			srf:filledRectangle(nx - 2, ty - 6, nx + 3, ty + 14, C_HILITE)
			srf:filledRectangle(nx - 1, ty - 6, nx + 2, ty + 14, needleCol)
		else
			srf:filledRectangle(nx - 1, ty - 6, nx + 2, ty + 14, needleCol)
		end

		-- ty + 15, not + 18. FreeSans 9 renders ~11 px tall, so a baseline at
		-- ty + 18 put the glyph bottoms at y + 71 against a row that ends at
		-- y + 70 -- the scale labels were running past the panel edge with no
		-- margin at all. Gated by test/test_textfit.lua.
		text(srf, self.fontXS, C_LABEL, "-15", TRK_X, ty + 15)
		textRight(srf, self.fontXS, C_LABEL, "+15", TRK_X + TRK_W, ty + 15)
	end

	-- NO STATUS BAR: the framework's iconbar belongs in the last 24 rows, and
	-- the hint line that used to cover it was redundant navigation instruction.
end

------------------------------------------------------------------- window

--[[
THE TONE MENU -- the screen in front of the EQ.

⛔ THIS COMMENT USED TO SAY Level Match and Reset Tone were inert placeholders
with no callback, and that Level Match's checkbox was "still a literal". All
three statements were false by the time anyone read them -- both rows have been
live since 2026-08-03, and a checkbox whose initial state is a hardcoded literal
while its callback is wired is the exact lie check-bypass-single-source.sh exists
to catch. A stale comment describing a safer, simpler system than the one that
ships is how a later change reintroduces the old assumption.

All five rows are live: Tone Control (the bypass tick box), Tone, Equalizer,
Level Matching and Reset Tone. Both tick boxes read their initial state from
settings.enabled / settings.levelMatch -- the single sources -- and both write
through the same apply transaction, reporting failure via _reportApply because a
stock menu row has no canvas of its own to show it on.

Built from the stock widgets the device's own settings screens use --
SimpleMenu + Checkbox with style 'item_choice' -- rather than the Canvas the EQ
screen needs. The EQ draws a response curve, which is why it owns its pixels; a
list of five rows does not, and hand-drawing one would diverge from the skin the
moment anything about it changed.
]]
function menuShow(self, menuItem)
	local window = Window("text_list", menuItem and menuItem.text or "Tone Controls",
	                      'settingstitle')
	local menu   = SimpleMenu("menu")

	-- The toggle below writes coefficients, so the mixer and a designed pair
	-- have to exist first. NOT fail-closed here, unlike the two editors: this
	-- menu is still useful without baby_bsp (the Equalizer row does its own
	-- check on entry), and a one-off bypass toggle can afford the ~1 s shell
	-- fallback. A knob path cannot, which is why those screens refuse.
	local okbsp, bsp = pcall(require, "baby_bsp")
	self.bsp = okbsp and bsp or nil
	self:_design()

	--[[
	1. Tone Control -- THE bypass toggle.

	Reads and writes settings.enabled, which is the applet's ONLY bypass state.
	The EQ screen's hold-to-bypass and the Tone screen's toggle that same field,
	so the three cannot drift apart: there is one flag, not three copies to keep
	in step. _applyNow reads it directly.

	The box is constructed from the LIVE value every time the menu opens, so
	arriving here after a hold-to-bypass on either editor shows the truth rather
	than a remembered default.
	]]
	menu:addItem({
		text   = self:string("SBRADIOEQ_TONE_CONTROL"),
		style  = 'item_choice',
		weight = 1,
		check  = Checkbox("checkbox",
			function(_, isSelected)
				local s = self:getSettings()
				s.enabled = isSelected and true or false
				local res = self:_flushApply()
				self:storeSettings()
				self:_reportApply(res, "Tone Control")
			end,
			self:getSettings().enabled and true or false),
	})

	-- 2. Tone -- two centre-zero faders over the SAME bassGain/trebGain the
	-- Equalizer edits. Live.
	menu:addItem({
		text     = self:string("SBRADIOEQ_TONE"),
		sound    = "WINDOWSHOW",
		weight   = 2,
		callback = function(event, item) self:toneShow(item) end,
	})

	-- 3. Equalizer -- the one live row.
	menu:addItem({
		text     = self:string("SBRADIOEQ"),
		sound    = "WINDOWSHOW",
		weight   = 3,
		callback = function(event, item)
				   self:settingsShow(item)
			   end,
	})

	--[[
	NO LOUDNESS ROW, and this is a decision rather than an omission.

	Loudness would have to fold into the two shelves the user already controls,
	because the chip has exactly two biquads and both are spent. MEASURED: a
	naive gain fold is BIT-IDENTICAL to the user turning the bass knob up -- an
	assert in the comparison confirmed it, not an argument. Pulling the shelf
	corner toward 120 Hz is the only part they could not reproduce by hand, and
	that is worth at most 1.02 dB, in a narrow band around 150 Hz, against a
	chip whose own coefficient error is already ~1.13 dB.

	So the measurable difference between "loudness on" and "you turned the knob
	up" sits below our own error floor.

	What would change this is AUTOMATIC level tracking -- the one thing the
	knobs genuinely cannot do. That is blocked on the framework emitting no
	volume notification at all (checked: the complete notify_ list has nothing
	for volume), so it would mean polling plus coefficient rewrites during
	playback, which is the exact operation that produced this project's popping
	and its shriek.

	Reinstating it needs that problem solved first, not a better curve.
	]]

	-- 4. Level Matching -- its own screen, because the tick box needs a sentence
	-- of explanation before it means anything.
	menu:addItem({
		text     = self:string("SBRADIOEQ_LEVEL_MATCHING"),
		sound    = "WINDOWSHOW",
		weight   = 4,
		callback = function(event, item) self:levelMatchShow(item) end,
	})

	-- 6. Reset Tone -- confirm screen, then back to the installed defaults.
	menu:addItem({
		text     = self:string("SBRADIOEQ_RESET"),
		sound    = "WINDOWSHOW",
		weight   = 5,
		callback = function(event, item) self:resetShow(item) end,
	})

	window:addWidget(menu)
	self:tieAndShowWindow(window)
	return window
end


--[[
LEVEL MATCHING -- a description, then the tick box under it.

Built the way SetupAppletInstaller presents its warning: the explanatory text is
the MENU'S HEADER WIDGET (menu:setHeaderWidget), not a separate widget added to
the window. That matters -- a Textarea added alongside a SimpleMenu competes
with it for the window's space and the menu ends up scrolling under it. As a
header it is part of the menu's own layout.

⛔ IT MUST FIT ONE SCREEN. The content band between the framework's title bar and
its iconbar is 180 px. The tick box row is 45 px (the skin's
LANDSCAPE_LINE_ITEM_HEIGHT), leaving 135 px, and help_text costs 10 px of top
padding and 8 of bottom, so the text itself gets 117 px. At the skin's
lineHeight of 20 that is FIVE lines. The string wraps to four.

Those numbers are the skin's own, read from QVGAbaseSkin, and the wrap was
measured with the real face at the real width. Gated by test/test_textfit.lua,
which re-measures the shipped string rather than trusting this comment.

THE COPY IS LOAD-BEARING, so it is worth saying what it must not get wrong.
Level matching moves the volume in BOTH directions -- dropping a boost lowers it
again, and Reset lowers it by the whole make-up at once -- and it happens LIVE,
on every detent, not when the screen is saved. A first draft said "raises the
volume" and omitted the timing; both were wrong, and a description that is wrong
about which way the volume moves is worse than no description.

WIRED, to settings.levelMatch. That flag gates SIX places, and the reason to
list them is that missing one leaves a feature half-off rather than off:

  1. _levelMatch          the volume move itself -- forced to target 0 when off,
                          so switching off UNWINDS existing make-up
  2. _nudgeKey            the affordability clamp, which exists only because
                          make-up is paid for out of the volume control
  3. _redraw              the EQ screen's "-14/82" readout
  4. _redrawTone          the Tone screen's copy of the same readout
  5. settingsShow's Back  the cancel-restores-volume path
  6. toneShow's Back      the same path on the other screen

The default is ON. Off is a deliberate choice, not the starting point: without
matching, turning the bass up makes the music quieter, which is exactly what the
control looked broken doing before level matching existed.
]]
function levelMatchShow(self, menuItem)
	local window = Window("text_list", menuItem and menuItem.text or "Level Matching",
	                      'settingstitle')
	local menu   = SimpleMenu("menu")

	menu:setHeaderWidget(Textarea("help_text",
	                              self:string("SBRADIOEQ_LEVEL_MATCH_DESC")))

	--[[
	Toggling APPLIES IMMEDIATELY, and that is the point of routing it through
	_applyNow rather than just storing the flag.

	OFF: _levelMatch forces its target to 0, so the make-up already folded into
	     the volume is unwound on the spot -- the volume comes DOWN. Leaving it
	     for "next time something applies" would strand the user loud.
	ON:  the curve's make-up is applied, so the volume comes back UP to where
	     matching says it belongs. That is a raise, but it is the one the user
	     just asked for by ticking the box.
	]]
	menu:addItem({
		text  = self:string("SBRADIOEQ_LEVEL_MATCH"),
		style = 'item_choice',
		check = Checkbox("checkbox",
			function(_, isSelected)
				local s = self:getSettings()
				s.levelMatch = isSelected and true or false
				if not self.bsp then
					local okbsp, bsp = pcall(require, "baby_bsp")
					self.bsp = okbsp and bsp or nil
				end
				self:_design()
				local res = self:_applyNow()
				self:storeSettings()
				self:_reportApply(res, "Level Matching")
			end,
			self:getSettings().levelMatch ~= false),
	})

	window:addWidget(menu)
	self:tieAndShowWindow(window)
	return window
end

--[[
RESET -- back to the installed defaults, curve AND volume.

⛔ appliedAtten IS DELIBERATELY NOT RESET HERE, and getting this wrong is a
loud-audio bug, not a cosmetic one.

appliedAtten is bookkeeping about the PLAYER VOLUME: it records how much make-up
gain is currently folded into it. At the moment Reset runs, the volume is still
carrying the old boost's make-up.

⛔ THE FIGURE HERE USED TO SAY 15 dB AND THAT IS THE SINGLE-BAND NUMBER.
Measured on the device (diag_maxmakeup, defaults 150 Hz / 3 kHz): one band at
+15 needs 15.00 dB, BOTH bands at +15 need 30.00 dB at Q 1.0, and 34.41 dB at
Q 2.0. So this comment understated the worst case by more than half, and the
"27 dB" written elsewhere in this project understated it too -- 27 was never
measured, it was carried from one comment to the next.

Copy appliedAtten = 0 in with the rest and _levelMatch computes
delta = target(0) - applied(0) = 0, decides there is nothing to do, and leaves
the volume 15 dB up over a curve that is now FLAT. That is the same shape as the
bypass bug: the compensation outlives the thing it was compensating for.

Leaving it alone makes _levelMatch compute delta = 0 - 15 = -15 and take the
volume back DOWN, then record the achieved figure. The direction is always
quieter, which is the safe way to be wrong.
]]
function resetToDefaults(self)
	if not self.bsp then
		local okbsp, bsp = pcall(require, "baby_bsp")
		self.bsp = okbsp and bsp or nil
	end

	local s = self:getSettings()
	for k, v in pairs(U.defaults()) do
		if k ~= "appliedAtten" then s[k] = v end
	end

	self:_design()
	local res = self:_applyNow()      -- brings the volume back down; see above
	self:storeSettings()

	--[[
	⛔ DO NOT ANNOUNCE A RESET THAT DID NOT HAPPEN.

	This used to log SBEQ-RESET unconditionally, immediately after an _applyNow
	whose result it discarded, and the confirmation screen closed either way. So
	the one action documented as the safe thing to do before uninstalling could
	fail, save flat settings, report success, and return the user to the menu with
	the old make-up still in the player volume and nothing said.

	Storing the settings is still right -- they are the DESIRED state, and the
	next successful apply reconciles from them. What must not happen is claiming
	the reset succeeded.
	]]
	local ok = (res and res.ok) and true or false
	if ok then
		log:info("SBEQ-RESET to defaults, build=", BUILD)
	else
		log:warn("SBEQ-RESET FAILED err=", tostring(res and res.error),
		         " stillMuted=", tostring(res and res.stillMuted),
		         " unwound=", tostring(self.hwUnwound),
		         " appliedAtten=", tostring(self:getSettings().appliedAtten),
		         " build=", BUILD)
	end
	return res
end

--[[
What the user is told when a reset does not complete. Three different states,
because the remedy differs and "it failed" alone leaves them guessing:

  muted        the filter cannot be vouched for, so audio is off deliberately
  not unwound  the EQ is off but the make-up is still in the player volume --
               the LOUD one, and the one where saying nothing is worst
  otherwise    the write failed; the previous curve is still in the chip
]]
--[[
Report a failed apply from a context that has no canvas of its own.

The two editors paint EQ FAILED / MUTED in their status corner, so a failure
during an edit is visible where it happens. A CHECKBOX in Settings > Audio
Settings > Tone Controls has no canvas, and the window-close path has no screen
left at all -- so without this, those actions fail exactly the way Reset Tone
used to: the setting saves, the menu returns, and nothing says the hardware
refused it.

Returns true when the apply succeeded, so a caller can also decline to close.
]]
function _reportApply(self, res, title)
	if res and res.ok then return true end
	log:warn("SBEQ-APPLYFAIL from=", tostring(title),
	         " err=", tostring(res and res.error),
	         " stillMuted=", tostring(res and res.stillMuted),
	         " unwound=", tostring(self.hwUnwound), " build=", BUILD)
	local Textarea = require("jive.ui.Textarea")
	local w = Window("text_list", title or "Equalizer", 'settingstitle')
	w:addWidget(Textarea("text", self:_resetFailureText(res)))
	self:tieAndShowWindow(w)
	return false
end

function _resetFailureText(self, res)
	if res and res.stillMuted then
		return "The equaliser could not be set safely, so sound is muted.\n\n" ..
		       "Restart the Radio to restore audio."
	end
	if not self.hwUnwound then
		return "The equaliser was switched off, but the volume compensation " ..
		       "could not be removed.\n\nThe Radio may be louder than usual -- " ..
		       "turn the volume down before uninstalling."
	end
	return "The equaliser could not be reset.\n\nIts previous settings are " ..
	       "still active."
end

--[[
The confirm screen, modelled on the device's own SetupFactoryReset: a plain
text_list window whose whole body is a two-item SimpleMenu, Cancel first.

Cancel first is the model's ordering and it is the right one for a destructive
action -- the highlight lands on the harmless option, so a stray press does
nothing.
]]
function resetShow(self, menuItem)
	local window = Window("text_list", menuItem and menuItem.text or "Reset Tone",
	                      'settingstitle')

	local menu = SimpleMenu("menu", {
		{
			text     = self:string("SBRADIOEQ_RESET_CANCEL"),
			sound    = "WINDOWHIDE",
			callback = function() window:hide() end,
		},
		{
			text     = self:string("SBRADIOEQ_RESET_CONTINUE"),
			sound    = "WINDOWSHOW",
			callback = function()
				local res = self:resetToDefaults()
				if res and res.ok then
					window:hide()
					return
				end
				--[[
				⛔ DO NOT HIDE ON FAILURE. Hiding returns the user to the menu with
				no indication, which is exactly how the pre-uninstall action could
				report itself done while make-up gain was still in the volume.
				The screen is REPLACED by the explanation, so the failure cannot be
				missed by anyone who does not later open one of the editors.
				]]
				local Textarea = require("jive.ui.Textarea")
				local w = Window("text_list", "Reset Tone", 'settingstitle')
				w:addWidget(Textarea("text", self:_resetFailureText(res)))
				self:tieAndShowWindow(w)
			end,
		},
	})

	window:addWidget(menu)
	self:tieAndShowWindow(window)
	return window
end


function toneShow(self, menuItem)
	local window = Window("text_list", menuItem and menuItem.text or "Tone",
	                      'settingstitle')

	self.toneRow     = 1
	self.toneEditing = false
	self.fontS     = Font:load("fonts/FreeSans.ttf", 12)
	self.fontXS    = Font:load("fonts/FreeSans.ttf", 9)
	self.fontVal   = Font:load("fonts/FreeSansBold.ttf", 15)

	-- Fail closed exactly as the EQ screen does: this screen writes coefficients
	-- on every detent through the same path, so the amixer fallback would stall
	-- the UI for about a second per click here too.
	local okbsp, bsp = pcall(require, "baby_bsp")
	self.bsp = okbsp and bsp or nil
	if not self.bsp then
		log:warn("SBRadioEQ: baby_bsp unavailable -- refusing to open Tone")
		local Textarea = require("jive.ui.Textarea")
		local w = Window("text_list", menuItem and menuItem.text or "Tone",
		                 'settingstitle')
		w:addWidget(Textarea("text",
			"Tone controls unavailable on this firmware.\n\n" ..
			"The in-process mixer module (baby_bsp) is missing.\n\n" ..
			"Any tone setting already saved is still applied at startup."))
		self:tieAndShowWindow(w)
		return w
	end

	-- Prime the mute-restore level once, on entry -- never on the knob path.
	-- It costs a ~220 ms process spawn; paid per click it was the popping.
	A.forgetMutePoint()
	A.mutePoint()

	self:_design()

	self.canvas = Canvas('debug_canvas', function(srf) self:_redrawTone(srf) end)

	--[[
	⛔ Canvas:draw DROPS THE LAYER ARGUMENT, so it paints in every pass, and a
	window transition draws each layer at its own offset. Without this override
	the incoming window paints unoffset over the animation and the screen CUTS
	instead of sliding. This is the same fault that broke the EQ screen; it is
	a property of jive/ui/Canvas.lua, so EVERY Canvas screen must repeat it.
	Gated by test/test_canvaslayer.lua.
	]]
	local applet = self
	self.canvas.draw = function(_, surface, layer)
		if layer and (layer & LAYER_CONTENT) == 0 then return end
		applet:_redrawTone(surface)
	end

	window:addWidget(self.canvas)

	-- ScreenSaversApplet eats EVENT_SCROLL globally to wake from idle, which
	-- left the knob dead on the EQ screen until an unrelated press. Same fix.
	window:setAllowScreensaver(false)

	local function repaint()
		self.canvas:reDraw()
		Framework:reDraw(nil)
	end

	window:addListener(EVENT_SCROLL, function(event)
		local d = event:getScroll()
		if self.toneEditing then
			self:_nudgeKey(TONE_ROWS[self.toneRow].key, d)
			self:_design()
			self:_applyNow()
		else
			-- one row per event, so a fast twist cannot jump the selection
			self.toneRow = U.nextCell(self.toneRow, d, #TONE_ROWS)
		end
		repaint()
		return EVENT_CONSUME
	end)

	window:addListener(EVENT_KEY_PRESS, function(event)
		local k = event:getKeycode()
		if k == KEY_GO then
			if not self.toneEditing then
				-- Snapshot BEFORE the first click: edits apply live, so cancel
				-- means "put it back", and there is nothing to put back unless
				-- it was captured on entry to EDIT.
				self.snap        = U.snapshot(self:getSettings())
				self.toneEditing = true
			else
				self.toneEditing = false
				self.snap        = nil
				local res = self:_flushApply()
				self:storeSettings()
				self:_reportApply(res, "Equalizer")
			end
			repaint()
			return EVENT_CONSUME

		elseif k == KEY_BACK and self.toneEditing then
			--[[
			⛔⛔ CANCEL DOES NOT MOVE THE VOLUME ITSELF. IT LETS THE TRANSACTION DO IT.

			This used to roll the player volume back here, BEFORE _applyNow, and
			that is outside the PCM mute -- the exact ordering defect fixed in the
			main path. Cancelling from a reduced edit back to a strongly boosted
			snapshot raised the volume first and restored the stronger attenuation
			afterwards, so the make-up briefly stood over a filter that had not
			been put back yet.

			It was invisible to test_ordering, which drives applyBSPMuted and never
			runs this handler.

			The fix is not to move the volume more carefully -- it is not to move it
			here at all. restoreSnapshot puts back the snapshot's controls AND its
			old appliedAtten; keeping the REAL appliedAtten instead means the
			transaction sees "currently carrying X, target is Y" and reconciles the
			whole difference inside the mute, in the safe order, with the failure
			handling everything else already has.
			]]
			local s          = self:getSettings()
			local appliedNow = s.appliedAtten or 0
			U.restoreSnapshot(s, self.snap)
			s.appliedAtten   = appliedNow      -- the volume is still where it is
			self.snap        = nil
			self.toneEditing = false
			self:_design()
			local res = self:_applyNow()
			self:storeSettings()
			self:_reportApply(res, "Equalizer")
			repaint()
			return EVENT_CONSUME
		end
		return EVENT_UNUSED
	end)

	--[[
	HOLD TO BYPASS -- the same gesture, on the same one flag.

	settings.enabled is the ONLY bypass state in the applet. The EQ screen's
	hold, this hold, and the Tone Controls checkbox all toggle this one field,
	so there is nothing to keep in sync: they cannot disagree because there is
	only one of them. _applyNow reads it directly (`(not s.enabled) or ...`).
	]]
	window:addListener(EVENT_KEY_HOLD, function(event)
		if event:getKeycode() == KEY_GO then
			local s = self:getSettings()
			s.enabled = not s.enabled
			local res = self:_flushApply()
			self:storeSettings()
			self:_reportApply(res, "Equalizer")
			repaint()
			return EVENT_CONSUME
		end
		return EVENT_UNUSED
	end)

	self:tieAndShowWindow(window)
	return window
end


function settingsShow(self, menuItem)
	local window = Window("text_list", menuItem and menuItem.text or "Equalizer",
	                      'settingstitle')

	self.cell    = 1
	self.editing = false
	self.fontS     = Font:load("fonts/FreeSans.ttf", 12)
	self.fontXS    = Font:load("fonts/FreeSans.ttf", 9)
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
				local res = self:_flushApply()
				self:storeSettings()
				self:_reportApply(res, "Equalizer")
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
			--[[
			⛔⛔ THE VOLUME IS NOT MOVED HERE. See the matching note on the Tone
			screen's cancel: rolling it back at this point happens OUTSIDE the PCM
			mute, which is the ordering defect the main path already fixed.

			Keeping the REAL appliedAtten across restoreSnapshot is what makes the
			transaction able to do it: it then sees the true current make-up and
			the snapshot's target, and reconciles the difference inside the mute.
			]]
			local appliedNow = s.appliedAtten or 0

			U.restoreSnapshot(s, self.snap)
			s.appliedAtten = appliedNow        -- the volume is still where it is

			self.snap    = nil
			self.editing = false
			self:_design()
			local res = self:_flushApply()
			self:storeSettings()
			self:_reportApply(res, "Equalizer")
			repaint(self)
			return EVENT_CONSUME
		end
		return EVENT_UNUSED
	end)

	window:addListener(EVENT_KEY_HOLD, function(event)
		if event:getKeycode() == KEY_GO then
			local s = self:getSettings()
			s.enabled = not s.enabled
			local res = self:_flushApply()
			self:storeSettings()
			self:_reportApply(res, "Equalizer")
			repaint(self)
			return EVENT_CONSUME
		end
		return EVENT_UNUSED
	end)

	window:addListener(EVENT_WINDOW_POP, function()
		local res = self:_flushApply()
		self:storeSettings()
		self:_reportApply(res, "Equalizer")
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
	self:_applyNow(true)
end
