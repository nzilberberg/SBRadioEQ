--[[
SBRadioEQ -- eqdesign.lua

Designs one biquad band for the TLV320AIC3104 audio effects filter and VERIFIES
what the chip will actually produce before anyone writes it.

Pure Lua 5.1, no dependencies beyond `math`. Runs unchanged inside SqueezePlay.

CHIP CONVENTION (verified against TI Table 10-4 and on-device readback):

    H(z) = (N0 + 2*N1*z^-1 + N2*z^-2) / (32768 - 2*D1*z^-1 - D2*z^-2)

  note the factor of 2 on N1 and D1 -- unguessable, and getting it wrong
  produces a filter that is stable and completely wrong. Coefficients are signed
  16-bit two's complement.

⚠️ PLATFORM TRAP: in SqueezePlay's Lua, `^` binds LOWER than `*` and unary
minus, and associates LEFT (measured on the device 2026-08-01: 2*3^2 == 36,
-3^2 == 9, 2^2^3 == 64; stock Lua 5.1 gives 18, -9, 256). Every use of `^` in
this file is written as a literal base with a parenthesised exponent, which
evaluates the same either way. Keep it that way.

WHY VERIFICATION IS NOT OPTIONAL: a Q=8 peaking band at 100 Hz asking for -6 dB
delivers +2.3 dB -- sign inverted, 8.3 dB wrong -- while sitting at pole radius
0.99875, i.e. perfectly stable. Checking stability alone passes it. This module
therefore compares the REALIZED (quantized) response against the intended one and
backs Q off until it agrees.
]]

local math = math

local log10 = math.log10 or function(x) return math.log(x) / math.log(10) end

local M = {}

M.SCALE   = 32768      -- denominator scale / N0,N2,D2 scale
M.SCALE_2 = 16384      -- N1 and D1 carry an implicit factor of 2
M.INT_MIN = -32768
M.INT_MAX = 32767

