--[[
cd /tmp && jive diag_netlurch

Make-up volume was measured jumping up to 5.48 dB between ADJACENT bass frequency
settings -- one knob click, about eleven volume steps.

That number on its own does not say whether anything is wrong. Make-up exists to
CANCEL the filter's own level change. If the realised filter really did drop
5.48 dB at that step, then moving the volume 5.48 dB is exactly right and the
listener hears nothing at all. The make-up jumping is only a problem if it is
NOT matched by the filter.

So measure the NET: realised filter response plus the make-up applied, at several
frequencies, across adjacent settings. That is what reaches the ear.

  net jump small  -> the compensation works; the visible volume number moves but
                     the sound is steady. A cosmetic oddity at worst.
  net jump large  -> the loudness genuinely lurches on one click. A real defect.
]]

local D = require("eqdesign")
local FS = 44100

local function design(bf, bg, bq)
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 })
	return c1, c2, i.attenDb or 0
end

local function respAt(c1, c2, f)
	local v = 0
	if c1 then local b0,b1,b2,a1,a2 = D.dequantize(c1); v = v + D.responseDb(b0,b1,b2,a1,a2,f,FS) end
	if c2 then local b0,b1,b2,a1,a2 = D.dequantize(c2); v = v + D.responseDb(b0,b1,b2,a1,a2,f,FS) end
	return v
end

-- Frequencies a listener actually has content at. 900 Hz is the reference the
-- make-up is supposed to hold steady; the others are where bass content lives.
local PROBE = { 60, 80, 120, 200, 400, 900, 3000 }

local function sweep(bg, bq)
	local prevNet, prevAtten = nil, nil
	local worstNet, worstNetAt, worstNetF = 0, 0, 0
	local worstAtten, worstAttenAt = 0, 0
	local f = 100
	while f <= 800 do
		local bf = math.floor(f + 0.5)
		local c1, c2, atten = design(bf, bg, bq)
		local net = {}
		for i, pf in ipairs(PROBE) do net[i] = respAt(c1, c2, pf) + atten end

		if prevNet then
			if math.abs(atten - prevAtten) > worstAtten then
				worstAtten, worstAttenAt = math.abs(atten - prevAtten), bf
			end
			for i = 1, #PROBE do
				local d = math.abs(net[i] - prevNet[i])
				if d > worstNet then worstNet, worstNetAt, worstNetF = d, bf, PROBE[i] end
			end
		end
		prevNet, prevAtten = net, atten
		f = f * 1.04
	end
	return worstAtten, worstAttenAt, worstNet, worstNetAt, worstNetF
end

print("One knob click on bass frequency (4%). How much does the MAKE-UP move,")
print("and how much does the SOUND actually move once the make-up is applied?")
print("")
print("  gain   Q  | make-up jump  at Hz | NET jump  at Hz / probe")

local worstAllNet, worstAllDesc = 0, ""
for _, bg in ipairs({ 6, 12, 15 }) do
	for _, bq in ipairs({ 0.2, 0.9, 2.0 }) do
		local wa, waAt, wn, wnAt, wnF = sweep(bg, bq)
		if wn > worstAllNet then
			worstAllNet = wn
			worstAllDesc = string.format("bass %+d / Q%.1f near %d Hz, heard at %d Hz", bg, bq, wnAt, wnF)
		end
		print(string.format("  %+4d  %.1f  | %8.2f dB %5d  | %7.2f dB %5d / %d Hz %s",
			bg, bq, wa, waAt, wn, wnAt, wnF, (wn > 1.5) and "  <== AUDIBLE" or ""))
	end
end

print("")
print(string.format("worst NET jump on one click: %.2f dB  (%s)", worstAllNet, worstAllDesc))
print(string.format("a volume step is 0.49 dB, so that is %.1f steps of real loudness change",
	worstAllNet / 0.4933))
print("")
if worstAllNet < 1.0 then
	print("VERDICT: the make-up is doing its job. The volume NUMBER moves a lot, but")
	print("the sound does not. Cosmetic, not audible.")
else
	print("VERDICT: the loudness genuinely jumps on a single click. Real defect.")
end
