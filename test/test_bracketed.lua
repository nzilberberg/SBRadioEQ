--[[
SBRadioEQ -- test_bracketed.lua        cd /tmp && jive test_bracketed

THE GATE. No coefficient may be written to a RUNNING filter.

On 2026-08-01 the enable bracket was removed from the muted write path to save
2 of 9 setMixer calls (~6 ms). The device answered with a half-second
high-pitched shriek during a bass adjustment. Two prior measurements had cleared
the change, and both asked a question that cannot detect this:

  * "0 of 418 intermediates unstable" -- stability is not audibility. A pole at
    r = 0.9999 is inside the unit circle and rings for 225 ms.
  * diag_intermediate.lua compared responses at 8 fixed frequencies. A narrow
    high-Q resonance sits between grid points and scores as benign.

Any future argument for removing the bracket will be some third clever
measurement. So this gate does not evaluate arguments, and does not model audio
at all. It checks one structural property of the emitted write sequence:

    between an enable=BYPASS and the following enable=ENABLE, and nowhere else,
    is where coefficient writes are allowed to be.

If that holds, no intermediate coefficient state is ever running, so none of them
can be excited, so none of them can ring -- whatever their poles do. The property
is cheap, total, and immune to being out-argued.
]]

local A = require("eqapply")
local D = require("eqdesign")
local FS = 44100

local pass, fail = 0, 0
local function ok(name, cond, detail)
	if cond then pass = pass + 1; print(string.format("  ok   %-52s %s", name, detail or ""))
	else fail = fail + 1; print(string.format("  FAIL %-52s %s", name, detail or "")) end
end