-- A perfectly flat section. Exact unity would need N0 = 32768, one past the
-- signed-16-bit maximum, so 32767 it is: -0.00027 dB, dead flat, no poles.
-- Used whenever a band sits at 0 dB -- the general path would leave a small
-- FREQUENCY-DEPENDENT error instead, and there is no per-section bypass on this
-- chip (reg 12's enable bits are per channel and cover both biquads).
M.FLAT = { N0 = 32767, N1 = 0, N2 = 0, D1 = 0, D2 = 0 }

-------------------------------------------------------------------- internals

--[[
NaN must not survive this.

Every comparison against NaN is false, so the two range tests below both fail to
fire and math.floor(NaN + 0.5) is NaN -- meaning a NaN coefficient used to pass
straight through and get written to the codec. That is how a 4 kHz treble shelf
came out completely silent: one NaN in N1.

Reject it here as well as at the end of designPair. A coefficient of 0 is a
filter that does nothing; a NaN is a filter that does anything.
]]
local function clampInt(v)
	if type(v) ~= "number" or v ~= v then return 0 end     -- v ~= v is true only for NaN
	if v == 1 / 0 then return M.INT_MAX end
	if v == -1 / 0 then return M.INT_MIN end
	v = math.floor(v + 0.5)
	if v > M.INT_MAX then return M.INT_MAX end
	if v < M.INT_MIN then return M.INT_MIN end
	return v
end

-- RBJ Audio EQ Cookbook. Returns b0,b1,b2,a1,a2 normalised to a0 = 1.
-- `shape` is S (shelf slope) for shelves, Q for peaking. For shelves S=1 is the
-- steepest that stays monotonic; below 1 is gentler.
local function designRaw(kind, fs, f0, gainDb, shape)
	local A  = 10 ^ (gainDb / 40)
	local w0 = 2 * math.pi * f0 / fs
	local cw, sw = math.cos(w0), math.sin(w0)
	local b0, b1, b2, a0, a1, a2

	if kind == "peaking" then
		local alpha = sw / (2 * shape)
		b0 = 1 + alpha * A
		b1 = -2 * cw
		b2 = 1 - alpha * A
		a0 = 1 + alpha / A
		a1 = -2 * cw
		a2 = 1 - alpha / A
	else
		local alpha = sw / 2 * math.sqrt((A + 1 / A) * (1 / shape - 1) + 2)
		local t = 2 * math.sqrt(A) * alpha
		if kind == "highshelf" then
			b0 =      A * ((A + 1) + (A - 1) * cw + t)
			b1 = -2 * A * ((A - 1) + (A + 1) * cw)
			b2 =      A * ((A + 1) + (A - 1) * cw - t)
			a0 =           (A + 1) - (A - 1) * cw + t
			a1 =      2 * ((A - 1) - (A + 1) * cw)
			a2 =           (A + 1) - (A - 1) * cw - t
		elseif kind == "lowshelf" then
			b0 =      A * ((A + 1) - (A - 1) * cw + t)
			b1 =  2 * A * ((A - 1) - (A + 1) * cw)
			b2 =      A * ((A + 1) - (A - 1) * cw - t)
			a0 =           (A + 1) + (A - 1) * cw + t
			a1 =     -2 * ((A - 1) + (A + 1) * cw)
			a2 =           (A + 1) + (A - 1) * cw - t
		else
			error("unknown filter kind: " .. tostring(kind))
		end
	end

	return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
end

function M.quantize(b0, b1, b2, a1, a2)
	return {
		N0 = clampInt(b0 * M.SCALE),
		N1 = clampInt(b1 * M.SCALE_2),
		N2 = clampInt(b2 * M.SCALE),
		D1 = clampInt(-a1 * M.SCALE_2),
		D2 = clampInt(-a2 * M.SCALE),
	}
end

-- Decode the integers the way the CHIP will read them. Any check that skips
-- this round trip is checking the wrong filter.
function M.dequantize(c)
	return c.N0 / M.SCALE,
	       2 * c.N1 / M.SCALE,
	       c.N2 / M.SCALE,
	       -2 * c.D1 / M.SCALE,
	       -c.D2 / M.SCALE
end

function M.responseDb(b0, b1, b2, a1, a2, f, fs)
	local w = 2 * math.pi * f / fs
	local c1, s1 = math.cos(w), math.sin(w)
	local c2, s2 = math.cos(2 * w), math.sin(2 * w)
	local nr = b0 + b1 * c1 + b2 * c2
	local ni = -(b1 * s1 + b2 * s2)
	local dr = 1 + a1 * c1 + a2 * c2
	local di = -(a1 * s1 + a2 * s2)
	local num = math.sqrt(nr * nr + ni * ni)
	local den = math.sqrt(dr * dr + di * di)
	if den == 0 then return 1 / 0 end
	return 20 * log10(num / den)
end

function M.poleRadius(a1, a2)
	local disc = a1 * a1 - 4 * a2
	if disc >= 0 then
		local r = math.sqrt(disc)
		return math.max(math.abs((-a1 + r) / 2), math.abs((-a1 - r) / 2))
	end
	return math.sqrt(math.abs(a2))
end

-- Log-spaced grid, built once. Verification only needs coverage, not density.
local function buildGrid(n, fLo, fHi)
	local g, lo, hi = {}, log10(fLo), log10(fHi)
	for i = 0, n - 1 do
		g[i + 1] = 10 ^ (lo + (hi - lo) * i / (n - 1))
	end
	return g
end

--[[
Evaluation band: 40 Hz - 16 kHz, NOT 20 Hz - 20 kHz.

Below ~40 Hz a shelf with a corner near 60 Hz is not representable in 16-bit
direct form at all. Measured: with the coefficients marching perfectly smoothly
(N0 8652 -> 8634 -> 8618, D1 32621 -> 32618 -> 32616), the response at 20 Hz
swung +5.01, -12.66, +4.85, -12.50 dB on consecutive 1 Hz steps of the corner.
The reason is cancellation, not a bug: at 20 Hz the numerator evaluates to
0.264 - 0.523 + 0.259 = 0.00006, and one LSB is 0.00003 -- half the answer.

Including that region poisons everything downstream: the peak used for
normalisation, the error metric, and the drawn curve. Excluding it makes all
three meaningful. It costs nothing real -- the Radio's driver produces nothing
at 20 Hz, and CamCoreEQ only avoids this because CamillaDSP uses 64-bit floats
where the cancellation never bites.
]]
M.F_EVAL_LO = 40
M.F_EVAL_HI = 16000
M.GRID = buildGrid(64, M.F_EVAL_LO, M.F_EVAL_HI)

--[[
CLIPPING is a different question from SHAPE, and needs a different band.

Everything above is about the shape the user asked for: the drawn curve, the
error metric, the peak the design normalises to. Including sub-40 Hz there would
poison all three, for the cancellation reason documented above.

But the chip still computes the filter down there, and if the realised response
exceeds unity at 25 Hz it clips at 25 Hz -- producing harmonics at 50, 75, 100 Hz
that ARE audible even though 25 Hz is not. Measured +3.49 dB at 20 Hz for bass
100 / +15 / Q 0.2.

So the CLIP check alone extends below the shape band. Checked before shipping it:
normalising against this region does NOT make the make-up jumpier -- worst jump
between adjacent settings went 5.48 dB to 5.41 dB, i.e. unchanged. (That 5.48 dB
is a separate pre-existing problem, not caused by this.)
]]
M.F_CLIP_LO = 20
M.SUB_GRID  = buildGrid(16, M.F_CLIP_LO, M.F_EVAL_LO)

-- The unquantised design, for diagnostics: lets a test separate "the design
-- moved" from "the 16-bit round trip moved it".
function M.designIdeal(kind, fs, f0, gainDb, shape)
	if gainDb == 0 then return 1, 0, 0, 0, 0 end
	return designRaw(kind, fs, f0, gainDb, shape)
end

--------------------------------------------------------------------- public

M.MAX_ERR_DB = 2.0     -- realized vs intended; a GATE on usable range, not the display
M.MAX_POLE_R = 0.9999  -- margin below the unit circle

--[[
Design one band, verified.

  kind    "lowshelf" | "highshelf" | "peaking"
  fs      sample rate (44100 on this player)
  f0      centre / corner frequency, Hz
  gainDb  -15..+15 (0 returns the flat section)
  shape   Q for peaking, S for shelves
  opts    { maxGainDb = <cap on realized peak gain, or nil> }

Returns coeffs, info where info = {
  ok, shape (possibly reduced), maxErrDb, poleR, maxGainDb, reason }
]]
function M.design(kind, fs, f0, gainDb, shape, opts)
	opts = opts or {}

	if gainDb == 0 then
		return M.FLAT, { ok = true, shape = shape, maxErrDb = 0, poleR = 0,
		                 maxGainDb = 0, attenDb = 0, reason = "flat" }
	end

	local grid = M.GRID
	local try = shape

	do
		local b0, b1, b2, a1, a2 = designRaw(kind, fs, f0, gainDb, try)

		-- PEAK-NORMALISE. The numerator coefficients are Q15, so |b| < 1 and the
		-- filter CANNOT express gain above 0 dB -- a +12 dB shelf would need
		-- N0 = b0*32768 > 32767 and clamp, wrecking the response (measured: 8.9 dB
		-- error before this was added). So any boost is realised as cut-elsewhere,
		-- exactly as TI's own default does it ("3 dB boost below 150 Hz" is 0 dB
		-- below and -3 dB above). The shape is preserved; the whole curve is shifted
		-- down so its maximum sits at 0 dB, and `attenDb` tells the caller how much
		-- level to make back up with volume.
		local peak = -1 / 0
		for i = 1, #grid do
			local g = M.responseDb(b0, b1, b2, a1, a2, grid[i], fs)
			if g > peak then peak = g end
		end
		local attenDb = 0
		if peak > 0 then
			attenDb = peak
			local k = 10 ^ (-peak / 20)
			b0, b1, b2 = b0 * k, b1 * k, b2 * k
		end

		local c = M.quantize(b0, b1, b2, a1, a2)
		local qb0, qb1, qb2, qa1, qa2 = M.dequantize(c)

		--[[ QUANTISE-THEN-REPAIR.

		Rounding the denominator to 16 bits can push a pole just outside the unit
		circle at low corner frequencies, where the poles already crowd z = 1.
		Discarding those designs (returning FLAT) is worse than useless for a UI:
		a design one click away from a good one snaps to a flat line, which
		measured as a 17.5 dB jump on a single frequency step -- a bigger
		discontinuity than the back-off it replaced.

		So pull the poles back in instead. Shrinking |D2| by one LSB at a time
		moves the pole radius inward in the smallest step the format allows, so
		the repaired filter stays visually and audibly indistinguishable from the
		one asked for, and the control stays continuous.
		]]
		local repairs = 0
		while M.poleRadius(qa1, qa2) >= M.MAX_POLE_R and repairs < 64 do
			if c.D2 > 0 then c.D2 = c.D2 - 1
			elseif c.D2 < 0 then c.D2 = c.D2 + 1
			else break end
			qb0, qb1, qb2, qa1, qa2 = M.dequantize(c)
			repairs = repairs + 1
		end

		local poleR = M.poleRadius(qa1, qa2)
		local maxErr, maxGain = 0, -1 / 0
		for i = 1, #grid do
			local f = grid[i]
			local got  = M.responseDb(qb0, qb1, qb2, qa1, qa2, f, fs)
			local want = M.responseDb(b0, b1, b2, a1, a2, f, fs)
			local e = math.abs(got - want)
			if e > maxErr then maxErr = e end
			if got > maxGain then maxGain = got end
		end

		local reason = nil
		if poleR >= M.MAX_POLE_R then
			reason = "unstable"
		elseif maxErr > M.MAX_ERR_DB then
			reason = "quantisation"
		elseif opts.maxAttenDb and attenDb > opts.maxAttenDb + 0.05 then
			reason = "needs more make-up than allowed"
		end

		--[[ info.ideal -- the normalised design BEFORE the 16-bit round trip.

		Diagnostics only: it lets a test separate "the design moved" from "the
		16-bit round trip moved it". It is NOT what gets drawn. An earlier version
		of this comment directed the display to plot this ideal instead of the
		realised response; that made the graph smooth by drawing something other
		than what the chip does (measured gap up to 7.33 dB at 40 Hz for a
		100 Hz / +15 dB / S 2.0 bass shelf), which is the exact defect
		test_graphtruth.lua now forbids. designPair() hands the applet realised
		sections to draw (info.realised1/realised2 there), and fit-quantisation below
		keeps those close to the request.
		]]
		local info = { ok = (reason == nil), shape = try, maxErrDb = maxErr,
		               poleR = poleR, maxGainDb = maxGain, attenDb = attenDb,
		               reason = reason,
		               ideal = { b0 = b0, b1 = b1, b2 = b2, a1 = a1, a2 = a2 } }
		--[[ NO BACK-OFF.

		Silently retrying at a reduced Q makes the output a DISCONTINUOUS function
		of the input, and that is what made the curve lurch on screen. Measured on
		this device before the change: a single Q click moved the response 4.32 dB,
		a single frequency click moved it 11.52 dB, and across a GAIN sweep with Q
		held fixed at 0.9 the achieved Q still changed 21 times. Peak-normalisation
		then turned each shape change into a vertical shift of the whole curve.

		So: design exactly what was asked for. The caller keeps the control inside
		the usable range with maxShape(), so requested always equals achieved and
		the curve moves smoothly. info.ok still reports quantisation honestly --
		and since the graph is drawn from the QUANTISED coefficients, the user sees
		the real response either way.

		Instability is the one hard refusal: an unstable filter oscillates at full
		scale into the speaker, which is not a cosmetic problem.
		]]
		if poleR >= M.MAX_POLE_R then
			info.ok, info.reason = false, "unstable"
			return M.FLAT, info
		end
		return c, info
	end
