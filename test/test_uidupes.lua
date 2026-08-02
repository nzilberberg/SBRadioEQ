--[[
SBRadioEQ -- test_uidupes.lua          cd /tmp && jive test_uidupes

THE GATE. Two versions of the same on-screen string may not coexist.

Porting the screen to the native skin replaced part of _redraw, and the OLD
status-bar draw survived below the new one. The device then painted both, one
over the other:

    turn: select   press: edit   hold: bypass     <- new
    turn:select  press:edit  hold:byp             <- old, still drawing

Every static check passed. It parses, the globals lint is clean, the surface
lint is clean, no constant is orphaned -- because nothing is wrong with either
line in isolation. The defect only exists on glass, and it took a photo to find.

But the two strings betray themselves without rendering anything. Normalise away
case, spaces and punctuation and:

  * the EDITING pair collapses to the same token exactly:
      "turnadjustpressokbackcancel" == "turnadjustpressokbackcancel"
  * the SELECT pair becomes a prefix of the other:
      "turnselectpresseditholdbyp" ⊂ "turnselectpresseditholdbypass"

So: no two DISTINCT literals in the applet may normalise to the same string, and
none may be a prefix of another once they are long enough for that to be
meaningful. That is cheap, needs no renderer, and catches a stale copy of any
label -- not just this one.

This does not replace looking at the screen. It closes the specific hole where a
leftover draw is invisible to every check we have.
]]

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-50s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-50s %s", name, detail or "")) end
end

-- Long enough that a prefix relation means something. "TREB Q" and "TREB Hz"
-- must not trip it; a whole status line must.
local MIN_LEN = 12

local function normalise(s)
	return (s:lower():gsub("[^%a%d]", ""))
end

--[[
Collect double-quoted literals. Lua patterns cannot express "quoted string with
escapes", so escaped quotes are handled by walking the line. Format specifiers
are skipped: "%.0f/%.0f" carries no words and would only add noise.
]]
local function literals(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. path end
	local out, seen = {}, {}
	local lineNo = 0
	for line in fh:lines() do
		lineNo = lineNo + 1
		-- ignore comment-only lines so prose cannot masquerade as UI text
		if not line:match("^%s*%-%-") then
			for lit in line:gmatch('"([^"\\]*)"') do
				local n = normalise(lit)
				if #n >= MIN_LEN and not lit:match("^%%") then
					if not seen[lit] then
						seen[lit] = true
						out[#out + 1] = { raw = lit, norm = n, line = lineNo }
					end
				end
			end
		end
	end
	fh:close()
	return out
end

-- Return a list of human-readable collisions.
local function collisions(lits)
	local bad = {}
	for i = 1, #lits do
		for j = i + 1, #lits do
			local a, b = lits[i], lits[j]
			if a.norm == b.norm then
				bad[#bad + 1] = string.format(
					'identical after normalising (lines %d, %d): "%s" / "%s"',
					a.line, b.line, a.raw, b.raw)
			else
				local short, long = a, b
				if #a.norm > #b.norm then short, long = b, a end
				if long.norm:sub(1, #short.norm) == short.norm then
					bad[#bad + 1] = string.format(
						'one is a prefix of the other (lines %d, %d): "%s" / "%s"',
						a.line, b.line, a.raw, b.raw)
				end
			end
		end
	end
	return bad
end

--[[
NEGATIVE CONTROL, generated here so it cannot go missing when /tmp is cleared --
that already silently disarmed test_globals once. This is the exact pair of
lines that shipped.
]]
local FIX = "/tmp/fixture_dupeui.lua"
do
	local fh = io.open(FIX, "w")
	if fh then
		fh:write([[
function _redraw(self, srf)
	text(srf, self.fontXS, C_DIM,
	     self.editing and "turn: adjust   press: ok   back: cancel"
	                   or "turn: select   press: edit   hold: bypass",
	     PAD, sh - STATUS_H + 5)

	text(srf, self.fontS, C_OFF,
	     self.editing and "turn:adjust  press:ok  back:cancel"
	                   or "turn:select  press:edit  hold:byp", 6, sh - 12)
end
]])
		fh:close()
	end
end

print("=== the gate FIRES on the pair that actually shipped ===")
local sawIdentical, sawPrefix = false, false
do
	local lits, err = literals(FIX)
	if not lits then
		ok("fixture readable", false, tostring(err))
	else
		local bad = collisions(lits)
		for _, b in ipairs(bad) do
			if b:match("^identical") then sawIdentical = true end
			if b:match("^one is a prefix") then sawPrefix = true end
		end
		ok("the editing pair is caught as identical", sawIdentical,
		   sawIdentical and "turn:adjust... == turn: adjust..." or "MISSED")
		ok("the select pair is caught as a prefix", sawPrefix,
		   sawPrefix and "...holdbyp is a prefix of ...holdbypass" or "MISSED")
	end
end

--[[
HARD assertion, deliberately not a soft ok(): if the detector ever stops
detecting, this file must ABORT rather than go on to report a comfortable pass
on the real applet. A clean result is only meaningful once the negative control
has proved the check can fire at all -- a gate whose proof-of-biting has quietly
broken is worse than no gate, because it reads as evidence.
]]
assert(sawIdentical and sawPrefix,
       "negative control did not fire: this test can no longer fail, so a pass from it means nothing")

print("=== the real applet is clean ===")
do
	local lits, err = literals("/usr/share/jive/applets/SBRadioEQ/SBRadioEQApplet.lua")
	if not lits then
		ok("applet readable", false, tostring(err))
	else
		local bad = collisions(lits)
		ok("no duplicated on-screen strings", #bad == 0,
		   #bad > 0 and table.concat(bad, " | ") or
		   string.format("%d distinct UI strings, no collisions", #lits))
	end
end

print("=== short labels must NOT be flagged (false-positive check) ===")
do
	--[[
	Without a length floor this would flag "TREB Q" against "TREB Hz" and the
	gate would be turned off within a day. Prove the floor holds on the labels
	the screen actually uses.
	]]
	local shorts = { "BASS Hz", "BASS dB", "BASS Q", "TREB Hz", "TREB dB", "TREB Q", "Equalizer", "BYP" }
	local kept = 0
	for _, sIt in ipairs(shorts) do
		if #normalise(sIt) >= MIN_LEN then kept = kept + 1 end
	end
	ok("the cell labels are below the length floor", kept == 0,
	   string.format("%d of %d would have been compared", kept, #shorts))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
