-- cd /tmp && jive diag_chip
-- Response of the coefficients ACTUALLY READ BACK FROM THE CHIP, not of the design.
local D = require("eqdesign")
local FS = 44100

local function show(label, c)
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	print(string.format("%s  N0=%d N1=%d N2=%d D1=%d D2=%d", label, c.N0, c.N1, c.N2, c.D1, c.D2))
	print(string.format("        b0=%.4f b1=%.4f b2=%.4f a1=%.4f a2=%.4f  poleR=%.5f",
	      b0, b1, b2, a1, a2, D.poleRadius(a1, a2)))
	local row = "        "
	for _, f in ipairs({ 50, 200, 1000, 4000, 12000 }) do
		row = row .. string.format("%6.0fHz:%8.2f ", f, D.responseDb(b0, b1, b2, a1, a2, f, FS))
	end
	print(row)
	-- clamp detector
	for k, v in pairs(c) do
		if v == 32767 or v == -32768 then
			print(string.format("        !! %s is AT THE CLAMP LIMIT (%d)", k, v))
		end
	end
end

-- read back from the device, byte-swap undone
local band1 = { N0 = 13095, N1 = -12693, N2 = 12321, D1 = 32136, D2 = -31532 }
local band2 = { N0 = 32767, N1 = -32768, N2 = 32572, D1 = 15152, D2 = -10394 }

print("=== WHAT THE CHIP IS ACTUALLY RUNNING ===")
show("band1 (bass)  ", band1)
show("band2 (treble)", band2)

print("")
print("=== combined response ===")
local a0,a1,a2,a3,a4 = D.dequantize(band1)
local c0,c1,c2,c3,c4 = D.dequantize(band2)
for _, f in ipairs({ 50, 100, 200, 500, 1000, 2000, 4000, 8000, 12000 }) do
	print(string.format("%7.0f Hz   %8.2f dB", f,
		D.responseDb(a0,a1,a2,a3,a4,f,FS) + D.responseDb(c0,c1,c2,c3,c4,f,FS)))
end

print("")
print("=== what the DESIGN for bass+8 / treble+9 should have been ===")
local d1, d2, i = D.designPair(FS,
	{ kind = "lowshelf",  f0 = 266,  gainDb = 8, shape = 1.2  },
	{ kind = "highshelf", f0 = 4384, gainDb = 9, shape = 0.95 })
show("design band1  ", d1)
show("design band2  ", d2)
print(string.format("        attenDb=%.2f", i.attenDb))