end

--[[
WHERE A BIQUAD'S PEAK ACTUALLY IS.

M.GRID is 64 log-spaced points, and its widest gap is 1452 Hz near 14.5 kHz.
A pole at r = 0.998 is about 28 Hz wide. Normalising against that grid therefore
scored a treble shelf at 16 kHz / +15 dB / Q 2.0 as -0.00 dB when its realised
response actually peaked at +9.69 dB at 18762 Hz -- 9.7 dB above full scale,
shipped, because the needle fell between two grid points.

Adding points is the wrong fix: this runs on every knob click on a 360 MHz core
with no FPU. The peak of a resonant biquad sits at its POLE frequency, which is
a closed-form value, so evaluate there rather than hoping to sample near it.

Returns nil for real poles, which have no resonant peak to find.
]]
function M.poleFreq(a1, a2, fs)
	local disc = a1 * a1 - 4 * a2
	if disc >= 0 then return nil end                -- real poles: no resonance
	local re, im = -a1 / 2, math.sqrt(-disc) / 2
	local theta = math.atan2(im, re)
	if theta <= 0 then return nil end
	local f = theta * fs / (2 * math.pi)
	if f <= 0 or f >= fs / 2 then return nil end
	return f
end

--[[
Peak response of a QUANTISED section, in dB.

The grid for shape, the pole frequency for the needle, then a local refinement
around whichever won -- because quantisation moves the true maximum slightly off
the analytic pole. 24 refinement points over a +/-15% window costs far less than
a grid dense enough to find it by luck.
]]
function M.realisedPeakDb(c, fs)
	if not c then return -1 / 0, 0 end
	local b0, b1, b2, a1, a2 = M.dequantize(c)
	local best, bf = -1 / 0, 0

	local function try(f)
		if f and f > 0 and f < fs / 2 then
			local v = M.responseDb(b0, b1, b2, a1, a2, f, fs)
			if v > best then best, bf = v, f end
		end
	end

	for i = 1, #M.GRID do try(M.GRID[i]) end
	for i = 1, #M.SUB_GRID do try(M.SUB_GRID[i]) end   -- clipping below 40 Hz
	try(M.poleFreq(a1, a2, fs))
	try(fs / 2 - 1)                                  -- Nyquist edge

	local lo, hi = bf * 0.85, bf * 1.15
	for i = 0, 24 do try(lo + (hi - lo) * i / 24) end

	return best, bf
