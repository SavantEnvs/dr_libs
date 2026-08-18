/*
 * Fuzz harness for dr_mp3.h -- the new `fuzz_dr_mp3` target (dr_libs previously only had FLAC
 * fuzzed; WAV and MP3 are independent untrusted-input parsers over the same single-header
 * library and deserve their own targets).
 *
 * Decodes entirely from memory (drmp3_init_memory) -- no filesystem I/O.
 *
 * BOUNDED (SPEC 6b): input capped at MAX_INPUT_SIZE. MP3 is fixed at <=2 channels by the format
 * itself, so the output buffer is a small fixed-size stack array; decoding is additionally capped
 * at MAX_ITERATIONS frame-reads regardless of how many frames the stream appears to contain, so a
 * malformed/adversarial frame-sync sequence cannot make one call decode without bound.
 */

#include <stdint.h>

#define DR_MP3_IMPLEMENTATION
#include "../../dr_mp3.h"

#define MAX_INPUT_SIZE  (1u * 1024 * 1024)
#define FRAMES_PER_READ 1152 /* one classic MP3 frame's worth of samples per channel */
#define MAX_CHANNELS    2    /* dr_mp3 / MPEG audio: mono or stereo only */
#define MAX_ITERATIONS  4096

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    drmp3 mp3;
    drmp3_int16 buffer[FRAMES_PER_READ * MAX_CHANNELS];
    drmp3_uint64 framesRead;
    unsigned int iterations = 0;

    if (size == 0 || size > MAX_INPUT_SIZE) {
        return 0;
    }

    if (!drmp3_init_memory(&mp3, data, size, NULL)) {
        return 0;
    }

    do {
        framesRead = drmp3_read_pcm_frames_s16(&mp3, FRAMES_PER_READ, buffer);
        iterations++;
    } while (framesRead > 0 && iterations < MAX_ITERATIONS);

    drmp3_uninit(&mp3);
    return 0;
}
