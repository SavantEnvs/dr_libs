/*
 * Fuzz harness for dr_flac.h -- the historical `drlibs-fuzz` target (project "dr-libs" since
 * 2022; preserved here so run history/defects stay attached).
 *
 * Ported from upstream tests/flac/flac_fuzz.c, updated for the current dr_flac callback API
 * (drflac_open_relaxed grew a drflac_tell_proc; the seek callback returns DRFLAC_TRUE on
 * success and must handle DRFLAC_SEEK_SET/CUR/END). The in-memory stream, byte-0 container
 * selection, and s32 drain loop match the upstream harness.
 *
 * BOUNDED (SPEC 6b): the input stream is capped at sizeof(fuzz_flacstream) (4096 bytes) and each
 * decode call reads at most 256 frames into a fixed 2048-int32 buffer (8 channels max, which is
 * dr_flac's own hard channel limit) -- a malformed header claiming a huge total sample count
 * cannot make one call over-read; the read/seek callbacks themselves never look past
 * fuzz_flacstream_length. Decoding continues only while frames are actually produced, so a
 * stream that runs out of real data stops promptly.
 */

#include <stdint.h>
#include <string.h>

#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_CRC
#define DR_FLAC_NO_STDIO
#include "../../dr_flac.h"

#define MIN(a,b) (((a)<(b))?(a):(b))

static uint8_t fuzz_flacstream[4096];
static size_t fuzz_flacstream_position;
static size_t fuzz_flacstream_length;

static size_t read_fuzz_flacstream(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    size_t readsize = MIN(bytesToRead, fuzz_flacstream_length - fuzz_flacstream_position);
    (void)pUserData;
    if (readsize > 0) {
        memcpy(bufferOut, fuzz_flacstream + fuzz_flacstream_position, readsize);
        fuzz_flacstream_position += readsize;
        return readsize;
    }
    return 0;
}

static drflac_bool32 seek_fuzz_flacstream(void* pUserData, int offset, drflac_seek_origin origin)
{
    long long base;
    long long target;
    (void)pUserData;

    switch (origin) {
        case DRFLAC_SEEK_SET: base = 0; break;
        case DRFLAC_SEEK_CUR: base = (long long)fuzz_flacstream_position; break;
        case DRFLAC_SEEK_END: base = (long long)fuzz_flacstream_length; break;
        default: return DRFLAC_FALSE;
    }

    target = base + offset;
    if (target < 0 || target > (long long)fuzz_flacstream_length) {
        return DRFLAC_FALSE;
    }

    fuzz_flacstream_position = (size_t)target;
    return DRFLAC_TRUE;
}

static drflac_bool32 tell_fuzz_flacstream(void* pUserData, drflac_int64* pCursor)
{
    (void)pUserData;
    *pCursor = (drflac_int64)fuzz_flacstream_position;
    return DRFLAC_TRUE;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size > 2) {
        drflac* drflac_fuzzer;
        drflac_int32 drflac_fuzzer_out[2048]; /* 256 frames over up to 8 channels */
        drflac_container container = (data[0] & 1) ? drflac_container_native : drflac_container_ogg;

        memcpy(fuzz_flacstream, data + 1, MIN(size - 1, sizeof(fuzz_flacstream)));

        fuzz_flacstream_position = 0;
        fuzz_flacstream_length = MIN(size - 1, sizeof(fuzz_flacstream));

        drflac_fuzzer = drflac_open_relaxed(read_fuzz_flacstream, seek_fuzz_flacstream, tell_fuzz_flacstream, container, NULL, NULL);

        while (drflac_read_pcm_frames_s32(drflac_fuzzer, 256, drflac_fuzzer_out));

        drflac_close(drflac_fuzzer);
    }
    return 0;
}
