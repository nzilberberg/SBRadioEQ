--[[
SBRadioEQ -- eqapply.lua

Turns two band specs into codec register writes, and reads them back to confirm.

REGISTER MAP (page 1; ALSA numids on this driver)
  biquad 1  N0=22  N1=23  N2=24  D1=28  D2=29     <- band 1 (bass)
  biquad 2  N3=25  N4=26  N5=27  D4=30  D5=31     <- band 2 (treble)
  enable    numid 21 = page-0 register 12
              D3 left-DAC effects | D1 right-DAC effects  ->  10 enables both
              0 bypasses (there is NO per-section bypass; the bits are per channel)

⛔ THE READ PATH IS BYTE-SWAPPED AND THE WRITE PATH IS NOT.
`aic3104_get_effect` assembles `read(reg) | read(reg+1) << 8`, but reg holds the
MSB. So WRITE the true coefficient, and byte-swap anything you READ before
comparing. Skipping the swap makes TI's own defaults look like an unstable
filter -- which is exactly the false alarm that cost an hour.
]]

local M = {}

M.AMIXER = "/usr/bin/amixer"
M.CARD   = 0

M.NUMID = {
	enable = 21,
	-- DAC digital volume, 0-127 in 0.5 dB steps, hardware soft-stepped one step
	-- per input sample. Used to silence the bypass window during a coefficient
	-- write. SqueezePlay never touches it (verified: pinned at 127 across every
	-- player volume), so it is free for us to use.
	pcmVolume = 1,
	band1  = { N0 = 22, N1 = 23, N2 = 24, D1 = 28, D2 = 29 },
	band2  = { N0 = 25, N1 = 26, N2 = 27, D1 = 30, D2 = 31 },
}

M.ENABLE_BOTH = 10
M.BYPASS      = 0

local ORDER = { "N0", "N1", "N2", "D1", "D2" }

-- The BSP addresses controls by NAME, not numid.
M.NAME = {
	enable = "Audio Codec Digital Filter Control",
	band1 = {
		N0 = "Audio Effects Filter N0 Coefficient",
		N1 = "Audio Effects Filter N1 Coefficient",
		N2 = "Audio Effects Filter N2 Coefficient",
		D1 = "Audio Effects Filter D1 Coefficient",
		D2 = "Audio Effects Filter D2 Coefficient",
	},
	band2 = {
		N0 = "Audio Effects Filter N3 Coefficient",
		N1 = "Audio Effects Filter N4 Coefficient",
		N2 = "Audio Effects Filter N5 Coefficient",
		D1 = "Audio Effects Filter D4 Coefficient",
		D2 = "Audio Effects Filter D5 Coefficient",
	},
}

local function unsigned(v)
	if v < 0 then return v + 65536 end
	return v
end

-- Undo the driver's read-path byte swap.
function M.swap16(v)
	return (v % 256) * 256 + math.floor(v / 256)
end

function M.toSigned(v)
	if v > 32767 then return v - 65536 end
	return v
end

--[[
Build the shell command for a write. Pure -- no side effects -- so the exact
string is testable without touching the hardware.

  c1, c2  coefficient tables (or nil to leave that biquad alone)
  enable  M.ENABLE_BOTH or M.BYPASS

Ordering matters: TI warns that partially-updated coefficients can momentarily
describe an unstable filter, so the filter is bypassed BEFORE the writes and
re-enabled after. The codec soft-mutes across the change in hardware
(datasheet 10.3.4.4), so this is click-free.
]]
function M.buildCommand(c1, c2, enable)
	local parts = {}
	local function cset(numid, v)
		parts[#parts + 1] = string.format("%s -c %d cset numid=%d %d,%d >/dev/null 2>&1",
		                                  M.AMIXER, M.CARD, numid, v, v)
	end

	cset(M.NUMID.enable, M.BYPASS)          -- quiet the filter while it changes

	if c1 then
		for _, k in ipairs(ORDER) do cset(M.NUMID.band1[k], unsigned(c1[k])) end
	end
	if c2 then
		for _, k in ipairs(ORDER) do cset(M.NUMID.band2[k], unsigned(c2[k])) end
	end

	cset(M.NUMID.enable, enable)

	-- One os.execute, not twelve: a process spawn costs far more than the write
	-- itself on a 360 MHz core.
	return table.concat(parts, "; ")
