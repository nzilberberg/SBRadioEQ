--[[
cd /tmp && jive diag_fingerprint

A fingerprint of what designPair PRODUCES, across the control surface.

The optimisations about to be made -- reusing a peak that was already computed,
and precomputing the trig that responseDb recalculates on every call -- are meant
to change the SPEED and nothing else. That claim is checkable exactly: run this
before and after and require the output to be identical, coefficient for
coefficient.

An optimisation that provably changes no output cannot re-arm the clipping bug,
which is the only real risk in touching this code. If a single digit moves, the
optimisation is wrong -- not "close enough".
]]

local D = require("eqdesign")
local FS = 44100

local BF = { 100, 150, 266, 400, 800 }
local TF = { 1000, 2500, 4000, 8000, 16000 }
local GG = { -15, -6, 0, 6, 15 }
local QQ = { 0.2, 0.9, 2.0 }

local n, sum = 0, 0
local lines = {}

for _, bf in ipairs(BF) do
for _, bg in ipairs(GG) do
for _, bq in ipairs(QQ) do
for _, tf in ipairs(TF) do
for _, tg in ipairs(GG) do
	local c1, c2, i = D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bq },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = 0.9 })
	n = n + 1
	-- a running checksum over every integer plus the make-up, to 4 decimals
	local function acc(v) sum = (sum * 31 + v) % 2147483647 end
	for _, k in ipairs({ "N0", "N1", "N2", "D1", "D2" }) do
		acc(c1 and c1[k] or 0)
		acc(c2 and c2[k] or 0)
	end
	acc(math.floor((i.attenDb or 0) * 10000 + 0.5))
	-- keep a few full rows so a mismatch can be localised, not just detected
	if n <= 6 or (n % 500 == 0) then
		lines[#lines + 1] = string.format(
			"  b%d/%+d/%.1f t%d/%+d : %d,%d,%d,%d,%d | %d,%d,%d,%d,%d | %.4f",
			bf, bg, bq, tf, tg,
			c1.N0, c1.N1, c1.N2, c1.D1, c1.D2,
			c2.N0, c2.N1, c2.N2, c2.D1, c2.D2,
			i.attenDb or 0)
	end
end end end end end

print(string.format("designs: %d", n))
print(string.format("CHECKSUM: %d", sum))
print("sample rows (for localising a mismatch):")
for _, l in ipairs(lines) do print(l) end
