--[[
SBRadioEQ -- test_powerprec.lua        cd /tmp && jive test_powerprec

⚠️ THIS PLATFORM'S `^` DOES NOT FOLLOW LUA PRECEDENCE.

Measured on the device (2026-08-02), SqueezePlay's Lua 5.1:

    expression     here    stock Lua 5.1
    2*3^2            36    18
    -3^2              9    -9
    2^2^3            64    256
    2^3*2            64    16
    100*1.04^3  1124864    112.4864

`^` binds LOWER than `*`, `/` and unary minus, and associates LEFT. So
`100*1.04^3` evaluates as `(100*1.04)^3` -- wrong by four orders of magnitude,
with no error and no warning.

This is not theoretical. It silently corrupted a frequency sweep during this
project (`100*1.04^k` became `104^k`), producing a whole run of plausible-looking
numbers that were garbage.

Every arithmetic `^` in this project is currently written safely, but by
convention only. One unparenthesised power added later would be wrong and would
look right. Hence this gate.

THE RULE: an arithmetic power must be unambiguous under BOTH precedences. Two
ways to satisfy it:
  1. wrap the whole power  ->  v * (1.04 ^ delta)
  2. be the entire right-hand side, base and parenthesised exponent, nothing
     else at that level  ->  local k = 10 ^ (-peak / 20)

String patterns like "^local BUILD" are not arithmetic and are ignored.
]]

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-48s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-48s %s", name, detail or "")) end
end

--[[
Strip what is not code: line comments, block comments, and string literals --
the last of these matters because Lua patterns use ^ constantly and none of it
is arithmetic.
]]
local function stripNonCode(src)
	src = src:gsub("%-%-%[%[.-%]%]", " ")          -- block comments
	local out = {}
	for line in (src .. "\n"):gmatch("(.-)\n") do
		line = line:gsub("%-%-.*$", "")            -- line comment
		line = line:gsub('"[^"]*"', '""')          -- double-quoted strings
		line = line:gsub("'[^']*'", "''")          -- single-quoted strings
		out[#out + 1] = line
	end
	return out
end

--[[
Is this occurrence of ^ safe under either precedence?

Safe form 1: the power sits inside its own parentheses, with nothing else in
             them at the top level -- "( base ^ exponent )".
Safe form 2: the power is the complete RHS of an assignment or return, as
             "base ^ (exponent)" with no other operator outside the exponent.
]]
local function safeOccurrence(line)
	-- form 2: RHS is exactly  <base> ^ (<anything>)
	local rhs = line:match("=%s*(.-)%s*$") or line:match("return%s+(.-)%s*$")
	if rhs then
		local base, rest = rhs:match("^([%w_%.]+)%s*%^%s*(%b())$")
		if base and rest then return true end
	end
	-- form 1: every ^ appears inside a parenthesised group of the form (a ^ b)
	local n = 0
	for _ in line:gmatch("%^") do n = n + 1 end
	local wrapped = 0
	for grp in line:gmatch("%b()") do
		if grp:match("^%(%s*[%w_%.]+%s*%^%s*[%w_%.]+%s*%)$")
		   or grp:match("^%(%s*[%w_%.]+%s*%^%s*%b()%s*%)$") then
			wrapped = wrapped + 1
		end
	end
	return wrapped >= n
end

local function scan(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. path end
	local src = fh:read("*a"); fh:close()
	local bad = {}
	local lines = stripNonCode(src)
	for i, line in ipairs(lines) do
		if line:find("%^") then
			if not safeOccurrence(line) then
				bad[#bad + 1] = string.format("%s:%d  %s", path:match("[^/]+$"), i,
				                              (line:gsub("^%s+", "")))
			end
		end
	end
	return bad
end

print("=== the platform really does have non-standard ^ precedence ===")
do
	--[[
	Assert the trap EXISTS. If a future firmware fixes the precedence this fires,
	which is the correct outcome: the rule below could then be relaxed, but only
	deliberately, not by silent drift.
	]]
	ok("2*3^2 evaluates as (2*3)^2", 2 * 3 ^ 2 == 36, tostring(2 * 3 ^ 2) .. " (stock Lua gives 18)")
	ok("-3^2 evaluates as (-3)^2",   -3 ^ 2 == 9,     tostring(-3 ^ 2)   .. " (stock Lua gives -9)")
	ok("^ associates LEFT",          2 ^ 2 ^ 3 == 64, tostring(2 ^ 2 ^ 3) .. " (stock Lua gives 256)")
end

print("=== the checker flags unsafe powers (negative control) ===")
do
	local FIX = "/tmp/fixture_power.lua"
	local fh = io.open(FIX, "w")
	if fh then
		fh:write("local f = 100 * 1.04 ^ k\n")          -- the bug that actually happened
		fh:write("local a = -x ^ 2\n")                   -- unary minus
		fh:write("local b = 2 ^ n * 3\n")                -- operator after
		fh:write("local ok1 = 10 ^ (gain / 40)\n")       -- safe form 2
		fh:write("local ok2 = v * (1.04 ^ d)\n")         -- safe form 1
		fh:write('local ok3 = s:match("^local BUILD")\n')-- a pattern, not arithmetic
		fh:close()
	end
	local bad = scan(FIX)
	if not bad then
		ok("fixture readable", false, "could not write it")
	else
		ok("catches 100 * 1.04 ^ k", #bad >= 1 and (bad[1] or ""):find("1%.04") ~= nil,
		   bad[1] or "MISSED")
		ok("catches all three unsafe forms", #bad == 3,
		   string.format("%d flagged: %s", #bad, table.concat(bad, " | ")))
		local safeFlagged = false
		for _, b in ipairs(bad) do
			if b:find("ok1") or b:find("ok2") or b:find("ok3") then safeFlagged = true end
		end
		ok("does NOT flag the safe forms or string patterns", not safeFlagged,
		   safeFlagged and "false positive" or "10^(...), v*(1.04^d) and \"^local\" all accepted")
	end
end

print("=== the real project code is clean ===")
do
	local files = {
		"/usr/share/jive/applets/SBRadioEQ/eqdesign.lua",
		"/usr/share/jive/applets/SBRadioEQ/eqapply.lua",
		"/usr/share/jive/applets/SBRadioEQ/uistate.lua",
		"/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua",
	}
	local all, missing = {}, {}
	for _, f in ipairs(files) do
		local bad, err = scan(f)
		if not bad then missing[#missing + 1] = err
		else for _, b in ipairs(bad) do all[#all + 1] = b end end
	end
	ok("all source files were readable", #missing == 0, table.concat(missing, "; "))
	ok("no ambiguous power expressions", #all == 0,
	   #all > 0 and table.concat(all, " | ") or (#files .. " files clean"))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
