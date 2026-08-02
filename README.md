# SBRadioEQ

A two-band parametric EQ for the **Squeezebox Radio**, running as a SqueezePlay applet on the
device itself.

It drives the TLV320AIC3104 codec's hardware "audio effects filter" directly, so the filtering
costs no CPU, applies in realtime, and works with no server involved. Adjust it with the Radio's
own knob and buttons — no web UI, no remote, no LMS plugin.

The Radio has bass and treble controls in its menus but no real EQ. This adds one.

---

## What you get

- **Two bands**, one hardware biquad each: a low shelf and a high shelf.
- **Three controls per band** — corner frequency, gain (±15 dB), and Q/shape.
- **A live response graph** drawn from the coefficients actually sent to the codec, so the picture
  is what the chip is doing rather than an idealised version of it.
- **Automatic level compensation.** The codec cannot express gain above unity, so every boost is
  realised as a cut elsewhere and the level is bought back with the player's volume. The applet
  works out how much and applies it, and refuses a boost it cannot pay for rather than letting the
  output sag.
- **The device's own look** — the stock wallpaper and skin chrome, so it does not look bolted on.

Controls are knob-only, because the Radio's arrows are remote-only:

| | |
|---|---|
| turn | move the highlight / change the value |
| press | enter and leave edit mode |
| hold | bypass on/off |
| back | cancel an edit, or save and exit |

---

## Installing

Applets live on the Radio's unionfs overlay, so they survive a reboot.

```bash
RADIO=root@<your-radio-ip> sh tools/deploy.sh
```

That script is deliberately paranoid, because a broken applet can leave the UI unusable:

1. bumps the build number, so what is on screen is identifiable
2. parse-checks the staged files **before** overwriting the installed ones
3. installs every module and verifies each `require` resolves on the device
4. compares md5 of source against destination
5. restarts SqueezePlay, waits for the old process to actually die, and fails if more than one
   instance ends up running

Then open **Settings → Audio Settings → Equalizer**. The build number shows in the status bar's
bottom-right corner; if it does not match what the deploy printed, you are looking at an older
render (the screen does not survive a restart — reopen it).

To roll back, delete `/usr/share/jive/applets/SBRadioEQ/` and restart SqueezePlay.

---

## Running the tests

There is no Lua interpreter on the Radio and none for this on a desktop — Lua is linked into the
`jive` binary. But `jive` treats its first argument as a module to require, with `./?.lua` on the
path, which turns the device into a test bench:

```bash
scp -O test/test_eqdesign.lua lua/eqdesign.lua root@<radio>:/tmp/
ssh root@<radio> 'cd /tmp && /usr/bin/jive test_eqdesign'
```

Everything therefore runs in the real interpreter on the real ARM hardware, soft-float and all.

`test/` holds the suite plus a large number of `diag_*.lua` measurement scripts. The diagnostics
are not tests — they are the experiments that established how this chip behaves, kept because
re-deriving them is expensive.

---

## Notes for anyone working on this

**The coefficient format is the whole difficulty.** Each section is:

```
H(z) = (N0 + 2*N1*z^-1 + N2*z^-2) / (32768 - 2*D1*z^-1 - D2*z^-2)
```

Note the factor of 2 on `N1` and `D1` — getting it wrong produces a filter that is stable and
completely wrong. All five coefficients are signed 16-bit.

**No section can express gain above unity.** A +15 dB shelf at 4 kHz would need `N0 = 129274` and
the field holds 32767. Every boost is a cut elsewhere plus volume make-up.

**Never write coefficients to a running filter.** Partially-written coefficients describe a filter
whose numerator no longer cancels its own denominator, which exposes the uncancelled pole at full
resonance — measured at +42 dB. Bypass, write, re-enable. `test_bracketed.lua` enforces it.

**⚠️ This platform's Lua gets `^` precedence wrong.** Measured on-device: `2*3^2 == 36`,
`-3^2 == 9`, `2^2^3 == 64` (stock Lua 5.1 gives 18, −9, 256). `^` binds *lower* than `*`, `/` and
unary minus, and associates left, so `100*1.04^3` computes `(100*1.04)^3`. Always parenthesise.
`test_powerprec.lua` guards it.

**At low bass corners the chip's precision runs out.** Below ~130 Hz at high gain and Q the
frequency control is audibly coarse, and the realised response differs from the request by about
1 dB. A brute-force search over the integer neighbourhood put that at the hardware's floor. The
graph shows it honestly rather than hiding it.

---

## Status

Working and in daily use. Not published to the LMS plugin repository.

Not built: settings persistence across a power cycle — the codec returns to its defaults and the
applet does not yet re-apply on boot.
