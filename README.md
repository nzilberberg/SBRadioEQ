# SBRadioEQ

A two-band parametric EQ for the **Squeezebox Radio**, running as a SqueezePlay applet on the
device itself.

It drives the TLV320AIC3104 codec's hardware "audio effects filter" directly, so the filtering
costs no CPU, applies in realtime, and works with no server involved. Adjust it with the Radio's
own knob and buttons — no web UI, no remote, no LMS plugin.

The Radio has **no tone controls at all** — not bass, not treble, not an EQ. LMS hides them because
`Slim::Player::SqueezePlay` inherits a zero-width bass range from `Squeezebox2.pm`, so every UI gates
the control off; and the device's own Audio Settings menu contains only Sound Effects. (The Boom is
different — it has real tone hardware driven over I²C. The Radio does not.)

The hardware to do it has been sitting in the codec the whole time, unused. This reaches it.

---

## What you get

- **Two bands**, one hardware biquad each: a low shelf and a high shelf.
- **Three controls per band** — corner frequency, gain (±15 dB), and Q/shape.
- **A live response graph** drawn from the coefficients actually sent to the codec, so the picture
  is what the chip is doing rather than an idealised version of it.
- **Automatic level compensation.** The codec cannot express gain above unity, so every boost is
  realised as a cut elsewhere and the level is bought back with the player's volume. The applet
  works out how much and applies as much as the volume range allows — it never refuses an EQ
  setting, and any part it cannot compensate is simply heard as a quieter result.
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

In LMS, go to **Settings → Plugins → Additional Repositories** and add:

```
https://nzilberberg.github.io/SBRadioEQ/repo.xml
```

Then on the Radio: **Settings → Advanced → Applet Installer → SBRadioEQ**. The Radio reboots when
it finishes. Afterwards the EQ lives at **Settings → Audio Settings → Tone Controls**.

That URL is a *catalog*: it is stable, and it is rewritten to point at each new release, so updates
are offered to you as they appear. The release archives it points at are immutable and carry a
SHA-1 the installer checks.

> **If you installed v0.2.0**, the URL you were given was
> `.../releases/download/v0.2.0/repo.xml` — a descriptor stored inside that one release, which can
> never mention a later version. Replace it with the catalog URL above, or you will never be
> offered an update. This is fixed from v0.2.1 onward.

**Requirements.** A Squeezebox Radio (`baby`) — the coefficient controls live in that model's
TLV320AIC3104 and nowhere else, and the applet refuses to register on anything else. Interactive
editing also needs the device's in-process mixer module `baby_bsp`; without it the editor declines
to open rather than fall back to a path that would stall the UI.

### Removing it

Use the Applet Installer's own removal. The Radio reboots, and because the codec's filter registers
are volatile, the reboot clears the EQ completely — no tone modification survives it.

**One thing does survive: the player volume.** See *Level matching* below. Run **Tone Controls →
Reset Tone** before uninstalling and the make-up gain is wound back out; skip it and playback stays
as much as ~34 dB louder than the curve warranted, until you turn it down by hand.

---

## Level matching

The codec cannot express gain above unity, so a "+12 dB bass" is realised as 0 dB bass and −12 dB
everywhere else, and the level is bought back by raising the *player's* volume. That make-up is
what "Level Matching" controls. Measured on the device at the default corner frequencies: **15 dB**
with one band at +15, **30 dB** with both at +15 and Q 1.0, and **34.4 dB** at both +15 with Q 2.0.

Two consequences worth knowing:

- The volume control is doing work on your behalf. Switching Level Matching off unwinds the make-up
  rather than stranding it, and Reset Tone takes it back to zero.
- The make-up lives in the player volume, which persists independently of this applet — hence the
  removal note above.

**Level Matching is best-effort, and never limits what you can build.** The EQ controls define the
sound you are asking for. Level Matching raises the player volume to offset the attenuation that
curve requires; if the current volume range cannot provide the whole amount, the curve is still
applied in full and playback is simply quieter by the uncompensated part. It stays enabled and
recalculates on every change, so a later, cheaper curve reduces or clears the shortfall on its own —
no toggling off and on, no manual retry.

