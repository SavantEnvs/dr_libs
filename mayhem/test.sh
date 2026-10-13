#!/bin/bash
# mayhem/test.sh -- RUNS the upstream dr_libs test suite (built by mayhem/build.sh; nothing is
# compiled here) and emits a CTRF summary. The oracle is behavioral: each upstream test program
# must produce its expected per-vector verdict lines (dr_flac vs libFLAC, dr_wav vs libsndfile,
# dr_mp3 self-consistency), and encoder outputs are byte-checked -- a program neutered to exit(0)
# produces none of that and FAILS. All test binaries are dynamically linked (asserted by
# build.sh), so verify-repo's LD_PRELOAD sabotage shim can neuter them.
#
# Upstream suite (CMake add_test) = 11 tests. 8 run here; the 3 *_playback tests are skipped:
# they need the tests/external/miniaudio submodule (not shipped in-tree) and a real audio device.
set -uo pipefail

cd "${SRC:-/mayhem}"
BT=mayhem/build-tests

NFLAC=$(ls tests/testvectors/flac/testbench/*.flac 2>/dev/null | wc -l)
NWAV=$(ls tests/testvectors/wav/tests/*.wav 2>/dev/null | wc -l)
NMP3=$(ls tests/testvectors/mp3/tests/*.mp3 2>/dev/null | wc -l)
echo "test vectors: $NFLAC flac, $NWAV wav, $NMP3 mp3"

TESTS_JSON=""
tests=0; passed=0; failed=0; skipped=0
record() { # name status
    tests=$((tests+1))
    case "$2" in passed) passed=$((passed+1));; failed) failed=$((failed+1));; skipped) skipped=$((skipped+1));; esac
    TESTS_JSON="${TESTS_JSON:+$TESTS_JSON,}{\"name\":\"$1\",\"status\":\"$2\",\"duration\":0}"
    echo "[$2] $1"
}

# run_counted <name> <binary> <expected-verdict-count> <verdict-regex> [args...]
# Passes iff: exit 0, exactly <expected> verdict lines, and no Failed/ERROR line.
run_counted() {
    local name=$1 bin=$2 want=$3 pat=$4; shift 4
    local out rc got
    out=$("$bin" "$@" 2>&1); rc=$?
    got=$(printf '%s\n' "$out" | grep -cE "$pat")
    if [ "$rc" -eq 0 ] && [ "$got" -eq "$want" ] && \
       ! printf '%s\n' "$out" | grep -qE '[[:space:]]Failed[[:space:]]*$|ERROR|error:'; then
        record "$name" passed
    else
        record "$name" failed
        echo "--- $name output (rc=$rc, verdicts $got/$want) ---"
        printf '%s\n' "$out" | tail -25
    fi
}

# FLAC: decode + open-and-read sections each print one 'Passed' per vector; seek prints one.
run_counted flac_decoding     "$BT/flac_decoding"     $((NFLAC*2)) '[[:space:]]Passed[[:space:]]*$'
run_counted flac_decoding_cpp "$BT/flac_decoding_cpp" $((NFLAC*2)) '[[:space:]]Passed[[:space:]]*$'
run_counted flac_seeking      "$BT/flac_seeking"      "$NFLAC"     '[[:space:]]Passed[[:space:]]*$'

# WAV: one 'Passed' per vector (dr_wav vs libsndfile, sample-exact).
run_counted wav_decoding      "$BT/wav_decoding"      "$NWAV"      '[[:space:]]Passed[[:space:]]*$'
run_counted wav_decoding_cpp  "$BT/wav_decoding_cpp"  "$NWAV"      '[[:space:]]Passed[[:space:]]*$'

# wav_encoding writes a 1s stereo 44.1kHz IEEE-float sine wav; verify the RIFF structure and
# samples byte-level (format tag 3, layout, amplitude envelope) -- not just the exit code.
we_out=/tmp/wav_encoding_out.wav
rm -f "$we_out"
if "$BT/wav_encoding" "$we_out" && python3 - "$we_out" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert d[0:4] == b'RIFF' and d[8:12] == b'WAVE', "not a RIFF/WAVE file"
pos, fmt, data = 12, None, None
while pos + 8 <= len(d):
    cid, sz = d[pos:pos+4], struct.unpack('<I', d[pos+4:pos+8])[0]
    if cid == b'fmt ': fmt = d[pos+8:pos+8+sz]
    if cid == b'data': data = d[pos+8:pos+8+sz]
    pos += 8 + sz + (sz & 1)
tag, ch, rate = struct.unpack('<HHI', fmt[:8])
bps = struct.unpack('<H', fmt[14:16])[0]
assert tag == 3 and ch == 2 and rate == 44100 and bps == 32, (tag, ch, rate, bps)
assert data is not None and len(data) == 44100 * 2 * 4, len(data) if data else None
s = struct.unpack('<%df' % (len(data)//4), data)
assert abs(s[0]) < 1e-6 and s[0] == s[1], "sine must start at ~0, channels identical"
peak = max(abs(x) for x in s)
assert 0.2 < peak <= 0.2500001, peak     # generator amplitude is 0.25
print("wav_encoding output verified: float32 stereo 44100Hz, %d frames, peak %.4f" % (len(s)//2, peak))
EOF
then record wav_encoding passed; else record wav_encoding failed; fi

# MP3: mp3_basic prints one 'OK' per vector (memory-vs-file, with/without metadata consistency).
run_counted mp3_basic "$BT/mp3_basic" "$NMP3" '[[:space:]]OK[[:space:]]*$' tests/testvectors/mp3/tests

# mp3_extract decodes one vector to raw s16 PCM and self-checks the frame count; verify the PCM
# size matches ~1s mono 44.1kHz and it is non-silent.
me_in=$(ls tests/testvectors/mp3/tests/*mono*.mp3 | head -1)
me_out=/tmp/mp3_extract_out.raw
rm -f "$me_out"
if "$BT/mp3_extract" "$me_in" -o "$me_out" -f s16 && python3 - "$me_out" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
frames = len(d) // 2                      # s16 mono
assert 40000 < frames < 60000, frames     # ~1s @ 44.1kHz + codec delay/padding
s = struct.unpack('<%dh' % frames, d)
peak = max(abs(x) for x in s)
assert peak > 10000, peak                 # non-silent decode
print("mp3_extract output verified: %d frames, peak %d" % (frames, peak))
EOF
then record mp3_extract passed; else record mp3_extract failed; fi

# Skipped upstream tests (recorded, with reason above).
record wav_playback skipped
record wav_playback_cpp skipped
record mp3_playback skipped

CTRF_OUT="${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}"
CTRF_JSON="{\"reportFormat\":\"CTRF\",\"specVersion\":\"0.0.0\",\"results\":{\"tool\":{\"name\":\"dr_libs-upstream-tests\"},\"summary\":{\"tests\":$tests,\"passed\":$passed,\"failed\":$failed,\"pending\":0,\"skipped\":$skipped,\"other\":0},\"tests\":[$TESTS_JSON]}}"
printf '%s\n' "$CTRF_JSON" > "$CTRF_OUT"
echo "CTRF $CTRF_JSON"

[ "$failed" -eq 0 ]
