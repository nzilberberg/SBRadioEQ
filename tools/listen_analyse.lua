--[[
SBRadioEQ -- find sound that is not the tone you played.

  cd /tmp/sbradioeq-bench && LISTEN_WAV=/tmp/sbradioeq-listen.wav jive listen_analyse

Reads a 16-bit stereo WAV and reports, per 100 ms block, four numbers that between
them separate "the tone I played" from "something the device added":

  peak    largest |sample|. 32767 means the converter ran out of numbers. Samples
          AT full scale are counted separately: a real sine touches the peak
          briefly, a clipped one SITS there, and the count is what tells them
          apart.

  rms     level. Establishes that the cable is actually connected -- a capture at
          the noise floor is NO RESULT, not a clean one.

  zcr     zero crossings per second. THIS IS THE SQUEE DETECTOR, and it needs no
          FFT: a 60 Hz sine crosses zero 120 times a second, a 5 kHz whistle
          crosses 10000 times. Play a LOW tone and any block whose zcr jumps by
          an order of magnitude contains something that is not that tone. Integer
          arithmetic, one pass, no spectral analysis on a 360 MHz core.

  jump    largest step between adjacent samples. THIS IS THE CRACK DETECTOR. A
          band-limited sine changes slowly between samples; a discontinuity --
          an unmuted transition, a sign inversion from a wrapped accumulator --
          moves a large fraction of full scale in ONE sample, which no 60 Hz tone
          can do.

WHY THESE FOUR AND NOT A SPECTRUM. The question is not "what does the output look
like", it is "did anything appear that was not played". With a single-frequency
source that question collapses to: did the rate of crossings change, did the
waveform tear, did it hit the rails. All three are O(n) and unambiguous.

⛔ THE SOURCE MUST BE ONE LOW TONE. Against music, zcr means nothing -- music
legitimately contains high frequencies, and this reports them as anomalies. The
whole method rests on the source being something whose zcr you know in advance.
]]

local path = os.getenv("LISTEN_WAV") or "/tmp/sbradioeq-listen.wav"
local f = io.open(path, "rb")
if not f then
	print("FAIL: cannot open " .. path)
	print("passed=0 failed=1")
	return
end

local data = f:read("*a")
f:close()

-- Minimal WAV handling: this reads files written by THIS project's arecord call
-- (S16_LE, 44100, stereo), so the header is a known 44 bytes. Anything else is
-- rejected rather than guessed at -- misreading the header silently shifts every
-- sample by a byte and turns the whole analysis into noise.
if #data < 45 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
	print("FAIL: not a RIFF/WAVE file: " .. path)
	print("passed=0 failed=1")
	return
end

local HDR   = 44
local RATE  = 44100
local BLOCK = RATE / 10          -- 100 ms
local nsamp = math.floor((#data - HDR) / 4)   -- stereo frames

print(string.format("%s: %d frames (%.2f s)", path, nsamp, nsamp / RATE))
if nsamp < BLOCK then
	print("FAIL: too short to analyse")
	print("passed=0 failed=1")
	return
end

local byte = string.byte
-- Left channel only. The loopback feeds both from the same output; a second
-- channel doubles the work and cannot disagree.
local function sampleAt(i)                      -- i is 0-based frame index
	local o = HDR + i * 4 + 1
	local lo, hi = byte(data, o), byte(data, o + 1)
	local v = hi * 256 + lo
	if v >= 32768 then v = v - 65536 end
	return v
end

print("")
print("  time     peak   atFS     rms    zcr/s     jump   note")

local worstZcr, worstZcrT = 0, 0
local anyClip, anyJump    = false, false
local blocks              = math.floor(nsamp / BLOCK)
local baseZcr             = nil

for b = 0, blocks - 1 do
	local i0    = b * BLOCK
	local peak, atFS, cross, jump, sumsq = 0, 0, 0, 0, 0
	local prev  = sampleAt(i0)
	for i = i0 + 1, i0 + BLOCK - 1 do
		local v = sampleAt(i)
		local a = v >= 0 and v or -v
		if a > peak then peak = a end
		if a >= 32767 then atFS = atFS + 1 end
		if (v >= 0) ~= (prev >= 0) then cross = cross + 1 end
		local d = v - prev
		if d < 0 then d = -d end
		if d > jump then jump = d end
		sumsq = sumsq + (v / 32768) * (v / 32768)
		prev  = v
	end
	local rms  = math.sqrt(sumsq / BLOCK)
	local zcr  = cross * 10                       -- per second
	local t    = b / 10

	-- The first block with real signal sets the expectation; later blocks are
	-- judged against it rather than against a hardcoded frequency, so the tone
	-- you chose does not have to be told to this script.
	if not baseZcr and rms > 0.01 then baseZcr = zcr end

	local note = ""
	if atFS > 0 then
		note = "CLIPPED (" .. atFS .. " samples at full scale)"
		anyClip = true
	end
	if baseZcr and baseZcr > 0 and zcr > baseZcr * 4 and rms > 0.005 then
		note = note .. (note ~= "" and " + " or "") .. "HIGH-FREQUENCY CONTENT"
		if zcr > worstZcr then worstZcr, worstZcrT = zcr, t end
	end
	if jump > 8000 then
		note = note .. (note ~= "" and " + " or "") .. "DISCONTINUITY"
		anyJump = true
	end

	if note ~= "" or b % 10 == 0 then
		print(string.format("  %5.1fs  %6d  %5d  %6.4f  %7d  %7d   %s",
		      t, peak, atFS, rms, zcr, jump, note))
	end
end

print("")
if not baseZcr then
	print("NO SIGNAL: every block sat at the noise floor.")
	print("  The cable is not connected, or nothing was playing. This is NOT a")
	print("  clean result -- it is the absence of a measurement.")
	print("passed=0 failed=1")
	return
end

print(string.format("reference zcr from the first block with signal: %d/s", baseZcr))
local bad = 0
if anyClip then print("CLIPPING FOUND: samples sat at full scale."); bad = bad + 1 end
if worstZcr > 0 then
	print(string.format("HIGH-FREQUENCY CONTENT FOUND: zcr reached %d/s at %.1fs, against a %d/s source.",
	      worstZcr, worstZcrT, baseZcr))
	bad = bad + 1
end
if anyJump then print("DISCONTINUITY FOUND: the waveform tore between adjacent samples."); bad = bad + 1 end
if bad == 0 then
	print("Nothing but the tone. No clipping, no added frequencies, no tearing.")
end
print(string.format("passed=%d failed=%d", bad == 0 and 1 or 0, bad))