Measured example: from volume 90, a curve wanting 30 dB gets 4.93 dB and the volume stops at 100. A
2.0 dB curve later reconciles to 1.97 dB.

What governs the maximum is your **current volume**, not the EQ settings:

- Strong boosts, high Q, and overlapping bands all cost more make-up.
- Lowering your base listening level before dialling in an expensive curve leaves more room.
- A shortfall is a loudness limitation, never a limit on which EQ settings are valid.

The readout shows required against available (`-34/20`), and a small `LIMITED` marker appears while
compensation is partial. Neither blocks editing.

**When a hardware write fails**, the applet does not raise the volume, shows `EQ FAILED` or `MUTED`
in the status corner of either editor, and records the detail to syslog (`SBEQ-HWFAIL`). If the
filter was confirmed bypassed, the make-up already in the player volume is wound back out before
sound returns; if the hardware state cannot be established, the output stays muted rather than
unmuting into a filter nobody can vouch for. Reset Tone shows the reason on screen instead of
closing when it cannot complete.

The volume move happens *inside* the mute, so the filter and the volume always settle together —
audio is never restored partway through a change.

---

## Working on it

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

The build number shows in the status bar's bottom-right corner; if it does not match what the
deploy printed, you are looking at an older render (the screen does not survive a restart — reopen
it).

To roll back, delete `/usr/share/jive/applets/SBRadioEQ/` and restart SqueezePlay.

Cutting a release is `sh tools/package.sh <version>`, then `gh release create`, then
`sh tools/verify-release.sh <version>` — which fetches the *served* bytes back and checks the
descriptor against them, because generating a descriptor is not evidence that the right one was
published. Committing `docs/repo.xml` is part of releasing, not an afterthought: it is the file
installed users actually poll.

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

Working and in daily use. Latest release v0.2.9; installable from the catalog URL above. Not listed
in the central LMS plugin repository — that would be a pull request to
`lms-community/lms-plugin-repository`, and it has not been made.

**Settings do survive a power cycle.** The codec's registers are volatile, so the applet re-applies
the saved curve at startup from its Meta (`configureApplet`), verified on a cold boot with the
screen never opened.

### Tested configuration

Everything below was measured on the hardware, not inferred. Nothing outside this row has been
tested, which is why the catalog entry carries **no `minTarget`/`maxTarget` bounds** — asserting a
firmware range nobody has checked is worse than leaving it open.

| | |
|---|---|
| Model | Squeezebox Radio (`baby`) — Logitech MX25 Baby Board |
| Firmware | **9.0.1 r17084** (community, Yocto `root@poky`, 2025-12-28) |
| Kernel | 2.6.26.8-rt16 |
| `baby_bsp` | present, 13076 bytes, at `/usr/lib/lua/5.1/baby_bsp.so` |
| Install / update | LMS 9.x via the stable catalog URL above |
| Boot re-apply | verified on a cold boot with the screen never opened |
| Restart | verified; codec coefficients survive a SqueezePlay restart |
| LMS power off → on | verified: enable register and both coefficient sets byte-identical |
| Speaker ↔ headphones | **NOT TESTED** — see below |

⚠️ **Only one firmware has ever been tested.** `baby_bsp` is present on it, and every interactive
path fails closed without that module, but "every Radio firmware ships it" is not something this
project has established.

Known gaps, in the order they matter:

- **Headphone insertion and removal are untested** — see the endpoint note below. That is the one
  remaining path where the loud mismatch could occur without any edit of yours.
- The endpoint-change case is untested: `SqueezeboxBabyApplet` rewrites codec state on headphone
  insert and on power transitions, which MAY drop the filter -- untested, and a hypothesis rather
  than a confirmed defect. An LMS power off/on transition WAS measured and leaves the filter
  byte-identical.
- Reset Tone and Level Matching are structurally tested but have never been watched through by a
  human on a live player.
