/*
 * Fuzz harness for dr_wav.h -- the new `fuzz_dr_wav` target (dr_libs previously only had FLAC
 * fuzzed; WAV and MP3 are independent untrusted-input parsers over the same single-header
 * library and deserve their own targets).
 *
 * Decodes entirely from memory (drwav_init_memory) -- no filesystem I/O.
 *
 * BOUNDED (SPEC 6b): input capped at MAX_INPUT_SIZE so a malformed RIFF header cannot make the
 * chunk walk (LIST/id3/smpl/cue/bext/fmt) run on an arbitrarily large buffer. Decoding itself
 * pulls samples MAX_ITERATIONS*FRAMES_PER_READ frames at a time into a HEAP buffer sized off the
 * declared channel count -- capped at MAX_CHANNELS; a wildly-out-of-range channel count (a
 * malformed header can declare up to 65535) skips PCM decoding rather than risking pathological
 * allocation size, but drwav_init_memory's own header/metadata-chunk parsing has already run by
 * that point, so it stays fully fuzzed. The frame loop is additionally capped at MAX_ITERATIONS
 * regardless of the file's declared totalPCMFrameCount, so one call can't spin forever.
 */

#include <stdint.h>
#include <stdlib.h>

#define DR_WAV_IMPLEMENTATION
#include "../../dr_wav.h"

#define MAX_INPUT_SIZE  (1u * 1024 * 1024)
#define MAX_CHANNELS    64
#define FRAMES_PER_READ 256
#define MAX_ITERATIONS  4096

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    drwav wav;

    if (size == 0 || size > MAX_INPUT_SIZE) {
        return 0;
    }

    if (!drwav_init_memory(&wav, data, size, NULL)) {
        return 0;
    }

    if (wav.channels > 0 && wav.channels <= MAX_CHANNELS) {
        drwav_int32* buffer = (drwav_int32*)malloc((size_t)FRAMES_PER_READ * wav.channels * sizeof(drwav_int32));
        if (buffer != NULL) {
            drwav_uint64 framesRead;
            unsigned int iterations = 0;
            do {
                framesRead = drwav_read_pcm_frames_s32(&wav, FRAMES_PER_READ, buffer);
                iterations++;
            } while (framesRead > 0 && iterations < MAX_ITERATIONS);
            free(buffer);
        }
    }

    drwav_uninit(&wav);
    return 0;
}