end

-- Highest shape value that verifies at this frequency/gain -- drives the UI's
-- Q slider range so the limit is VISIBLE in the control rather than silently
-- rewriting the filter behind the user's back.
function M.maxShape(kind, fs, f0, gainDb, ceiling)
	ceiling = ceiling or 8
	if gainDb == 0 then return ceiling end
	local try = ceiling
	for _ = 1, 40 do
		local _, info = M.design(kind, fs, f0, gainDb, try)
		if info.ok then return try end
		try = try * 0.93
		if try < 0.05 then break end
	end
	return 0.05
end

--[[
FIT-QUANTISATION: pick the integers that realise the RESPONSE, not the ones
nearest each float coefficient.

Why rounding each coefficient independently fails at low corners (measured on
the device, bass 100 Hz / +15 dB / S 2.0):

  The response near DC is the ratio of two near-cancelling sums,
      num = N0 + 2*N1 + N2        den = 32768 - 2*D1 - D2,
  and at a 100 Hz corner the ideal values of BOTH sums are only ~2-3 LSB
  (den 2.795 LSB, num 2.172 LSB). Independent rounding landed num on 1 instead
  of 2 -- a 54% error in the sum -- which realised -7.33 dB of error at 40 Hz
  while every individual coefficient was correctly rounded to 1 LSB. That is
  the whole graph-vs-sound divergence: not instability, not the repair loop
  (verified: repairs never fired in the failing cases), just the sums.

So quantise the SUMS deliberately:

  * den sum: dInt = round of the ideal, D2 chosen as 32768 - 2*D1 - dInt so the
    denominator's DC cancellation is exact to the format's resolution;
  * num sum: nInt chosen so nInt/dInt best matches the ideal DC gain ratio;
  * N1 keeps its plain rounding (it controls the w-linear term, which is not
    critical), and N0/N2 are recovered from the sum and the odd part b0-b2.

Where the sums are so small that even this is coarse (dInt of 2-5 LSB leaves
the realisable lattice visibly quantised), a bounded local search tries
dInt +/- 1, D1 offsets up to +/-10 (pole damping at fixed corner) and both
neighbouring nInt, scoring each candidate by its realised-vs-ideal error over a
fixed grid and keeping the best. Unstable candidates are rejected outright.

MEASURED, 150-point sweep of the bass lattice (100-288 Hz corners, gains
-15..+15, S 0.2..2.0), worst |realised - ideal| over 40 Hz - 8 kHz:

    independent rounding:  worst 7.33 dB   mean 0.70 dB
    fit-quantisation:      worst 1.14 dB   mean 0.18 dB

The residual 1.14 dB (at 100 Hz / +15 / S 2.0) is a representability floor,
not a search failure: a brute-force sweep over a much wider integer
neighbourhood (D1 +/-10, dInt +/-2..+3, zero-spread N1 +/-48, both nInt) found
nothing better than 1.13 dB. With ideal sums of ~2.8 LSB the chip's lattice of
realisable low-shelf corners and DC ratios is simply that coarse. This is why
the drawn curve comes from the REALISED sections (see designPair): below
~150 Hz at high gain no drawable ideal exists that the chip can honour to
better than ~1 dB.

Cost, measured with the SDL wall clock (validated against os.time each run):
the search path is ~58 ms and only runs when the cheap sum-fix candidate
misses 0.15 dB (low bass corners); everywhere else the sum-fix is accepted at
~5 ms. This is paid for by designPair no longer recomputing realisedPeakDb for
diag when correct() already measured it, and by FLAT sections getting their
peak as a constant. Measured on the same 14-setting workload before and after
the change: 215.8 -> 215.9 ms per designPair call (identical); the worst
corner with one active band (100 Hz / +15 / S 2.0) is 116.0 ms, a typical
mid-band click 153.9 ms.
]]

