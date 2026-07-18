#!/usr/bin/env bash
#
# mayhem/build.sh — build the Verona compiler, its fuzz harness, and its test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Produces:
#   /mayhem/verona-parser              in-process libFuzzer harness (ASan+UBSan+cov, DWARF-3)
#   /mayhem/verona-parser-standalone   run-once reproducer (same harness, no libFuzzer runtime)
#   /mayhem/build/                     cmake tree with the installed dist + registered ctest suite
#                                      (mayhem/test.sh only RUNS it)
#
# Verona pulls five deps via CMake FetchContent (trieste, fmt, snmalloc, re2, cli11). This build is
# AIR-GAPPED: the deps are vendored once (first, networked, build) into $VENDOR and thereafter the
# build re-runs OFFLINE from that cache (FETCHCONTENT_FULLY_DISCONNECTED). trieste pins snmalloc to a
# moving `main`; we pin the contemporaneous snmalloc SHA so the build is reproducible.
#
# Build time matters: the PATCH tier re-runs this script cold (after `git clean -ffdX`) under a 450 s
# limit, and the three unity compiles of the whole front-end dominate it. So the dep libraries are
# built alone (not Verona's own multi-TU executable, which the unity build replaces anyway), and the
# two independent unity compiles (test executable, instrumented fuzz object) run concurrently; the
# fuzz object is compiled once and linked twice (libFuzzer binary, standalone reproducer).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (base image exports these), with parameter-expansion fallbacks.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# ─────────────────────────────────────────────────────────────────────────────
# 0) Vendor the FetchContent deps (once, networked) — thereafter the build is offline.
#    trieste/fmt/re2/cli11 are pinned to the SHAs verona@bfca50d / trieste@b466068 resolve to.
#    snmalloc is declared by trieste as a MOVING `main`; we pin it to a fixed main SHA that (a)
#    compiles under the base image's clang-19 — the older 2024-era snmalloc trips clang-19's hard
#    `-Wmissing-template-arg-list-after-template-kw` error in localalloc.h — and (b) passes Verona's
#    full golden-file suite with this trieste. Pinning a SHA keeps the build reproducible.
# ─────────────────────────────────────────────────────────────────────────────
# A fixed, $HOME-independent cache (created by mayhem/Dockerfile): the PATCH re-run is not CI's $HOME.
VENDOR="${VENDOR:-/opt/toolchains/vendor}"
vendor_dep() { # <name> <url> <sha>
  local name="$1" url="$2" sha="$3"
  local dir="$VENDOR/$name"
  if [ -d "$dir/.git" ]; then return 0; fi
  echo "[build.sh] vendoring $name @ $sha"
  git clone --quiet "$url" "$dir"
  git -C "$dir" checkout --quiet "$sha"
}
mkdir -p "$VENDOR"
vendor_dep trieste  https://github.com/microsoft/trieste  b466068270471ccc9c5f5ddd543bd6e2fb02ad87
vendor_dep fmt      https://github.com/fmtlib/fmt         a33701196adfad74917046096bf5a2aa0ab0bb50
vendor_dep snmalloc https://github.com/microsoft/snmalloc 481b6484ab8b1dd5cdf01a855d97152d1df15752
vendor_dep re2      https://github.com/google/re2         4be240789d5b322df9f02b7e19c8651f3ccbf205
vendor_dep cli11    https://github.com/CLIUtils/CLI11      b9be5b9444772324459989177108a6a65b8b2769

# Defensive: drop snmalloc's `-Werror` from its build-affecting warning lines (identified by the
# accompanying `-Wundef`) so a stray clang-19 warning can't fail the build; leave the
# `check_cxx_compiler_flag` feature-probes (no `-Wundef`) intact.
if grep -q -- '-Wundef.* -Werror' "$VENDOR/snmalloc/CMakeLists.txt"; then
  sed -i '/-Wundef/ s/ -Werror//' "$VENDOR/snmalloc/CMakeLists.txt"
fi

# trieste@b466068's CMake doesn't propagate snmalloc's include dir to trieste's own targets, so
# `#include <snmalloc/...>` from trieste headers needs the dir on the compile line explicitly. This
# is a compile include-path fix, NOT a sanitizer or source edit.
SNMALLOC_INC="-I$VENDOR/snmalloc/src"

FC_ARGS=(
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  -DFETCHCONTENT_SOURCE_DIR_TRIESTE="$VENDOR/trieste"
  -DFETCHCONTENT_SOURCE_DIR_FMT="$VENDOR/fmt"
  -DFETCHCONTENT_SOURCE_DIR_SNMALLOC="$VENDOR/snmalloc"
  -DFETCHCONTENT_SOURCE_DIR_RE2="$VENDOR/re2"
  -DFETCHCONTENT_SOURCE_DIR_CLI11="$VENDOR/cli11"
)

