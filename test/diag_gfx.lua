--[[
cd /tmp && jive diag_gfx

Probe the graphics capabilities the native-skin port needs. A previous version of
this file SEGFAULTED -- the `jive <module>` bench runs the real interpreter but
without the video surface the UI would normally have set up, so some Surface
calls take the process down rather than raising a Lua error.

Markers go to stderr, which is unbuffered, so the last line printed is the call
that died. pcall does NOT protect against a segfault; only the marker does.
]]

local function mark(s) io.stderr:write("[" .. s .. "]\n") end

mark("start")

local Font = require("jive.ui.Font")
mark("Font required")

print("=== Font ===")
local f = Font:load("fonts/FreeSans.ttf", 12)
mark("FreeSans loaded")
local okB, fb = pcall(function() return Font:load("fonts/FreeSansBold.ttf", 13) end)
print("  FreeSansBold loads: " .. tostring(okB))
mark("FreeSansBold attempted")

for _, m in ipairs({ "width", "getSize", "height", "ascend", "capHeight" }) do
	print(string.format("  Font.%-10s : %s", m, type(f[m])))
end
if type(f.width) == "function" then
	local okW, w = pcall(function() return f:width("NO HEADROOM") end)
	print("  width('NO HEADROOM') = " .. tostring(okW and w or "call failed"))
end
if type(f.height) == "function" then
	local okH, h = pcall(function() return f:height() end)
	print("  height() = " .. tostring(okH and h or "call failed"))
end
mark("font metrics done")

local Surface = require("jive.ui.Surface")
mark("Surface required")

print("=== Surface methods present ===")
do
	local names = {}
	for k, v in pairs(Surface) do if type(v) == "function" then names[#names+1] = k end end
	table.sort(names)
	print("  " .. table.concat(names, ", "))
end
mark("surface methods listed")

print("=== loadImage ===")
local WALL = "applets/SetupWallpaper/wallpaper/bb_encore.png"
local okI, img = pcall(function() return Surface:loadImage(WALL) end)
mark("loadImage returned")
if okI and img then
	local okS, w, h = pcall(function() return img:getSize() end)
	mark("getSize returned")
	if okS then
		print(string.format("  %s -> %dx%d", WALL, w, h))
		print("  covers 320x240: " .. ((w >= 320 and h >= 240) and "YES" or "NO, needs scaling"))
	else
		print("  getSize failed")
	end
else
	print("  loadImage failed: " .. tostring(img))
end

mark("done -- newRGBA/getPixel deliberately NOT called; that is the suspect")
print("")
print("Alpha blending is NOT probed here: it needs a real drawing surface, and")
print("creating one off-screen in this bench is what crashed. It will be judged")
print("on the device instead.")