local FIT_EVAL   = { 40, 55, 75, 105, 145, 200, 280, 460, 900, 3000 }
local FIT_ACCEPT = 0.15
local FIT_DD1    = { 0, -1, 1, -3, 3, -6, 6, -10, 10 }

local function fitQuantize(x, fs)
	local D1r = math.floor(-x.a1 * M.SCALE_2 + 0.5)
	local N1  = math.floor(x.b1 * M.SCALE_2 + 0.5)
	local den = 1 + x.a1 + x.a2
	local gDC = (x.b0 + x.b1 + x.b2) / den
	local oIf = (x.b0 - x.b2) * M.SCALE
	local oI  = math.floor(oIf + 0.5)

	-- One candidate: denominator from (dInt, D1), numerator from (nInt, N1, odd
	-- part), with the odd part nudged one LSB when parity demands it. Returns nil
	-- for anything out of range or unstable -- a rejected candidate, not an error.
	local function build(dInt, D1, nInt)
		local D2 = M.SCALE - 2 * D1 - dInt
		if D2 < M.INT_MIN or D2 > M.INT_MAX or D1 < M.INT_MIN or D1 > M.INT_MAX then
			return nil
		end
		if M.poleRadius(-2 * D1 / M.SCALE, -D2 / M.SCALE) >= M.MAX_POLE_R then
			return nil
		end
		local T = nInt - 2 * N1
		local o = oI
		if ((T + o) % 2) ~= 0 then
			if o <= oIf then o = o + 1 else o = o - 1 end
		end
		local N0, N2 = (T + o) / 2, (T - o) / 2
		if N0 < M.INT_MIN or N0 > M.INT_MAX or N2 < M.INT_MIN or N2 > M.INT_MAX
		   or N1 < M.INT_MIN or N1 > M.INT_MAX then
			return nil
		end
		return { N0 = N0, N1 = N1, N2 = N2, D1 = D1, D2 = D2 }
	end

	if den > 0 and gDC == gDC and gDC ~= 1 / 0 and gDC ~= -1 / 0 then
		local sI = den * M.SCALE
		local gi
		local function score(c, cap)
			if not gi then
				gi = {}
				for k, f in ipairs(FIT_EVAL) do
					gi[k] = M.responseDb(x.b0, x.b1, x.b2, x.a1, x.a2, f, fs)
				end
			end
			local b0, b1, b2, a1, a2 = M.dequantize(c)
			local e = 0
			for k, f in ipairs(FIT_EVAL) do
				local d = math.abs(M.responseDb(b0, b1, b2, a1, a2, f, fs) - gi[k])
				if d ~= d then return 1 / 0 end
				if d > e then
					e = d
					if e >= cap then return e end     -- cannot win; stop scoring
				end
			end
			return e
		end

		local dInt0 = math.max(1, math.floor(sI + 0.5))
		local nR0   = math.floor(gDC * dInt0 + 0.5)
		local best, bestc = 1 / 0, nil

		local c0 = build(dInt0, D1r, nR0)
		if c0 then
			best, bestc = score(c0, 1 / 0), c0
			if best <= FIT_ACCEPT then return bestc end
		end
		for _, dd in ipairs({ 0, -1, 1 }) do
			local dInt = dInt0 + dd
			if dInt >= 1 then
				local nf = math.floor(gDC * dInt)
				for _, dD1 in ipairs(FIT_DD1) do
					for _, nInt in ipairs({ nf, nf + 1 }) do
						if not (dd == 0 and dD1 == 0 and nInt == nR0) then
							local c = build(dInt, D1r + dD1, nInt)
							if c then
								local e = score(c, best)
								if e < best then best, bestc = e, c end
							end
						end
					end
				end
			end
		end
		if bestc then return bestc end
	end

	-- Fallback -- exactly the old behaviour: plain rounding, then pull the poles
	-- back inside the circle one D2 LSB at a time. Reached only when the ideal
	-- itself is degenerate (non-positive or non-finite DC sums) or every fitted
	-- candidate was unstable.
	local c = M.quantize(x.b0, x.b1, x.b2, x.a1, x.a2)
	local _, _, _, qa1, qa2 = M.dequantize(c)
	local n = 0
	while M.poleRadius(qa1, qa2) >= M.MAX_POLE_R and n < 64 do
		if c.D2 > 0 then c.D2 = c.D2 - 1 elseif c.D2 < 0 then c.D2 = c.D2 + 1 else break end
		_, _, _, qa1, qa2 = M.dequantize(c)
		n = n + 1
	end
	return c
end