VERONA_SRCS=(src/lang.cc src/lookup.cc src/parse.cc src/subtype.cc)
while IFS= read -r p; do VERONA_SRCS+=("$p"); done < <(ls src/passes/*.cc)
HARNESS_INCS=(-I"$SRC/src" -I"$VENDOR/trieste/include" -I"$VENDOR/fmt/include"
              -I"$VENDOR/re2" -I"$VENDOR/cli11/include" "$SNMALLOC_INC")

# ─────────────────────────────────────────────────────────────────────────────
# 1) CONFIGURE + DEP LIBRARIES (project's NORMAL flags). Only the static libs the unity builds link
#    (re2, fmt, snmalloc's static shim) are built; the configured tree still carries the ctest suite
#    that mayhem/test.sh RUNS.
# ─────────────────────────────────────────────────────────────────────────────
BUILD_DIR="$SRC/build"
# Always configure fresh: a surviving tree caches the previous run's compiler path (the ccache masquerade
# at image build, plain clang at a re-run), and CMake then wipes the cache, dropping the offline FetchContent
# settings mid-configure.
rm -rf "$BUILD_DIR"
cmake -S "$SRC" -B "$BUILD_DIR" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SNMALLOC_INC $COVERAGE_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SNMALLOC_INC $COVERAGE_FLAGS" \
  "${FC_ARGS[@]}"
cmake --build "$BUILD_DIR" -j"$MAYHEM_JOBS" --target re2 fmt snmallocshim-static

# ─────────────────────────────────────────────────────────────────────────────
# 2) UNITY `verona` executable (NORMAL flags). Verona's multi-TU build SEGVs before main on a
#    static-init-order fiasco in wf.h's inline DSL globals; compiling all of src (incl. main.cc) as
#    ONE TU makes init order deterministic. Same sources, same flags — just one TU. It is installed
#    as both binaries the ctest suite invokes (dist for golden tests; build/src for `verona test -f`).
# 3) FUZZ HARNESS (unity: all of src EXCEPT main.cc, then the harness). Instrument the WHOLE Verona
#    front-end with $SANITIZER_FLAGS + $DEBUG_FLAGS so ASan/UBSan see Verona (not just the harness)
#    and backtraces resolve to Verona source with DWARF-3 symbols. re2/fmt are linked as plain deps.
#    Compiled ONCE to an object (libFuzzer coverage instrumentation, no runtime), linked below as the
#    libFuzzer binary and as the standalone reproducer.
#    2 and 3 are independent, so they compile concurrently.
# ─────────────────────────────────────────────────────────────────────────────
EXE_UNITY=/tmp/verona_exe_unity.cc
{ echo '#include <trieste/driver.h>'; echo '#include "lang.h"'
  for f in "${VERONA_SRCS[@]}" src/main.cc; do echo "#include \"$SRC/$f\""; done
} > "$EXE_UNITY"

FUZZ_UNITY=/tmp/verona_fuzz_unity.cc
{ echo '#include <trieste/driver.h>'; echo '#include "lang.h"'
  for f in "${VERONA_SRCS[@]}"; do echo "#include \"$SRC/$f\""; done
  echo "#include \"$SRC/mayhem/verona-parser/verona-parser.cc\""
  # ccache does not hash the -fsanitize-ignorelist file; with CCACHE_COMMENTS=1 it hashes comments, so
  # this line keys the cached object on the ignorelist's content (SPEC §6.2 item 17).
  echo "// ubsan-ignorelist sha256: $(sha256sum "$SRC/mayhem/verona-parser/ubsan-ignorelist.txt" | cut -d' ' -f1)"
} > "$FUZZ_UNITY"

UBSAN_IGNORE="-fsanitize-ignorelist=$SRC/mayhem/verona-parser/ubsan-ignorelist.txt"

"$CXX" -std=c++20 -O2 -DNDEBUG "${HARNESS_INCS[@]}" "$EXE_UNITY" \
  "$BUILD_DIR/_deps/re2-build/libre2.a" \
  "$BUILD_DIR/_deps/fmt-build/libfmt.a" \
  "$BUILD_DIR/_deps/snmalloc-build/libsnmallocshim-static.a" \
  -lpthread -latomic -o /tmp/verona-unity &
exe_pid=$!

"$CXX" -std=c++20 -O2 -DNDEBUG $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_IGNORE -fsanitize=fuzzer-no-link \
  "${HARNESS_INCS[@]}" -c "$FUZZ_UNITY" -o /tmp/verona_fuzz_unity.o &
fuzz_pid=$!

rc=0
wait "$exe_pid" || { echo "[build.sh] unity verona executable failed" >&2; rc=1; }
wait "$fuzz_pid" || { echo "[build.sh] unity fuzz object failed" >&2; rc=1; }
[ "$rc" -eq 0 ] || exit 1

# The dist the ctest golden tests run (what `cmake --install` of the multi-TU target would produce).
rm -rf "$BUILD_DIR/dist"
mkdir -p "$BUILD_DIR/dist/verona" "$BUILD_DIR/src"
cp -r "$SRC/std" "$BUILD_DIR/dist/verona/std"
cp /tmp/verona-unity "$BUILD_DIR/src/verona"
cp /tmp/verona-unity "$BUILD_DIR/dist/verona/verona"

# LeakSanitizer is disabled at build time for every target (ASan and UBSan stay on and halting).
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o

DEPS_LIBS=("$BUILD_DIR/_deps/re2-build/libre2.a" "$BUILD_DIR/_deps/fmt-build/libfmt.a")
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE /tmp/verona_fuzz_unity.o /tmp/lsan_off.o "${DEPS_LIBS[@]}" \
  -lpthread -latomic -o "$SRC/verona-parser"

# 3b) Standalone reproducer: the same harness object, linked against the run-once driver and libFuzzer's
#     coverage callbacks (no fuzzing main) instead of the libFuzzer engine: takes input files, runs
#     LLVMFuzzerTestOneInput once per file, crashes naturally.
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
FUZZER_NO_MAIN="$("$CXX" -print-file-name="libclang_rt.fuzzer_no_main-$(uname -m).a")"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/verona_fuzz_unity.o /tmp/lsan_off.o /tmp/standalone_main.o \
  "$FUZZER_NO_MAIN" "${DEPS_LIBS[@]}" -lpthread -latomic -o "$SRC/verona-parser-standalone"

echo "[build.sh] done: $(ls -la "$SRC"/verona-parser "$SRC"/verona-parser-standalone)"
