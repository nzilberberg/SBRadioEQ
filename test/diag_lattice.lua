--[[
cd /tmp && jive diag_lattice

The bass response jumps up to 5.60 dB at 60 Hz on one 4% frequency click.

Research says why: in a direct-form biquad the poles are most sensitive to
coefficient quantisation at angles near ZERO -- low frequency -- and the standard
cure is a coupled / Gold-Rader topology. That is a different filter STRUCTURE,
fixed in the AIC3104's silicon, so it is not available.

What IS available is the choice of integers. So the question becomes: what can
the hardware actually resolve down there?

D1 and D2 are integers, so the poles can only land on a LATTICE. Between 100 and
800 Hz there is some finite number of distinct realisable filters, and the UI
currently offers ~53 frequency steps (4% each) regardless. Two very different
worlds:

  MANY distinct filters, SMALL gaps  -> our 4% stepping is landing badly and
                                        snapping the control to the lattice fixes it
  FEW distinct filters, BIG gaps     -> the hardware cannot sweep bass smoothly at
                                        all, and the honest fix is to say so in
                                        the control rather than pretend

This also separates two things the net-jump measurement conflated: does the
FILTER SHAPE jump, or does the MAKE-UP jump, or both?
]]

local D = require("eqdesign")
local FS = 44100

local function key(c) return c.N0 .. "," .. c.N1 .. "," .. c.N2 .. "," .. c.D1 .. "," .. c.D2 end

local function design(bf, bg, bq)
	local c1, _, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
	return c1, i.attenDb or 0
end

local function respAt(c, f)
	if not c then return 0 end
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	return D.responseDb(b0, b1, b2, a1, a2, f, FS)
end

local BG, BQ = 15, 2.0        -- the worst case found

print(string.format("Lowshelf, gain %+d, Q %.1f. Sweeping f0 by 1 Hz from 100 to 800.", BG, BQ))
print("")

local seen, order = {}, {}
for f = 100, 800 do
	local c, atten = design(f, BG, BQ)
	local k = key(c)
	if not seen[k] then
		seen[k] = { f0 = f, c = c, atten = atten, r60 = respAt(c, 60), r120 = respAt(c, 120) }
		order[#order + 1] = k
	end
end

print(string.format("distinct realisable filters between 100 and 800 Hz: %d", #order))
print(string.format("the UI offers about %d steps there (4%% each)",
	math.floor(math.log(800 / 100) / math.log(1.04) + 0.5)))
print("")

--[[
Gap between CONSECUTIVE DISTINCT filters -- the irreducible step size. If this is
small, our stepping is at fault and snapping helps. If it is large, the hardware
simply cannot do finer.
]]
local worstShape, worstAtten, worstNet = 0, 0, 0
local wsAt, wnAt = 0, 0
for i = 2, #order do
	local a, b = seen[order[i - 1]], seen[order[i]]
	local dShape = math.abs(b.r60 - a.r60)
	local dAtten = math.abs(b.atten - a.atten)
	local dNet   = math.abs((b.r60 + b.atten) - (a.r60 + a.atten))
	if dShape > worstShape then worstShape, wsAt = dShape, b.f0 end
	if dAtten > worstAtten then worstAtten = dAtten end
	if dNet > worstNet then worstNet, wnAt = dNet, b.f0 end
end

print("Between ADJACENT DISTINCT filters (the finest step the chip can take):")
print(string.format("  worst shape jump at 60 Hz : %6.2f dB  (near %d Hz)", worstShape, wsAt))
print(string.format("  worst make-up jump        : %6.2f dB", worstAtten))
print(string.format("  worst NET jump at 60 Hz   : %6.2f dB  (near %d Hz)", worstNet, wnAt))
print("")

-- Where does it become well behaved?
print("Distinct filters and worst NET jump, by octave:")
print("   range        distinct   worst net jump at 60 Hz")
for _, band in ipairs({ {100,150}, {150,200}, {200,300}, {300,400}, {400,600}, {600,800} }) do
	local lo, hi = band[1], band[2]
	local sub = {}
	for _, k in ipairs(order) do
		local e = seen[k]
		if e.f0 >= lo and e.f0 <= hi then sub[#sub + 1] = e end
	end
	local w = 0
	for i = 2, #sub do
		local d = math.abs((sub[i].r60 + sub[i].atten) - (sub[i-1].r60 + sub[i-1].atten))
		if d > w then w = d end
	end
	print(string.format("  %4d-%4d Hz   %6d       %6.2f dB %s",
		lo, hi, #sub, w, (w > 1.5) and "  <== coarse" or ""))
end

print("")
print("First 12 realisable corner frequencies from 100 Hz (what a snapped control")
print("would actually offer):")
local shown = 0
for _, k in ipairs(order) do
	local e = seen[k]
	if shown < 12 then
		print(string.format("   %4d Hz  ->  60Hz %+6.2f dB, make-up %5.2f, net %+6.2f",
			e.f0, e.r60, e.atten, e.r60 + e.atten))
		shown = shown + 1
	end
end