--[[
Design BOTH bands together, normalising the pair rather than each section.

Normalising sections independently double-counts. Bass +12 and treble +6 sit at
opposite ends of the spectrum and never stack, so the CASCADE only peaks at +12 --
but per-section normalisation charged 12 + 6 = 18 dB of make-up, discarding 6 dB
of level and signal-to-noise for nothing.

Two constraints, not one:
  * the INTERMEDIATE signal between biquad 1 and biquad 2 must stay <= 0 dB,
    because they are cascaded in fixed point and section 1's output is section
    2's input -- so section 1 is normalised on its own merits;
  * the FINAL output must stay <= 0 dB, so section 2 absorbs only whatever the
    combined response still exceeds.

That yields the minimum total attenuation that satisfies both. Verified against
the independent case (one band flat), where it agrees with the old behaviour.

Returns c1, c2, info { attenDb, ok, realised1, realised2, diag }. realised1/realised2 are
the REALISED sections (dequantized q1/q2) -- the curve to draw. See the note at
the return statement.
]]
function M.designPair(fs, b1, b2)
	local grid = M.GRID

	local function raw(spec)
		if not spec or spec.gainDb == 0 then return nil end
		local x = {}
		x.b0, x.b1, x.b2, x.a1, x.a2 = designRaw(spec.kind, fs, spec.f0, spec.gainDb, spec.shape)
		return x
	end

	local function resp(x, f)
		if not x then return 0 end
		return M.responseDb(x.b0, x.b1, x.b2, x.a1, x.a2, f, fs)
	end

	--[[
	Peak of an unquantised design -- grid, POLE FREQUENCY, and a refinement pass.

	The grid alone is 64 log-spaced points whose widest gap is 1452 Hz near
	14.5 kHz, and a pole at r = 0.998 is 28 Hz wide. A 16 kHz treble shelf
	therefore normalised to "0.00 dB" while really peaking +9.69 dB at 18762 Hz,
	and 9.7 dB of overshoot went to the chip and clipped.

	Fixing it HERE, in the one-pass normalisation, is the whole fix. An earlier
	attempt bolted a retry loop onto the end instead; it ran away to 75 dB of
	attenuation on one setting and produced a NaN coefficient on another. The
	peak search was the broken part, so the peak search is what to correct.
	]]
	local function peakOf(x)
		if not x then return -1 / 0 end
		local best, bf = -1 / 0, 0
		local function at(f)
			if not (f and f > 0 and f < fs / 2) then return end
			local v = resp(x, f)
			if v == v and v > best then best, bf = v, f end   -- v == v rejects NaN
		end
		for i = 1, #grid do at(grid[i]) end
		for i = 1, #M.SUB_GRID do at(M.SUB_GRID[i]) end   -- clipping below 40 Hz
		at(M.poleFreq(x.a1, x.a2, fs))
		at(fs / 2 - 1)
		if bf > 0 then
			local lo, hi = bf * 0.85, bf * 1.15
			for i = 0, 24 do at(lo + (hi - lo) * i / 24) end
		end
		return best
	end

	local function scaleTo0(x)
		if not x then return 0 end
		local peak = peakOf(x)
		if peak ~= peak or peak == 1 / 0 then return 0 end     -- never scale by NaN/inf
		if peak <= 0 then return 0 end
		local k = 10 ^ (-peak / 20)
		x.b0, x.b1, x.b2 = x.b0 * k, x.b1 * k, x.b2 * k
		return peak
	end

	--[[ FIT THE COEFFICIENTS, not just the response.

	A SECOND hard representability limit, found the hard way. N1 is stored at
	scale 16384, so |b1| cannot exceed 2.0 -- but a high shelf at +9 dB / 4384 Hz
	legitimately needs b1 = -2.963. clampInt silently truncated it to -2.0, and
	because these coefficients rely on near-exact cancellation, that single
	clamped value turned a -9 dB shelf into a -36 dB brick wall. Measured on the
	device: 50 Hz -35.60 dB, 500 Hz -38.87 dB. The audible level vanished.

	Peak-normalising bounds the RESPONSE at 0 dB; it does not bound the
	COEFFICIENTS. So scale the numerator until every one of them fits strictly
	inside the format, and charge the extra to attenDb where the volume make-up
	will compensate it. The response shape is preserved exactly -- only the level
	moves, which is already accounted for.
	]]
	local function fitCoeffs(x)
		if not x then return 0 end
		local worst = math.max(math.abs(x.b0) * M.SCALE,
		                       math.abs(x.b1) * M.SCALE_2,
		                       math.abs(x.b2) * M.SCALE)
		-- Target below INT_MAX, not at it: landing exactly on 32767 is
		-- indistinguishable from having been truncated there, and the sweep
		-- flagged 1281 sections sitting right on the limit.
		local LIMIT = 32000
		if worst <= LIMIT then return 0 end
		local k = LIMIT / worst
		x.b0, x.b1, x.b2 = x.b0 * k, x.b1 * k, x.b2 * k
		return -20 * log10(k)          -- positive dB of extra attenuation
	end

	local r1, r2 = raw(b1), raw(b2)

	-- 1. Protect the intermediate: section 1 alone must not exceed unity.
	local k1 = scaleTo0(r1)

	--[[
	2. Protect the output: the PAIR must not exceed unity. Only the excess beyond
	   what section 1 already gave up is charged again.

	   Pole-aware for the same reason as scaleTo0: summing two responses over the
	   64-point grid cannot see either section's needle, so the candidate set is
	   the grid plus BOTH pole frequencies plus a refinement around the winner.
	]]
	local peak2, pf2 = -1 / 0, 0
	local function pairAt(f)
		if not (f and f > 0 and f < fs / 2) then return end
		local g = resp(r1, f) + resp(r2, f)
		if g == g and g > peak2 then peak2, pf2 = g, f end
	end
	for i = 1, #grid do pairAt(grid[i]) end
	for i = 1, #M.SUB_GRID do pairAt(M.SUB_GRID[i]) end   -- clipping below 40 Hz
	if r1 then pairAt(M.poleFreq(r1.a1, r1.a2, fs)) end
	if r2 then pairAt(M.poleFreq(r2.a1, r2.a2, fs)) end
	pairAt(fs / 2 - 1)
	if pf2 > 0 then
		local lo, hi = pf2 * 0.85, pf2 * 1.15
		for i = 0, 24 do pairAt(lo + (hi - lo) * i / 24) end
	end

	local k2 = 0
	if peak2 > 0 and peak2 == peak2 and peak2 ~= 1 / 0 and r2 then
		k2 = peak2
		local k = 10 ^ (-peak2 / 20)
		r2.b0, r2.b1, r2.b2 = r2.b0 * k, r2.b1 * k, r2.b2 * k
	end

	-- Now make sure the integers themselves fit. Section 1 first, because
	-- shrinking it lowers the cascade too and can only help section 2.
	local f1 = fitCoeffs(r1)
	local f2 = fitCoeffs(r2)
	k1, k2 = k1 + f1, k2 + f2

	-- Every quantisation in this function goes through the response-fitting
	-- quantiser; its own fallback carries the old plain-round + pole-repair path.
	local function finish(x)
		if not x then return M.FLAT end
		return fitQuantize(x, fs)
	end

	local q1, q2 = finish(r1), finish(r2)

	--[[
	NORMALISE THE REALISED RESPONSE, NOT THE IDEAL ONE.

	Everything above -- scaleTo0, the cascade peak, fitCoeffs -- works on the
	floating-point design. Quantising afterwards moves the response by up to a
	coefficient LSB, and for a low shelf near DC that is not small: measured
	+0.94 dB at bass +15. Two invariants were quietly broken by it:

	  * section 1's output is the INTERMEDIATE feeding biquad 2, and it must not
	    exceed unity -- the whole reason scaleTo0 exists;
	  * the pair's output must not exceed unity, or loud bass clips.

	Both were being guaranteed against a design that is not what the chip runs.
	This measures the QUANTISED sections and pulls them back down if they came
	out over the line, re-quantising until they are honestly under it. Anything
	it takes off is real level, so it is charged to attenDb like every other cut.

	Found by test_pairnorm.lua only after that file was rewritten to measure
	realised coefficients; the previous version compared ideal against ideal and
	passed 26/26 while both invariants were violated.
	]]
	--[[
	POST-QUANTISATION CORRECTION -- one bounded pass, and a hard safety net.

	Quantising moves the response by up to a coefficient LSB, so a design that was
	normalised to exactly 0 dB can land slightly above it. Measured +0.94 dB at
	bass +15 before this existed, which clips.

	This replaced a retry loop that iterated up to eight times per section and
	then again over the pair. That version was strictly worse than the bug: it
	reached 75 dB of attenuation on a 16 kHz treble shelf (inaudible) and left a
	NaN in N1 on a 4 kHz one (silent). Both shipped a dead band. A correction that
	can run away is more dangerous than the 0.94 dB it was correcting, so this one
	cannot iterate and cannot exceed a bounded amount.
	]]
	--[[
	The bound exists to stop a RUNAWAY, and a runaway needs iteration -- this is a
	single pass, so the cap can be generous without being able to compound. It was
	3 dB at first and that was too tight: a 80 Hz / +12 dB shelf needs about 6.7 dB
	of correction, so capping at 3 shipped the remaining 3.71 dB as clipping.

	Low shelves need the most because their poles sit closest to the unit circle,
	where 16-bit quantisation spoils the pole/zero cancellation worst -- the same
	reason the evaluation band stops at 40 Hz. Anything this removes is real level
	and is charged to attenDb, so the cost is visible as make-up rather than hidden
	as distortion.
	]]
	local MAX_CORRECTION_DB = 12.0

	-- Third return: the realised peak it measured, when that peak is still valid
	-- for the returned coefficients (i.e. nothing was shaved). diag below reuses
	-- it instead of paying for a second realisedPeakDb sweep on every knob click.
	local function correct(x, c, budget)
		if not x or not c then return c, 0, nil end
		local p = M.realisedPeakDb(c, fs)
		if p ~= p or p == 1 / 0 or p == -1 / 0 then return c, 0, nil end   -- non-finite
		if p <= 0 then return c, 0, p end
		if p > budget then p = budget end
		local k = 10 ^ (-p / 20)
		x.b0, x.b1, x.b2 = x.b0 * k, x.b1 * k, x.b2 * k
		return finish(x), p, nil
	end

	local t1, t2, pk1, pk2
	q1, t1, pk1 = correct(r1, q1, MAX_CORRECTION_DB)
	q2, t2, pk2 = correct(r2, q2, MAX_CORRECTION_DB)
	k1, k2 = k1 + t1, k2 + t2

	--[[
	SAFETY NET. clampInt is math.floor(v + 0.5) with two range comparisons, and
	every comparison against NaN is false -- so a NaN coefficient passes straight
	through it and gets written to the codec. A NaN in the numerator silences the
	whole cascade; a NaN in the denominator is worse.

	Nothing above should produce one any more, but "should" is what shipped the
	last two faults. Any section that is not entirely finite integers is replaced
	with FLAT, which is unity gain: the band does nothing, which is a visible
	disappointment rather than an inaudible or dangerous filter.
	]]
	local function sane(c)
		if not c then return M.FLAT, false end
		for _, k in ipairs({ "N0", "N1", "N2", "D1", "D2" }) do
			local v = c[k]
			if type(v) ~= "number" or v ~= v or v == 1 / 0 or v == -1 / 0
			   or v < M.INT_MIN or v > M.INT_MAX then
				return M.FLAT, true                      -- true = the net caught something
			end
		end
		return c, false
	end
	local caught1, caught2
	q1, caught1 = sane(q1)
	q2, caught2 = sane(q2)

	--[[
	DIAGNOSTICS for the caller to police.

	The shriek could not be explained after the fact because nothing recorded what
	was in the chip at the time -- by the time the coefficients were read they had
	been adjusted past. These are the quantities that decide whether a filter is
	dangerous, measured on the QUANTISED result, so the applet can log the moment
	a dangerous one is produced instead of reconstructing it later.

	No logging here: this module stays pure, and the decision about what is worth
	writing to syslog belongs where the volume and the user's settings are known.
	]]
	local function radiusOf(c)
		if not c then return 0, nil end
		local _, _, _, a1, a2 = M.dequantize(c)
		return M.poleRadius(a1, a2), M.poleFreq(a1, a2, fs)
	end
	--[[
	The pole FREQUENCY travels with its radius deliberately. A radius near 1 is
	normal and unavoidable for a low shelf -- a 100 Hz bass shelf sits at 0.998 --
	so radius alone cannot distinguish a working bass band from a screaming treble
	one. It is a near-unity pole HIGH IN THE BAND that rings audibly, and only the
	pair of numbers says which is which.
	]]
	local rr1, pf1 = radiusOf(q1)
	local rr2, pf2b = radiusOf(q2)
	-- FLAT's response is frequency-independent: 20*log10(32767/32768). Sections
	-- that are FLAT (0 dB band, or the safety net fired) get the constant rather
	-- than a 100-evaluation peak sweep for a known answer.
	local FLAT_PEAK_DB = 20 * log10(32767 / 32768)
	local function peakFor(x, c, cached, caught)
		if caught or not x then return FLAT_PEAK_DB end
		if cached then return cached end
		return M.realisedPeakDb(c, fs)
	end
	local diag = {
		peak1  = peakFor(r1, q1, pk1, caught1),   -- realised dB, pole-aware
		peak2  = peakFor(r2, q2, pk2, caught2),
		r1     = rr1,  pf1 = pf1,            -- pole radius and where it sits
		r2     = rr2,  pf2 = pf2b,
		flat1  = caught1,                    -- the non-finite net fired
		flat2  = caught2,
	}

	--[[
	A pure cut must cost nothing. Quantisation ripple can leave a hair of
	positive peak on a cut-only design (measured 0.11 dB), and charging make-up
	for a cut would raise the volume when the user asked for less. Round it away
	rather than bill it.
	]]
	local atten = k1 + k2
	if atten < 0.25 and atten > 0 then atten = 0 end

	--[[
	THE DRAWN CURVE IS THE REALISED FILTER. realised1/realised2 are float views of the
	integers that go to the codec -- dequantized q1/q2 -- so anything plotted from
	them is, by construction, what the chip does (test_graphtruth.lua is the
	specification). They are NOT the unquantised request: at low bass corners no
	drawable request exists that the chip can honour to better than ~1 dB (the
	representability floor measured at fitQuantize above), so drawing the request
	would re-create the graph-vs-sound lie this module was caught telling once
	already. fitQuantize keeps the realised sections as close to the request as
	the format allows; whatever gap remains is real and belongs on screen.
	]]
	local function view(c)
		if not c then return nil end
		local b0, b1, b2, a1, a2 = M.dequantize(c)
		return { b0 = b0, b1 = b1, b2 = b2, a1 = a1, a2 = a2 }
	end

	return q1, q2,
	       { attenDb = atten, k1 = k1, k2 = k2,
	         realised1 = view(q1), realised2 = view(q2), ok = true,
	         diag = diag }
end

-- amixer wants the unsigned 16-bit form.
function M.toAmixer(c)
	local function u(v) if v < 0 then return v + 65536 end return v end
	return { N0 = u(c.N0), N1 = u(c.N1), N2 = u(c.N2), D1 = u(c.D1), D2 = u(c.D2) }
end

-- Headroom available for BOOST at the current player volume, from the
-- SqueezePlay volume curve (totalVolumeRange -74 dB, stepPoint 25,
-- stepFraction 0.5). Volume is applied in software upstream of the codec
-- (decode_alsa_backend.c multiplies lgain into every sample), so the
-- attenuation IS the headroom. At volume 100 it is exactly zero.
function M.volumeToDb(v)
	if v <= 25 then return 1.48 * v - 74 end
	return (37 / 75) * (v - 100)
end

-- Inverse of volumeToDb, clamped to the control's range.
function M.dbToVolume(db)
	local v
	if db <= -37 then v = (db + 74) / 1.48 else v = db / (37 / 75) + 100 end
	v = math.floor(v + 0.5)
	if v < 0 then v = 0 end
	if v > 100 then v = 100 end
	return v
end

function M.headroomDb(v)
	return -M.volumeToDb(v)
end

return M
