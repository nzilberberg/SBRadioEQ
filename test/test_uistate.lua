--[[
SBRadioEQ -- test_uistate.lua          cd /tmp && jive test_uistate

The graph markers turn white when their band's cell is highlighted, so you can
see which dot the knob is about to move.

That rule existed before the native-skin port and the port silently dropped it.
Nothing caught it: the rule was a colour argument inside a filledCircle call, so
there was nothing to reference, nothing to import, and nothing a test could
observe. It came back only because the user noticed on the device.

Moving it into uistate.markerState is what makes it gateable at all -- the
behaviour is now a value a test can read rather than a pixel it cannot. These
assertions are the whole truth table, so the rule cannot be half-lost again.
]]

local U = require("uistate")

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-52s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-52s %s", name, detail or "")) end
end

local BASS, TREB = 1, 2

print("=== the highlighted band's marker is always 'selected' ===")
do
	--[[
	Every gain the band can be at, including zero: a band you are pointing at
	must read as selected even when it is doing nothing, because the dot is
	still the thing the knob will move.
	]]
	local gains = { -15, -6, 0, 0.5, 6, 15 }
	local wrong = {}
	for _, g in ipairs(gains) do
		if U.markerState(BASS, BASS, g) ~= "selected" then
			wrong[#wrong + 1] = string.format("bass gain %+g -> %s", g, U.markerState(BASS, BASS, g))
		end
		if U.markerState(TREB, TREB, g) ~= "selected" then
			wrong[#wrong + 1] = string.format("treb gain %+g -> %s", g, U.markerState(TREB, TREB, g))
		end
	end
	ok("selected at every gain, including zero", #wrong == 0,
	   #wrong > 0 and table.concat(wrong, " | ") or (#gains * 2) .. " combinations")
end

print("=== the OTHER band is never 'selected' ===")
do
	local wrong = {}
	for _, g in ipairs({ -15, 0, 15 }) do
		if U.markerState(BASS, TREB, g) == "selected" then
			wrong[#wrong + 1] = "treble marked selected while bass is highlighted"
		end
		if U.markerState(TREB, BASS, g) == "selected" then
			wrong[#wrong + 1] = "bass marked selected while treble is highlighted"
		end
	end
	ok("only the highlighted band lights up", #wrong == 0,
	   #wrong > 0 and table.concat(wrong, " | ") or "both directions checked")
end

print("=== an unhighlighted band reads 'active' or 'idle' by its gain ===")
do
	ok("bass boosted, treble highlighted -> active",
	   U.markerState(TREB, BASS, 9) == "active", U.markerState(TREB, BASS, 9))
	ok("bass cut, treble highlighted -> active",
	   U.markerState(TREB, BASS, -9) == "active", U.markerState(TREB, BASS, -9))
	ok("bass flat, treble highlighted -> idle",
	   U.markerState(TREB, BASS, 0) == "idle", U.markerState(TREB, BASS, 0))
	ok("treble flat, bass highlighted -> idle",
	   U.markerState(BASS, TREB, 0) == "idle", U.markerState(BASS, TREB, 0))
end

print("=== the full truth table, exhaustively ===")
do
	local expect = {
		-- selBand, band, gain, want
		{ BASS, BASS,   0, "selected" }, { BASS, BASS,  12, "selected" },
		{ BASS, TREB,   0, "idle"     }, { BASS, TREB,  12, "active"   },
		{ TREB, TREB,   0, "selected" }, { TREB, TREB, -12, "selected" },
		{ TREB, BASS,   0, "idle"     }, { TREB, BASS, -12, "active"   },
	}
	local bad = {}
	for _, e in ipairs(expect) do
		local got = U.markerState(e[1], e[2], e[3])
		if got ~= e[4] then
			bad[#bad + 1] = string.format("sel=%d band=%d gain=%+g: want %s got %s",
			                              e[1], e[2], e[3], e[4], got)
		end
	end
	ok("all 8 rows correct", #bad == 0,
	   #bad > 0 and table.concat(bad, " | ") or "8/8")
end

--[[
NEGATIVE CONTROL. The bug that shipped was the rule IGNORING which band is
highlighted -- colour chosen from gain alone. Reimplement exactly that and
require the table above to reject it. Without this, every assertion here could
be satisfied by an implementation that never lights anything white.
]]
print("=== the truth table REJECTS the implementation that shipped ===")
do
	local function dropped(selBand, band, gainDb)     -- the ported-away version
		if gainDb ~= 0 then return "active" end
		return "idle"
	end
	local caught = 0
	for _, e in ipairs({
		{ BASS, BASS, 0, "selected" }, { BASS, BASS, 12, "selected" },
		{ TREB, TREB, 0, "selected" }, { TREB, TREB, -12, "selected" },
	}) do
		if dropped(e[1], e[2], e[3]) ~= e[4] then caught = caught + 1 end
	end
	ok("the gain-only version fails on every selected row", caught == 4,
	   caught .. "/4 rows rejected")

	assert(caught == 4,
	       "negative control did not fire: this test would pass with the rule missing")
end

--[[
=============================================================================
Moving the highlight. A fast twist was skipping options, because the handler
applied the scroll event's raw delta and a quick turn delivers more than 1.
=============================================================================
]]
local N = 6

print("=== one scroll event moves exactly one cell, whatever its magnitude ===")
do
	local bad = {}
	for cell = 1, N do
		for _, d in ipairs({ 1, 2, 3, 4, 5, 9, 37 }) do
			local nxt = U.nextCell(cell, d, N)
			local want = (cell % N) + 1
			if nxt ~= want then
				bad[#bad + 1] = string.format("cell %d + %d -> %d (want %d)", cell, d, nxt, want)
			end
		end
	end
	ok("forwards, every cell and magnitude", #bad == 0,
	   #bad > 0 and table.concat(bad, " | ") or (N * 7) .. " combinations")

	bad = {}
	for cell = 1, N do
		for _, d in ipairs({ -1, -2, -3, -5, -9, -37 }) do
			local nxt = U.nextCell(cell, d, N)
			local want = ((cell - 2) % N) + 1
			if nxt ~= want then
				bad[#bad + 1] = string.format("cell %d + %d -> %d (want %d)", cell, d, nxt, want)
			end
		end
	end
	ok("backwards, every cell and magnitude", #bad == 0,
	   #bad > 0 and table.concat(bad, " | ") or (N * 6) .. " combinations")
end

print("=== no cell can ever be jumped over ===")
do
	--[[
	The property the user actually asked for, stated directly: from any cell,
	any single event lands on a NEIGHBOUR. Adjacency is checked on the ring, so
	the 6-to-1 and 1-to-6 wraps count as adjacent rather than as a five-cell
	skip.
	]]
	local function adjacent(a, b)
		return b == (a % N) + 1 or b == ((a - 2) % N) + 1 or b == a
	end
	local bad = {}
	for cell = 1, N do
		for d = -40, 40 do
			local nxt = U.nextCell(cell, d, N)
			if not adjacent(cell, nxt) then
				bad[#bad + 1] = string.format("cell %d + %d -> %d SKIPPED", cell, d, nxt)
			end
		end
	end
	ok("every delta from -40 to +40 lands on a neighbour", #bad == 0,
	   #bad > 0 and table.concat(bad, " | ") or (N * 81) .. " combinations")
end

print("=== zero does not move, and the ring wraps both ways ===")
do
	ok("delta 0 stays put", U.nextCell(3, 0, N) == 3, tostring(U.nextCell(3, 0, N)))
	ok("last wraps to first", U.nextCell(N, 5, N) == 1, tostring(U.nextCell(N, 5, N)))
	ok("first wraps to last", U.nextCell(1, -5, N) == N, tostring(U.nextCell(1, -5, N)))
end

--[[
NEGATIVE CONTROL: the expression that shipped, which applied the raw delta.
Without this, the adjacency property above could be satisfied by an
implementation that never moves at all.
]]
print("=== the adjacency property REJECTS the expression that shipped ===")
do
	local function raw(cell, delta, count)          -- the skipping version
		return ((cell - 1 + delta) % count) + 1
	end
	local function adjacent(a, b)
		return b == (a % N) + 1 or b == ((a - 2) % N) + 1 or b == a
	end
	local caught = 0
	for _, d in ipairs({ 2, 3, 4, -2, -3 }) do
		if not adjacent(1, raw(1, d, N)) then caught = caught + 1 end
	end
	ok("the raw-delta version skips on every multi-step", caught == 5,
	   caught .. "/5 deltas rejected")

	-- and it must reject a do-nothing implementation too, or "never skips" is
	-- trivially satisfiable
	local moved = U.nextCell(1, 1, N) ~= 1 and U.nextCell(1, -1, N) ~= 1
	ok("a do-nothing implementation would not pass", moved,
	   "single steps do move the highlight")

	assert(caught == 5 and moved,
	       "negative control did not fire: this test can no longer distinguish the bug")
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
