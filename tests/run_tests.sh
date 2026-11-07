#!/usr/bin/env bash
# Run every test in tests/. Exit status: 0 all passed (skips allowed), 1 a failure,
# 2 refused to run because the host is not Intel.
#
# Each test exits 0 (pass), 1 (fail) or 77 (skip, with a reason on stdout). Skips are
# reported separately: a skip is not a pass, and a suite of nothing but skips exits
# non-zero rather than pretending to have verified anything.
#
# Written for macOS /bin/bash 3.2: no mapfile, no associative arrays.
#
# Usage: ./tests/run_tests.sh [test-name ...]

set -uo pipefail

if [ "$(uname -m)" != "x86_64" ]; then
  cat >&2 <<EOF
ABORT: this suite only verifies Intel (x86_64) macOS, and the host is $(uname -m).
       On Apple Silicon every check here either does not apply or passes for reasons
       unrelated to this repository, so a green run would be meaningless.
EOF
  exit 2
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=()
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    case "$name" in
      *.sh) tests+=("$name") ;;
      *)    tests+=("$TESTS_DIR/$name.sh") ;;
    esac
  done
else
  while IFS= read -r file; do
    tests+=("$file")
  done < <(find "$TESTS_DIR" -maxdepth 1 -name 'test_*.sh' | sort)
fi

[ "${#tests[@]}" -gt 0 ] || { echo "no tests found in $TESTS_DIR" >&2; exit 1; }

passed=0
failed=0
skipped=0
failed_names=""
skipped_names=""

for test in "${tests[@]}"; do
  name="$(basename "$test" .sh)"
  if [ ! -f "$test" ]; then
    echo "FAIL  $name (missing file $test)"
    failed=$((failed + 1))
    failed_names="$failed_names $name"
    continue
  fi

  echo "=== $name ==="
  bash "$test"
  status=$?
  case "$status" in
    0)  echo "--- $name PASSED";  passed=$((passed + 1)) ;;
    77) echo "--- $name SKIPPED"; skipped=$((skipped + 1)); skipped_names="$skipped_names $name" ;;
    *)  echo "--- $name FAILED (exit $status)"; failed=$((failed + 1)); failed_names="$failed_names $name" ;;
  esac
  echo
done

echo "================ summary ================"
echo "passed:  $passed"
echo "failed:  $failed${failed_names:+ ($failed_names )}"
echo "skipped: $skipped${skipped_names:+ ($skipped_names )}"

[ "$failed" -eq 0 ] || exit 1
[ "$passed" -gt 0 ] || { echo "nothing actually ran; a suite of only skips is not a pass" >&2; exit 1; }
exit 0
