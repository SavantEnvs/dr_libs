# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) -- builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base), which already carries clang-19 + libFuzzer + StandaloneFuzzTargetMain.
#
# dr_libs is three single-header decoders (dr_flac.h, dr_wav.h, dr_mp3.h) with no build system of
# their own for the libraries -- only extra apt packages needed are reference libs/encoders for
# the upstream comparison test suite:
#   cmake                   -- upstream's own CMakeLists.txt builds the comparison test suite.
#   libflac-dev + flac CLI  -- flac_* tests compare dr_flac against libFLAC; the `flac` CLI
#                              encodes deterministic FLAC test vectors in mayhem/gen_vectors.py.
#   libsndfile1-dev/-1      -- wav_* tests dlopen libsndfile as ground truth for dr_wav.
#   lame                    -- encodes deterministic MP3 test vectors in mayhem/gen_vectors.py.
FROM ghcr.io/savantenvs/base:20260621

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        cmake libflac-dev libsndfile1-dev libsndfile1 flac lame && \
    rm -rf /var/lib/apt/lists/*

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); an empty value breaks clang, so it is
# never baked as ENV -- build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declared WITHOUT a default so an unset arg lets the base ENV flow through to build.sh, while an
# explicit --build-arg (including an EMPTY one, for a no-sanitizer build) overrides it.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Upstream's own comparison test suite (dr_flac vs libFLAC, dr_wav vs libsndfile, dr_mp3
# self-consistency), built above with NORMAL flags -- a failing suite fails the image.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