local function stub()
	local s = { seq = {} }
	function s:setMixer(name, a, b) s.seq[#s.seq + 1] = { name = name, a = a } end
	return s
end

-- Every control that carries a filter coefficient.
local COEFF = {}
for _, band in ipairs({ A.NAME.band1, A.NAME.band2 }) do
	for _, n in pairs(band) do COEFF[n] = true end
end

--[[
Walk a write sequence and report every coefficient written while the filter was
running. The filter is assumed RUNNING at the start -- that is the normal state
of a device in use, and assuming otherwise would let a sequence pass by relying
on a bypass that some earlier call happened to leave behind.
]]
local function violations(seq)
	local running, bad = true, {}
	for i, e in ipairs(seq) do
		if e.name == A.NAME.enable then
			running = (e.a ~= A.BYPASS)
		elseif COEFF[e.name] and running then
			bad[#bad + 1] = string.format("#%d %s", i, e.name)
		end
	end
	return bad
end

--[[
NEGATIVE CONTROL -- the gate must actually bite.

A gate that cannot fail is not a gate. This is the exact shape of the change that
caused the shriek: the same coefficient writes, with the bracket taken away.
]]
print("=== the checker detects an unbracketed write (negative control) ===")
do
	local unbracketed = {
		{ name = A.NAME.band1.N0, a = 1 },
		{ name = A.NAME.band1.D1, a = 2 },
	}
	local v = violations(unbracketed)
	ok("unbracketed writes are reported", #v == 2, table.concat(v, ", "))

	-- and the subtler one: bracket opened, then closed EARLY, rest written live
	local early = {
		{ name = A.NAME.enable,    a = A.BYPASS },
		{ name = A.NAME.band1.N0,  a = 1 },
		{ name = A.NAME.enable,    a = A.ENABLE_BOTH },
		{ name = A.NAME.band1.D1,  a = 2 },
	}
	v = violations(early)
	ok("a bracket closed too early is reported", #v == 1, table.concat(v, ", "))

	-- and a sequence that only looks safe because something else bypassed first
	local presumed = { { name = A.NAME.band1.N0, a = 1 }, { name = A.NAME.enable, a = A.BYPASS } }
	v = violations(presumed)
	ok("a write before its own bypass is reported", #v == 1, table.concat(v, ", "))
end

print("=== a correctly bracketed sequence passes ===")
do
	local good = {
		{ name = A.NAME.enable,   a = A.BYPASS },
		{ name = A.NAME.band1.N0, a = 1 },
		{ name = A.NAME.band2.D2, a = 2 },
		{ name = A.NAME.enable,   a = A.ENABLE_BOTH },
	}
	ok("no violations", #violations(good) == 0, "")
end

--[[
THE REAL ARTIFACT -- applyBSPMuted is what the applet calls on every knob click.
Swept across the control surface, including the transitions that have their own
code paths: first write with no history, entering and leaving bypass, and a
no-op.
]]
local function pairAt(bg, bf, bs, tg, tf, ts)
	return D.designPair(FS,
		{ kind = "lowshelf",  f0 = bf, gainDb = bg, shape = bs },
		{ kind = "highshelf", f0 = tf, gainDb = tg, shape = ts })
end

print("=== applyBSPMuted brackets every write, across the control surface ===")
do
	local checked, offenders = 0, {}
	for _, bf in ipairs({ 80, 266, 800 }) do
	for _, bs in ipairs({ 0.4, 2.0 }) do
	for _, tg in ipairs({ 0, 15 }) do
		local c1, c2 = pairAt(0, bf, bs, tg, 4000, 0.9)
		local prev = { c1 = c1, c2 = c2 }
		for g = 1.0, 15.0, 1.0 do
			local n1, n2 = pairAt(g, bf, bs, tg, 4000, 0.9)
			local b = stub()
			A.applyBSPMuted(b, n1, n2, prev, false, false)
			local v = violations(b.seq)
			if #v > 0 and #offenders < 4 then
				offenders[#offenders + 1] = string.format("bass %+.1f f0=%d S=%.1f: %s",
					g, bf, bs, table.concat(v, ","))
			end
			checked = checked + 1
			prev = { c1 = n1, c2 = n2 }
		end
	end end end
	ok("gain sweeps", #offenders == 0,
	   string.format("%d write sequences, %d violations %s", checked, #offenders,
	                 table.concat(offenders, " | ")))
end

print("=== the transitions with their own code paths ===")
do
	local c1, c2 = pairAt(9, 150, 0.9, 6, 4000, 0.9)
	local d1, d2 = pairAt(9.5, 150, 0.9, 6, 4000, 0.9)

	local b = stub()
	A.applyBSPMuted(b, c1, c2, nil, false, nil)
	ok("first write, no history", #violations(b.seq) == 0,
	   string.format("%d calls", #b.seq))

	b = stub()
	A.applyBSPMuted(b, c1, c2, { c1 = c1, c2 = c2 }, true, false)
	ok("entering bypass", #violations(b.seq) == 0, string.format("%d calls", #b.seq))

	b = stub()
	A.applyBSPMuted(b, d1, d2, { c1 = c1, c2 = c2 }, false, true)
	ok("leaving bypass", #violations(b.seq) == 0, string.format("%d calls", #b.seq))

	b = stub()
	A.applyBSPMuted(b, c1, c2, { c1 = c1, c2 = c2 }, false, false)
	ok("no-op writes nothing at all", #b.seq == 0, string.format("%d calls", #b.seq))
end

--[[
And the reason the bracket cannot be traded away for latency: the mute does not
substitute for it. Mute silences the filter's OUTPUT. Audio still flows into the
filter, so a running intermediate is still excited and still stores energy in the
delay elements -- which the restore then plays back. Muting hides the window; only
bypassing prevents the state.
]]
print("=== the mute does not stand in for the bracket ===")
do
	local c1, c2 = pairAt(9, 150, 0.9, 6, 4000, 0.9)
	local d1, d2 = pairAt(9.5, 150, 0.9, 6, 4000, 0.9)
	local b = stub()
	A.applyBSPMuted(b, d1, d2, { c1 = c1, c2 = c2 }, false, false)
	local muted, bypassed = false, false
	for _, e in ipairs(b.seq) do
		if e.name == A.MUTE_CTL and e.a == 0 then muted = true end
		if e.name == A.NAME.enable and e.a == A.BYPASS then bypassed = true end
	end
	ok("muted AND bypassed, not muted instead of bypassed", muted and bypassed,
	   string.format("muted=%s bypassed=%s", tostring(muted), tostring(bypassed)))
end

print("")
print(string.format("passed=%d failed=%d", pass, fail))