end

function M.execute(cmd)
	return os.execute(cmd)
end

--[[
Apply two designed bands.

  c1, c2   coefficient tables from eqdesign.design()
  bypass   true to bypass wholesale (both bands flat)

Returns the command that was run, so a caller can log exactly what happened.
]]
function M.apply(c1, c2, bypass)
	local cmd
	if bypass then
		cmd = string.format("%s -c %d cset numid=%d %d,%d >/dev/null 2>&1",
		                    M.AMIXER, M.CARD, M.NUMID.enable, M.BYPASS, M.BYPASS)
	else
		cmd = M.buildCommand(c1, c2, M.ENABLE_BOTH)
	end
	M.execute(cmd)
	return cmd
end

--[[
BSP path -- in-process ALSA, ~2.25 ms per write measured on the Radio, against
~92 ms for an amixer process spawn. A full 12-write apply is ~27 ms, which is
what makes live knob updates possible at all.

⛔ setMixer is VARIADIC AND MEMSETS THE VALUE STRUCT. `baby_bsp.c l_set_mixer`
does `memset(value, 0, ...)` then fills value[i] for each argument. So calling
it with ONE number on a stereo control sets the left channel and writes ZERO to
the right -- silence on one side, not a stale value. Coefficients MUST be passed
twice. Measured, not theorised: a single-argument write left R=0.
]]
function M.setStereo(bsp, name, v)
	bsp:setMixer(name, v, v)
end

