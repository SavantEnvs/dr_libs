#!/bin/bash
# mayhem/build.sh -- builds the dr_libs fuzz targets (FLAC, WAV, MP3), their standalone
# reproducers, per-target dictionaries, the upstream comparison test suite, and deterministic
# test vectors. Idempotent and air-gapped: every tool/library used here (clang, cmake, python3,
# flac, lame, libFLAC, libsndfile) is baked into the image by mayhem/Dockerfile, so a re-run needs
# no network.
#
# dr_flac.h / dr_wav.h / dr_mp3.h are single-header libraries: each harness `#define`s the
# implementation macro and includes the header directly, so the decoder compiles INTO the same
# translation unit as the harness -- $SANITIZER_FLAGS (and, for the fuzz binary, the SanCov that
# $LIB_FUZZING_ENGINE (-fsanitize=fuzzer) carries) instruments the whole decoder automatically.
# There is no separate library object to remember `-fsanitize=fuzzer-no-link` on.
set -euxo pipefail

cd "${SRC:-/mayhem}"

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers.
export SANITIZER_FLAGS="${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
DEBUG_FLAGS="-g -gdwarf-3"          # Mayhem triage needs DWARF <= 3 (clang-19 default -g is DWARF-5)
CC="${CC:-clang}"
LIB_FUZZING_ENGINE="${LIB_FUZZING_ENGINE:--fsanitize=fuzzer}"
STANDALONE_FUZZ_MAIN="${STANDALONE_FUZZ_MAIN:-/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"

# ── 1) Fuzz targets + standalone reproducers ──────────────────────────────────────────────────
# Mining branch: only the dr_mp3.h harness (the fix 51e61d3 is in dr_mp3.h).
declare -A BINARY_FOR_TARGET=(
  [fuzz_dr_mp3-mined-019e75b]=fuzz_dr_mp3
)

for target in "${!BINARY_FOR_TARGET[@]}"; do
  bin="${BINARY_FOR_TARGET[$target]}"
  src="mayhem/harnesses/$bin.c"

  flags="$SANITIZER_FLAGS"

  $CC $flags $DEBUG_FLAGS ${COVERAGE_FLAGS:-} $LIB_FUZZING_ENGINE \
      "$src" -o "/mayhem/$bin"

  $CC $flags $DEBUG_FLAGS \
      "$STANDALONE_FUZZ_MAIN" "$src" -o "/mayhem/$bin-standalone"

  echo "built $bin (+ standalone) for target $target"
done

# ── 2) Per-target dictionaries -- Mayhemfiles reference /mayhem/<target>.dict ─────────────────
for target in "${!BINARY_FOR_TARGET[@]}"; do
  d="$SRC/mayhem/$target/$target.dict"
  [ -f "$d" ] || { echo "FATAL: missing dictionary $d (referenced by mayhem/Mayhemfile_$target)" >&2; exit 1; }
  cp -f "$d" "/mayhem/$target.dict"
  echo "copied dictionary /mayhem/$target.dict"
done

# ── 3) Upstream test suite, NORMAL flags (mayhem/test.sh RUNS it; it does not compile). ───────
# Build only the non-playback tests: the *_playback tests need the tests/external/miniaudio
# submodule (not shipped in-tree) and a real audio device, neither of which exists here.
cmake -S . -B mayhem/build-tests -DDR_LIBS_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build mayhem/build-tests -j"$MAYHEM_JOBS" --target \
    wav_decoding wav_decoding_cpp wav_encoding \
    flac_decoding flac_decoding_cpp flac_seeking \
    mp3_basic mp3_extract

# All 8 test binaries MUST be dynamically linked so verify-repo's LD_PRELOAD sabotage shim can
# neuter them (constructor _exit(0)s before main() runs) -- a statically-linked test binary would
# survive sabotage and make mayhem/test.sh a reward-hackable oracle (SPEC 6.3). Plain clang/cc
# links dynamically by default; assert it so a toolchain change can't silently flip this.
for t in wav_decoding wav_decoding_cpp wav_encoding flac_decoding flac_decoding_cpp flac_seeking mp3_basic mp3_extract; do
  bin="mayhem/build-tests/$t"
  if ! file "$bin" | grep -q 'dynamically linked'; then
    echo "FATAL: $bin is not dynamically linked -- the sabotage check could not neuter it" >&2
    file "$bin" >&2
    exit 1
  fi
done

# ── 4) Deterministic test vectors for the suite (python stdlib PCM synth + in-image flac/lame). ─
python3 mayhem/gen_vectors.py

echo "build.sh complete:"
ls -la /mayhem/fuzz_dr_mp3 /mayhem/fuzz_dr_mp3-standalone /mayhem/fuzz_dr_mp3-mined-019e75b.dict 2>&1 || true
