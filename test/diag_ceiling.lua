local D = require("eqdesign")
local FS = 44100
local function mk(bg,tg)
  local _,_,i = D.designPair(FS,
    {kind="lowshelf", f0=150, gainDb=bg, shape=0.9},
    {kind="highshelf",f0=4000,gainDb=tg, shape=0.9})
  return i.attenDb
end
print("setting                make-up   highest volume it still works at")
for _,t in ipairs({ {3,0},{6,0},{6,6},{12,0},{12,6},{12,12},{15,15} }) do
  local a = mk(t[1],t[2])
  -- volume where headroom just equals the make-up
  local vmax = 100
  for v = 100,1,-1 do if -D.volumeToDb(v) >= a then vmax = v break end end
  print(string.format("bass +%-2d treble +%-2d   %5.1f dB   volume %d", t[1], t[2], a, vmax))
end