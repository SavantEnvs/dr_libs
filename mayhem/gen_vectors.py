#!/usr/bin/env python3
"""Deterministic test vectors for the upstream dr_libs test suite.

Synthesizes PCM WAV files with the python stdlib, then encodes FLAC/MP3 vectors with the
in-image `flac` and `lame` encoders (installed by mayhem/Dockerfile -- no network needed).
The upstream tests scan these fixed directories:
    tests/testvectors/wav/tests       (wav_decoding: dr_wav vs libsndfile)
    tests/testvectors/flac/testbench  (flac_decoding/flac_seeking: dr_flac vs libFLAC)
    tests/testvectors/mp3/tests       (mp3_basic/mp3_extract: dr_mp3 self-consistency)
"""
import math
import os
import struct
import subprocess
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAV_DIR = os.path.join(ROOT, "tests/testvectors/wav/tests")
FLAC_DIR = os.path.join(ROOT, "tests/testvectors/flac/testbench")
MP3_DIR = os.path.join(ROOT, "tests/testvectors/mp3/tests")
for d in (WAV_DIR, FLAC_DIR, MP3_DIR):
    os.makedirs(d, exist_ok=True)


def synth(path, channels, rate, seconds, sampwidth=2):
    """Multi-tone PCM: sine + harmonic, per-channel detune -- deterministic."""
    n = int(rate * seconds)
    frames = bytearray()
    amp = (1 << (8 * sampwidth - 1)) - 2
    for i in range(n):
        t = i / rate
        for c in range(channels):
            f = 440.0 + 110.0 * c
            v = 0.5 * math.sin(2 * math.pi * f * t) + 0.25 * math.sin(2 * math.pi * 3 * f * t)
            s = int(amp * v * 0.9)
            if sampwidth == 1:
                frames.append((s >> 8) + 128 & 0xFF)  # 8-bit WAV is unsigned
            elif sampwidth == 2:
                frames += struct.pack("<h", s)
            elif sampwidth == 3:
                frames += struct.pack("<i", s)[:3]
    w = wave.open(path, "wb")
    w.setnchannels(channels)
    w.setsampwidth(sampwidth)
    w.setframerate(rate)
    w.writeframes(bytes(frames))
    w.close()
    return path


wavs = [
    synth(os.path.join(WAV_DIR, "sine_mono_44k_s16.wav"), 1, 44100, 1.0, 2),
    synth(os.path.join(WAV_DIR, "sine_stereo_48k_s16.wav"), 2, 48000, 1.0, 2),
    synth(os.path.join(WAV_DIR, "sine_mono_8k_u8.wav"), 1, 8000, 0.5, 1),
    synth(os.path.join(WAV_DIR, "sine_stereo_22k_s24.wav"), 2, 22050, 0.5, 3),
]

# FLAC vectors: s16 sources at different compression levels (flac adds a seek table by default,
# which flac_seeking requires).
for src, level in ((wavs[0], "-0"), (wavs[1], "-8")):
    out = os.path.join(FLAC_DIR, os.path.basename(src).replace(".wav", level.replace("-", "_l") + ".flac"))
    subprocess.run(["flac", "--silent", "--force", level, "-o", out, src], check=True)

# MP3 vectors (s16 sources only; lame rejects u8/s24 wavs without extra flags). mp3_extract needs
# a vector whose filename contains "mono" (see mayhem/test.sh).
for src, kbps in ((wavs[0], "64"), (wavs[1], "128")):
    out = os.path.join(MP3_DIR, os.path.basename(src).replace(".wav", ".mp3"))
    subprocess.run(["lame", "--quiet", "-b", kbps, src, out], check=True)

print("test vectors OK:", len(wavs), "wav /", len(os.listdir(FLAC_DIR)), "flac /", len(os.listdir(MP3_DIR)), "mp3")