--[[
Write only the coefficients that actually CHANGED.

The filter is bypassed while coefficients go in (TI: partially-updated coefficients
can momentarily describe an unstable system). But bypass means UNFILTERED audio,
and by then the volume has already been raised by the make-up -- so the bypass
window plays exactly `attenDb` too loud. Measured cost: 3.25 ms per write, so ten
writes is ~30 ms of audible overshoot per adjustment.

Diffing shrinks the window to only what moved, and skips the bracket entirely when
nothing did. Note it cannot be reduced to "just the band the user touched": joint
normalisation means a bass change rescales the treble section too, so the decision
has to be per coefficient, not per band.

Returns the number of coefficient writes performed.
]]
function M.applyBSPDiff(bsp, c1, c2, prev, bypass, prevBypass)
	if bypass then
		if prevBypass ~= true then bsp:setMixer(M.NAME.enable, M.BYPASS) end
		return 0
	end

	local pending = {}
	local function collect(c, prevC, names)
		if not c then return end
		for _, k in ipairs(ORDER) do
			if not prevC or prevC[k] ~= c[k] then
				pending[#pending + 1] = { names[k], unsigned(c[k]) }
			end
		end
	end
	collect(c1, prev and prev.c1, M.NAME.band1)
	collect(c2, prev and prev.c2, M.NAME.band2)

	-- Nothing moved and the filter is already on: touch nothing at all.
	if #pending == 0 and prevBypass == false then return 0 end

	bsp:setMixer(M.NAME.enable, M.BYPASS)
	for _, w in ipairs(pending) do M.setStereo(bsp, w[1], w[2]) end
	bsp:setMixer(M.NAME.enable, M.ENABLE_BOTH)
	return #pending
end

--[[
POLE GEOMETRY -- retained for the diagnostics only. NOT a safety criterion.

There was once an applyBSPLive here that skipped the bypass to avoid the pop,
justified by this reasoning: only the denominator places poles, so pick a D1/D2
write order whose intermediate poles are inside the unit circle and every state
the chip passes through is provably stable.

Every step of that is true, and the conclusion is still wrong. The device
answered with a half-second 11 kHz shriek (2026-08-01). diag_shriek.lua measures
why: an intermediate peaked at +42.1 dB where the endpoint peaked at +2.5 dB,
with the intermediate pole radius IDENTICAL to the endpoint's. The poles were
never the problem.

A shelf's numerator very nearly cancels its own denominator away from the shelf
frequency. Write a new numerator against an old denominator and that pairing
breaks, exposing the uncancelled pole at its full resonance -- a ~40 dB spike
whose frequency has nothing to do with either endpoint. Stability says the spike
decays; it does not say the spike is small.

The lesson is narrower than "be careful": a coefficient set is only meaningful
whole. There is no partial write worth reasoning about, so do not reason about
them -- bypass, write, enable. test_bracketed.lua enforces that structurally.
]]
local function poleR(a1, a2)
	local disc = a1 * a1 - 4 * a2
	if disc >= 0 then
		local r = math.sqrt(disc)
		local x, y = (-a1 + r) / 2, (-a1 - r) / 2
		if x < 0 then x = -x end
		if y < 0 then y = -y end
		if x > y then return x end
		return y
	end
	return math.sqrt(a2 < 0 and -a2 or a2)
end

-- Pole radius implied by a (D1, D2) pair, in the chip's convention.
local function radiusOf(D1, D2)
	return poleR(-2 * D1 / 32768, -D2 / 32768)
end

local MAX_R = 0.9999

-- Safe order for a band's denominator writes, or nil if neither is safe.
function M.denomOrder(prevC, c)
	local d1Changed = (not prevC) or prevC.D1 ~= c.D1
	local d2Changed = (not prevC) or prevC.D2 ~= c.D2
	if not d1Changed and not d2Changed then return {} end
	if not prevC then return nil end                      -- no history: cannot reason
	if d1Changed and not d2Changed then return { "D1" } end
	if d2Changed and not d1Changed then return { "D2" } end
	if radiusOf(c.D1, prevC.D2) < MAX_R then return { "D1", "D2" } end
	if radiusOf(prevC.D1, c.D2) < MAX_R then return { "D2", "D1" } end
	return nil
end

-- applyBSPLive removed 2026-08-01. See the note above: it emitted unbracketed
-- coefficient writes, and no ordering of them is safe. Nothing replaces it.

--[[
MUTED WRITE -- the pop, addressed at its actual source.

The audible event was never the enable-bit transitions: the codec already
soft-mutes across those by itself (datasheet 10.3.4.4). It is the window BETWEEN
them, where the filter is bypassed so the audio plays UNFILTERED while the volume
is still raised by the make-up -- a burst some 8-15 dB too loud, lasting as long
as the writes take.

Writing live instead was worse, not better: it removes the enable transition and
therefore the codec's automatic soft-mute, so coefficient changes land on a
running filter with the old state still in its delay elements. On bass, where
excursion is largest, that was more jarring and harder on the driver.

So: silence the window. The DAC digital volume soft-steps one 0.5 dB step per
input sample (10.3.4.4), i.e. full scale to mute in ~2.9 ms at 44.1 kHz, smooth by
design and enabled by default. Mute, write, restore -- a brief dip in place of a
loud burst. Dips are far less objectionable and far kinder to a small driver.

The restore value is READ rather than assumed: SqueezePlay leaves this control at
127, but hardcoding that would silently undo any future change to it.
]]
M.MUTE_CTL = "PCM Playback Volume"

--[[
THE LEVEL TO RESTORE TO -- read ONCE, never in the apply path.

This value used to be read on every knob click, so that a future change to the
control would not be silently undone by a hardcoded 127. The read is
M.readRaw -> io.popen -> a full amixer PROCESS SPAWN, and diag_spawn.lua
measured what that costs on this hardware:

    amixer spawn      215.50 ms   -- 91% of the click
    all 9 setMixer     20.70 ms   (2.30 ms each)

215 ms of fork/exec on a 360 MHz single core that is simultaneously decoding
audio starves the decoder, and that is the pop. Two rounds of work went into
shaving setMixer calls off the 20 ms beside it -- one of which caused an
audible shriek -- while this sat there unmeasured.

(Time a coefficient control, not numid=1: baby_bsp's find_element does a linear
search per call, so the volume control writes in 0.10 ms and a coefficient in
2.30 ms. Timing the cheap one understates the apply path 23-fold.)

So: read once, cache, and let the applet prime it when the screen opens rather
than when a knob turns. The original concern is still met -- the value is read
from the hardware, not assumed -- just not 220 ms at a time.

test_nospawn.lua fails the build if anything in the apply path spawns again.
]]
local mutePoint = nil

function M.mutePoint()
	if mutePoint == nil then
		mutePoint = M.readRaw(M.NUMID.pcmVolume) or 127
	end
	return mutePoint
end

-- Drop the cached value so the next mutePoint() re-reads the hardware. The
-- applet calls this when the screen opens: once per visit, off the knob path.
function M.forgetMutePoint()
	mutePoint = nil
end

function M.applyBSPMuted(bsp, c1, c2, prev, bypass, prevBypass)
	-- Nothing to do? Then do not mute -- a dip for no reason is still a dip.
	if not bypass then
		local anything = false
		for _, b in ipairs({ { c1, prev and prev.c1 }, { c2, prev and prev.c2 } }) do
			if b[1] then
				for _, k in ipairs(ORDER) do
					if not b[2] or b[2][k] ~= b[1][k] then anything = true end
				end
			end
		end
		if not anything and prevBypass == false then return 0 end
	elseif prevBypass == true then
		return 0
	end

	local restore = M.mutePoint()
	bsp:setMixer(M.MUTE_CTL, 0, 0)

	--[[
	KEEP THE BRACKET, even though we are muted. Skipping it to save 2 of 9
	setMixer calls produced a half-second high-pitched shriek on the device
	while the bass gain was being adjusted (2026-08-01).

	The reasoning that justified skipping it was wrong in two ways, and both
	matter more than the 6 ms:

	  * "Muted, so a partial filter is inaudible" is false. Mute silences the
	    filter's OUTPUT; the audio still flows into it, so an intermediate
	    coefficient set still excites the filter and the energy is stored in
	    its delay elements. Restoring the volume then plays the ringing back.
	  * "Inside the unit circle" is not the same as safe. applyBSPLive admits
	    any intermediate with r < 0.9999, and a pole at 0.9999 is a resonator
	    with a ~0.5 s decay -- which is exactly the event that was heard.

	Bypassing means no intermediate state ever RUNS, so nothing can be excited.
	That is the property being paid for, and it is not negotiable for 6 ms.
	]]
	local n = M.applyBSPDiff(bsp, c1, c2, prev, bypass, prevBypass)

	bsp:setMixer(M.MUTE_CTL, restore, restore)
	return n
end

function M.applyBSP(bsp, c1, c2, bypass)
	if bypass then
		bsp:setMixer(M.NAME.enable, M.BYPASS)   -- 1-value control
		return
	end
	bsp:setMixer(M.NAME.enable, M.BYPASS)
	if c1 then
		for _, k in ipairs(ORDER) do M.setStereo(bsp, M.NAME.band1[k], unsigned(c1[k])) end
	end
	if c2 then
		for _, k in ipairs(ORDER) do M.setStereo(bsp, M.NAME.band2[k], unsigned(c2[k])) end
	end
	bsp:setMixer(M.NAME.enable, M.ENABLE_BOTH)
end

-- Read one control's first value (raw, as the driver reports it).
function M.readRaw(numid)
	local fh = io.popen(string.format("%s -c %d cget numid=%d 2>/dev/null",
	                                  M.AMIXER, M.CARD, numid))
	if not fh then return nil end
	local out = fh:read("*a")
	fh:close()
	-- MUST anchor on the ": values=" line. amixer prints a TYPE line first --
	-- "; type=INTEGER,access=rw------,values=2,min=0,..." -- whose `values=` is
	-- the value COUNT, not the value. Matching bare "values=" reads 2 for every
	-- coefficient and 1 for the enable register, which looks like plausible data.
	local v = out:match(":%s*values=(%-?%d+)")
	if not v then return nil end
	return tonumber(v)
end

-- Read a biquad back as TRUE signed coefficients (byte-swap undone).
function M.readBand(which)
	local map = M.NUMID[which]
	local c = {}
	for _, k in ipairs(ORDER) do
		local raw = M.readRaw(map[k])
		if raw == nil then return nil end
		c[k] = M.toSigned(M.swap16(raw))
	end
	return c
end

function M.readEnable()
	return M.readRaw(M.NUMID.enable)
end

-- Compare what is in the chip against what we meant to write.
function M.verify(which, expected)
	local got = M.readBand(which)
	if not got then return false, "readback failed" end
	for _, k in ipairs(ORDER) do
		if got[k] ~= expected[k] then
			return false, string.format("%s: chip=%d expected=%d", k, got[k], expected[k])
		end
	end
	return true, "match"
end

return M
