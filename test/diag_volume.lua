local D = require("eqdesign")
local FS = 44100
local function atten(bg, tg)
	local _,_,i = D.designPair(FS,
		{kind="lowshelf",  f0=150,  gainDb=bg, shape=0.9},
		{kind="highshelf", f0=4000, gainDb=tg, shape=0.9})
	return i.attenDb
end
print("bass  treb   make-up   vol 20->   vol 30->   vol 50->")
for _,t in ipairs({ {0,0},{6,0},{12,0},{15,0},{0,12},{6,12},{12,6},{12,12},{15,15},{-12,0},{-12,-6},{12,-6} }) do
	local a = atten(t[1], t[2])
	local function moved(v) return D.dbToVolume(D.volumeToDb(v) + a) end
	print(string.format("%+4d  %+4d   %6.1f dB   %3d        %3d        %3d",
		t[1], t[2], a, moved(20), moved(30), moved(50)))
end