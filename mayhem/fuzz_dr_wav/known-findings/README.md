# fuzz_dr_wav -- known findings

Found during integration, within ~1 minute of `-fork=4` fuzzing from the committed seeds + dict.
Kept here and NOT in `testsuite/`: seeds are replayed on every run, and this is a fatal
(process-aborting) input, so it would abort every future run if it sat in the corpus.

Reproduce (both binaries are produced by `mayhem/build.sh`):

```
/mayhem/fuzz_dr_wav-standalone mayhem/fuzz_dr_wav/known-findings/float-to-int-overflow-f32-to-s32.wav
```

## 1. `float-to-int-overflow-f32-to-s32.wav` -- undefined float-to-int32 conversion in `drwav_f32_to_s32`

```
mayhem/harnesses/../../dr_wav.h:8146:19: runtime error: inf is outside the range of representable
values of type 'int'
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior mayhem/harnesses/../../dr_wav.h:8146:19
```

**Cause.** `dr_wav.h`'s IEEE-float-to-s32 sample converter does no range check before the cast
(`dr_wav.h:8140-8147`):

```c
DRWAV_API void drwav_f32_to_s32(drwav_int32* pOut, const float* pIn, size_t sampleCount)
{
    ...
    for (i = 0; i < sampleCount; ++i) {
        *pOut++ = (drwav_int32)(2147483648.0f * pIn[i]);   /* dr_wav.h:8146 */
    }
}
```

`drwav_read_pcm_frames_s32()` calls this converter whenever the WAV's `fmt` chunk declares
`wFormatTag == WAVE_FORMAT_IEEE_FLOAT` (3) and the caller asked for s32 output (exactly what
`mayhem/harnesses/fuzz_dr_wav.c` does via `drwav_read_pcm_frames_s32`) -- so every raw 4-byte
"sample" in the `data` chunk of an IEEE-float WAV is attacker-controlled and reinterpreted as a
`float` with no validation. A sample of `+-Inf`, `NaN`, or any magnitude whose product with
`2147483648.0f` exceeds `INT32_MAX`/underflows `INT32_MIN` makes the `(drwav_int32)` cast operate
on an out-of-range float, which is undefined behavior in C (6.3.1.4) -- caught here by
`-fsanitize=undefined` before it can silently yield an unspecified/trap value on a platform whose
cast instruction (e.g. x86 `cvttss2si`) doesn't saturate.

**Impact.** Attacker-supplied IEEE-float WAV data decoded through
`drwav_read_pcm_frames_s32()`/`drwav_read_pcm_frames_s32le()`/`..._s32be()` (or any of the
higher-level `drwav_*_and_read_pcm_frames_s32*` convenience APIs) can drive this conversion into
UB with a single crafted sample -- no special container structure needed, just
`wFormatTag=WAVE_FORMAT_IEEE_FLOAT` and one huge/`Inf`/`NaN` 4-byte float in `data`. Under the
project's default build this is "just" a halting UBSan abort (a DoS on any caller that treats a
`dr_wav` decode of untrusted audio as safe); on a target compiled without UBSan the cast is
implementation-defined/unspecified, not a guaranteed crash, but still incorrect (silently produces
a garbage sample rather than a clamped value). The `drwav_f64_to_s32` sibling (`dr_wav.h:8153`,
`2147483648.0 * pIn[i]` then cast) has the identical shape and is presumably equally reachable via
a `bitsPerSample=64` IEEE-float WAV, though not separately reproduced here.

**One-line-ish upstream fix** -- clamp before casting, e.g.:

```c
float v = 2147483648.0f * pIn[i];
*pOut++ = (v >= 2147483520.0f) ? DRWAV_INT32_MAX
        : (v < -2147483648.0f) ? DRWAV_INT32_MIN
        : (drwav_int32)v;
```

(NaN also needs an explicit check -- a NaN compares false against every bound above.)

**Reproducer** (48-byte minimal WAV, built by hand -- not one of the committed corpus seeds):
mono, `fmt` tag 3 (IEEE float), 32-bit, 44100Hz, one `data` sample = `1e30f` (which the header
declares as its own float encoding; the cast that fires on it happens to hit `+Inf` because
`2147483648.0f * 1e30f` itself already overflows `float` range before the int cast is even
reached).

A related, not-yet-isolated class was also observed during the same fuzzing run: repeated
`signed integer overflow` reports in the MS-ADPCM decoder's predictor arithmetic
(`dr_wav.h:6513/6523/6545/6560`, e.g. `newSample0 = (prevFrames[...] * coeff1Table[predictor]) + ...`)
-- `coeff1Table`/`coeff2Table` entries and `prevFrames` combine via plain `int` multiplication with
no overflow check. Not minimized/committed here for time; worth a follow-up pass if this target
gets a deep run.
