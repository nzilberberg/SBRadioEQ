--[[
cd /tmp && jive diag_shriek

A half-second high-pitched shriek was heard on the device while adjusting bass
gain, immediately after the enable bracket was skipped on the muted write path.

Skipping the bracket means the chip RUNS each intermediate coefficient state
instead of sitting bypassed through them. applyBSPLive admits an intermediate
whenever its poles are inside the unit circle (MAX_R = 0.9999).

Two earlier measurements said this was safe. Both asked the wrong question:
  * "0 of 418 intermediates unstable" -- stability is not audibility. A pole at
    r = 0.9999 is stable and rings for 225 ms.
  * diag_intermediate.lua sampled 8 fixed frequencies (50 Hz .. 12 kHz). A narrow
    high-Q resonance falls between grid points and is scored as benign.

So: dense grid, peak search, and ring-down time, for every intermediate the chip
actually runs.
]]

local D = require("eqdesign")
local A = require("eqapply")
local FS = 44100

local function radiusOf(D1, D2)
	local a1, a2 = -2 * D1 / 32768, -D2 / 32768
	local disc = a1 * a1 - 4 * a2
	if disc >= 0 then
		local r = math.sqrt(disc)
		local x, y = math.abs((-a1 + r) / 2), math.abs((-a1 - r) / 2)
		return x > y and x or y
	end
	return math.sqrt(math.abs(a2))
end

-- peak response over a DENSE grid, and where it peaks
local function peakOf(c)
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	local best, bf = -1 / 0, 0
	local l0, l1 = math.log(20), math.log(20000)
	for i = 0, 1200 do
		local f = math.exp(l0 + (l1 - l0) * i / 1200)
		local v = D.responseDb(b0, b1, b2, a1, a2, f, FS)
		if v > best then best, bf = v, f end
	end
	return best, bf
end

local function ringMs(r)
	if r >= 1 then return 1 / 0 end
	if r <= 0 then return 0 end
	return -1000 / (FS * math.log(r))
end

local function bass(g, f0, s)
	return (D.designPair(FS,
		{ kind = "lowshelf",  f0 = f0,   gainDb = g, shape = s },
		{ kind = "highshelf", f0 = 4000, gainDb = 0, shape = 0.9 }))
end

print("Bass gain sweep, f0=150 S=0.9, one UI click (0.5 dB) per row.")
print("The intermediate is the state the chip RUNS when the bracket is skipped.")
print("")
print("  from     to    end r     int r    end pk   INT PK   int f     int ring")

local worst = { pk = -1 / 0 }
local prev = bass(0, 150, 0.9)
for g = 0.5, 15.0, 0.5 do
	local cur = bass(g, 150, 0.9)
	local ord = A.denomOrder(prev, cur)
	if ord and #ord == 2 then
		local mid = { N0 = cur.N0, N1 = cur.N1, N2 = cur.N2, D1 = prev.D1, D2 = prev.D2 }
		mid[ord[1]] = cur[ord[1]]
		local ir = radiusOf(mid.D1, mid.D2)
		local ipk, ifq = peakOf(mid)
		local epk = peakOf(cur)
		local er = radiusOf(cur.D1, cur.D2)
		if ipk > worst.pk then
			worst = { pk = ipk, f = ifq, r = ir, g = g, epk = epk }
		end
		print(string.format("%+6.1f %+6.1f  %8.5f  %8.5f  %+7.2f  %+7.2f  %7.0f  %7.0f ms%s",
			g - 0.5, g, er, ir, epk, ipk, ifq, ringMs(ir),
			(ipk > epk + 6) and "   <==" or ""))
	else
		print(string.format("%+6.1f %+6.1f  (one denominator write -- no intermediate)", g - 0.5, g))
	end
	prev = cur
end

print("")
print("Same question across the whole control surface:")
local gw = { pk = -1 / 0 }
for _, f0 in ipairs({ 80, 266, 800 }) do
for _, s in ipairs({ 0.4, 0.9, 2.0 }) do
	local p = bass(0, f0, s)
	for g = 1.0, 15.0, 1.0 do
		local c = bass(g, f0, s)
		local ord = A.denomOrder(p, c)
		if ord and #ord == 2 then
			local mid = { N0 = c.N0, N1 = c.N1, N2 = c.N2, D1 = p.D1, D2 = p.D2 }
			mid[ord[1]] = c[ord[1]]
			local ipk, ifq = peakOf(mid)
			local epk = peakOf(c)
			if ipk - epk > gw.pk then
				gw = { pk = ipk - epk, ipk = ipk, epk = epk, f = ifq,
				       r = radiusOf(mid.D1, mid.D2), f0 = f0, s = s, g = g }
			end
		end
		p = c
	end
end end

if gw.f then
	print(string.format("  worst OVERSHOOT: intermediate peaks %+.2f dB where the endpoint peaks %+.2f dB",
		gw.ipk, gw.epk))
	print(string.format("  that is %+.2f dB of gain the user never asked for, at %.0f Hz",
		gw.pk, gw.f))
	print(string.format("  reached at bass %+.1f dB, f0=%d, S=%.1f (pole r=%.5f, ring %.0f ms)",
		gw.g, gw.f0, gw.s, gw.r, ringMs(gw.r)))
end
print("")
print(string.format("MAX_R = 0.9999 admits a pole ringing for %.0f ms.", ringMs(0.9999)))
