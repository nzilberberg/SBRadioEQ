-- cd /tmp && jive diag_jump
-- The 17.5 dB lurch is between f0=59 and f0=62 on a +12 dB lowshelf, seen at
-- 20 Hz. Print everything about each design across that step instead of theorising.
local D = require("eqdesign")
local FS = 44100

print("  f0   ok  reason            shape  atten   poleR    N0     N1     N2     D1     D2")
for _, f0 in ipairs({ 55, 57, 59, 60, 61, 62, 64, 66 }) do
	local c, i = D.design("lowshelf", FS, f0, 12, 0.9)
	print(string.format("%4d  %-5s %-16s %.2f  %5.2f  %.5f  %6d %6d %6d %6d %6d",
		f0, tostring(i.ok), tostring(i.reason), i.shape or -1, i.attenDb or -1,
		i.poleR or -1, c.N0, c.N1, c.N2, c.D1, c.D2))
end

print("")
print("  f0     20Hz    50Hz   200Hz    1kHz    5kHz   20kHz")
for _, f0 in ipairs({ 55, 57, 59, 60, 61, 62, 64, 66 }) do
	local c = D.design("lowshelf", FS, f0, 12, 0.9)
	local b0, b1, b2, a1, a2 = D.dequantize(c)
	local row = string.format("%4d", f0)
	for _, f in ipairs({ 20, 50, 200, 1000, 5000, 20000 }) do
		row = row .. string.format("  %6.2f", D.responseDb(b0, b1, b2, a1, a2, f, FS))
	end
	print(row)
end

print("")
print("Is FLAT being returned anywhere above?  FLAT is N0=32767, rest 0.")
print("What is the design grid's lowest frequency?  GRID[1] =", D.GRID and D.GRID[1] or "n/a")
