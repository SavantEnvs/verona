# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for mayhemheroes/verona — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm-19 + libFuzzer + the build
# contract ENV; this only adds the per-commit build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t verona-commit:test .
#
# mayhem/build.sh vendors Verona's FetchContent deps (trieste/fmt/snmalloc/re2/cli11) into
# /opt/toolchains/vendor on this networked build; the cache is baked into the image so an offline
# (--network none) re-run of build.sh at the PATCH tier rebuilds from it.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# The vendored FetchContent deps live in a fixed, $HOME-independent cache that build.sh fills on the
# networked image build and re-reads offline on every PATCH re-run (SPEC §6.5).
USER root
RUN mkdir -p /opt/toolchains/vendor && chown 2000:2000 /opt/toolchains/vendor

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Pre-fills rlenv's compile cache (SPEC §6.2 item 18) so the patch grader's first rebuild is warm; the
# build.sh below never enables ccache itself.
RUN /opt/mayhem/ccache/prefill bash mayhem/build.sh

# Run the functional suite at build time — a failing suite fails the image build, so the commit
# image is guaranteed to build AND pass Verona's own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
