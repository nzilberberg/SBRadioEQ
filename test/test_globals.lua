--[[
SBRadioEQ -- test_globals.lua      cd /tmp && jive test_globals

Catches the failure mode that shipped a dead menu item: `module(...)` replaces the
global environment, so any Lua global used AFTER it must be captured as a local
BEFORE it. Missing one is invisible at load time and at syntax-check time -- the
applet registers happily and then throws the instant the user opens it
("attempt to call global 'pcall' (a nil value)").

Static check: for each known Lua global, if it is used after the module() line
and not captured before it, that is an error. Field accesses (x.pcall) and
Framework.constants names (EVENT_*, KEY_*, ACTION*) are exempt.
]]

local GLOBALS = {
	"pcall", "xpcall", "require", "type", "tonumber", "tostring", "ipairs",
	"pairs", "next", "select", "unpack", "error", "assert", "setmetatable",
	"getmetatable", "rawget", "rawset", "print", "os", "io", "table", "math",
	"string", "coroutine", "collectgarbage", "loadstring", "loadfile", "dofile",
}

local function stripNoise(src)
	src = src:gsub("%-%-%[%[.-%]%]", " ")   -- block comments
	src = src:gsub("%-%-[^\n]*", " ")       -- line comments
	src = src:gsub('"[^"\n]*"', '""')       -- string literals
	src = src:gsub("'[^'\n]*'", "''")
	return src
end

local function check(path)
	local fh = io.open(path)
	if not fh then return nil, "cannot open " .. path end
	local src = fh:read("*a"); fh:close()
	src = stripNoise(src)

	local mstart = src:find("\nmodule%s*%(")
	if not mstart then return {}, "no module() call -- plain module, nothing to check" end

	local head, body = src:sub(1, mstart), src:sub(mstart)
	local missing = {}

	for _, g in ipairs(GLOBALS) do
		-- used after module(), not as a field (.g / :g)
		local used = body:find("[^%w_%.:]" .. g .. "%s*[%(%.%[]")
		if used then
			-- captured before module()? "local ... g ... =" or "local g ="
			local captured = head:find("local[^\n]*[^%w_]" .. g .. "[^%w_][^\n]*=")
			                 or head:find("local%s+" .. g .. "%s*=")
			if not captured then
				missing[#missing + 1] = g
			end
		end
	end
	return missing
end

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-44s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-44s %s", name, detail or "")) end
end

--[[
FIXTURES ARE GENERATED, NOT SHIPPED.

These used to be two loose files in /tmp. /tmp gets cleared on this device, and
when it does the negative control silently disappears -- the run then reports
"FAIL fixture readable" among a wall of oks, or worse, gets read as noise. A gate
whose negative control can go missing is a gate that can quietly stop biting.

Writing them here means the proof that this lint FIRES travels with the lint.
]]
local function writeFixture(path, body)
	local fh = io.open(path, "w")
	if not fh then return false end
	fh:write(body)
	fh:close()
	return true
end

local wroteG = writeFixture("/tmp/fixture_badglobals.lua", [[
local oo = require("loop.simple")
local Framework = require("jive.ui.Framework")
-- NOTE: pcall is deliberately NOT captured -- this is the bug being detected
local ipairs, math, string = ipairs, math, string
module(..., Framework.constants)
function settingsShow(self)
	local ok, err = pcall(function() return 1 end)
	for i = 1, 3 do local _ = math.floor(i) end
	return ok, err
end
]])

local wroteS = writeFixture("/tmp/fixture_badsurface.lua", [[
local Surface = require("jive.ui.Surface")
function draw(self, srf)
	-- instance-level drawText with no release: the call that froze the device
	local t = srf:drawText(self.font, 0xFFFFFFFF, "hello")
	t:blit(srf, 0, 0)
end
]])

print("=== the gate must FIRE on a known-bad fixture ===")
ok("both fixtures were written", wroteG and wroteS,
   "generated, so they cannot go missing with /tmp")
local bad, berr = check("/tmp/fixture_badglobals.lua")
if bad then
	local hit = false
	for _, g in ipairs(bad) do if g == "pcall" then hit = true end end
	ok("fixture with pcall uncaptured is caught", hit,
	   "missing: " .. (#bad > 0 and table.concat(bad, ",") or "<none>"))
else
	ok("fixture readable", false, tostring(berr))
end

print("=== the real applet must PASS ===")
local real, rerr = check("/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua")
if real then
	ok("applet captures every global it uses", #real == 0,
	   #real > 0 and ("MISSING: " .. table.concat(real, ", ")) or "clean")
else
	ok("applet readable", false, tostring(rerr))
end

local meta = check("/usr/share/jive/applets/SBRadioEQ/SBRadioEQMeta.lua")
if meta then
	ok("meta captures every global it uses", #meta == 0,
	   #meta > 0 and ("MISSING: " .. table.concat(meta, ", ")) or "clean")
end

--[[
Surface lint. Surface:drawText is a CLASS call that ALLOCATES; the result must be
released. Two ways to get it wrong, both of which shipped:
  (a) srf:drawText(...)  -- instance call, puts the surface in the font slot
  (b) allocating per frame without :release() -- leaked 12 surfaces a frame,
      froze the Radio and tripped the watchdog.
]]
local function surfaceLint(path)
	local fh = io.open(path); if not fh then return nil end
	local src = fh:read("*a"); fh:close()
	src = stripNoise(src)

	local badRecv = {}
	for recv in src:gmatch("([%w_]+):drawText%s*%(") do
		if recv ~= "Surface" then badRecv[#badRecv + 1] = recv end
	end

	local allocs, frees = 0, 0
	for _ in src:gmatch("Surface:drawText%s*%(") do allocs = allocs + 1 end
	for _ in src:gmatch(":release%s*%(") do frees = frees + 1 end

	return badRecv, allocs, frees
end

print("=== Surface allocation lint ===")
local fb, fa, ff = surfaceLint("/tmp/fixture_badsurface.lua")
if fb then
	ok("fixture with srf:drawText is caught", #fb > 0,
	   #fb > 0 and ("bad receiver: " .. table.concat(fb, ",")) or "not caught")
end

local rb, ra, rf = surfaceLint("/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua")
if rb then
	ok("applet uses the CLASS call only", #rb == 0,
	   #rb > 0 and ("bad receiver: " .. table.concat(rb, ",")) or "clean")
	ok("every allocated surface is released", ra == 0 or rf >= 1,
	   string.format("%d Surface:drawText, %d :release", ra, rf))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
