--[[
cd /tmp && jive diag_where

designPair measures 149.6 ms. Before deciding that is a defect I introduced
today, find out where the time actually goes -- and specifically how much of it
is today's additions rather than the original design path.

Method: responseDb is the unit of cost (0.18 ms each, measured). Count the calls
by wrapping it, and isolate each stage by neutralising it and re-counting:

  * M.SUB_GRID = {}          removes the sub-40 Hz clip band (added today)
  * the diag block           two realisedPeakDb calls purely for instrumentation
  * the refinement windows   25 extra points per peak search (added today)

Everything here is counting, not timing, so it cannot be confounded by CPU load
or by a bad clock.
]]

local D = require("eqdesign")
local FS = 44100

local realResp = D.responseDb
local realPeak = D.realisedPeakDb
local nResp, nPeak = 0, 0

D.responseDb = function(...) nResp = nResp + 1; return realResp(...) end
D.realisedPeakDb = function(...) nPeak = nPeak + 1; return realPeak(...) end

local MSPER = 0.1815     -- measured cost of one responseDb, ms

local function run(label)
	nResp, nPeak = 0, 0
	D.designPair(FS,
		{ kind = "lowshelf",  f0 = 150, gainDb = 12, shape = 0.9 },
		{ kind = "highshelf", f0 = 4000, gainDb = 6, shape = 0.9 })
	print(string.format("  %-42s %6d evals  ~%6.1f ms   (%d peak searches)",
		label, nResp, nResp * MSPER, nPeak))
	return nResp
end

print(string.format("one responseDb = %.4f ms (measured earlier)", MSPER))
print(string.format("grid = %d points, sub-grid = %d points", #D.GRID, #D.SUB_GRID))
print("")

local full = run("AS SHIPPED (build 8)")

-- 1. without the sub-40 Hz clip band (added today)
local savedSub = D.SUB_GRID
D.SUB_GRID = {}
local noSub = run("without SUB_GRID (today's clip band)")
D.SUB_GRID = savedSub

-- 2. without the diagnostics: realisedPeakDb is called twice purely for diag,
--    and correct() already computed the same quantity
local savedPeak = D.realisedPeakDb
local peakCalls = 0
D.realisedPeakDb = function(c, fs)
	peakCalls = peakCalls + 1
	if peakCalls > 2 then return -100, 1000 end    -- stub the diag pair
	return realPeak(c, fs)
end
peakCalls = 0
local noDiag = run("with the diag peak searches stubbed")
D.realisedPeakDb = savedPeak

print("")
print("Attribution:")
print(string.format("  sub-40 Hz clip band  : %5d evals  ~%5.1f ms   (added today)",
	full - noSub, (full - noSub) * MSPER))
print(string.format("  diag instrumentation : %5d evals  ~%5.1f ms   (added today, redundant)",
	full - noDiag, (full - noDiag) * MSPER))
print(string.format("  everything else      : %5d evals  ~%5.1f ms",
	noSub + noDiag - full, (noSub + noDiag - full) * MSPER))
print("")
print(string.format("  TOTAL                : %5d evals  ~%5.1f ms", full, full * MSPER))
print("")
print("The refinement window is 25 points per peak search; the pole and Nyquist")
print("probes are 2 more. Both were added today as part of the pole-aware fix.")
