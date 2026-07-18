#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Verona's own functional test suite (built by mayhem/build.sh) and report CTRF.
#
# The suite is Verona's upstream ctest (testsuite/): for each .verona input it runs the compiler,
# dumps every compiler pass, and DIFFS the dumps + exit code against checked-in golden files, plus
# the built-in `verona test -f` well-formedness self-test. This asserts OUTPUT/BEHAVIOUR, not just
# exit status — a patch that "fixes" a bug by making the compiler exit(0) or no-op produces wrong
# dumps and FAILS here. This script only RUNS the pre-built suite; it never builds.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

BUILD_DIR="$SRC/build"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other] — writes CTRF file + stdout marker,
# returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILD_DIR" ] || [ ! -x "$BUILD_DIR/dist/verona/verona" ]; then
  echo "test.sh: ctest tree / installed verona missing at $BUILD_DIR — build.sh did not produce the suite" >&2
  emit_ctrf "verona-ctest" 0 1
  exit 1
fi

LOG=$(mktemp)
( cd "$BUILD_DIR" && ctest --output-on-failure -j"$MAYHEM_JOBS" ) 2>&1 | tee "$LOG"

# ctest end line: "<pct>% tests passed, <F> tests failed out of <T>"
summary=$(grep -E "tests (passed|failed)" "$LOG" | tail -1)
total=$(echo "$summary"  | sed -nE 's/.* out of ([0-9]+).*/\1/p')
failed=$(echo "$summary" | sed -nE 's/.*, ([0-9]+) tests failed .*/\1/p')
rm -f "$LOG"

if [ -z "${total:-}" ]; then
  echo "test.sh: could not parse ctest summary" >&2
  emit_ctrf "verona-ctest" 0 1
  exit 1
fi
: "${failed:=0}"
passed=$(( total - failed ))

emit_ctrf "verona-ctest" "$passed" "$failed"
