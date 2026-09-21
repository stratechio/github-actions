#!/usr/bin/env bash
# Run every suite under test/ and report one PASS/FAIL line per suite. Exit 1
# if any suite failed, so CI can call this file alone. Usable from any working
# directory: each suite resolves the repository root from its own location.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

found=0
failed=0
for suite in "$TEST_DIR"/*.test.sh; do
  [ -e "$suite" ] || continue
  found=1
  name="$(basename "$suite" .test.sh)"
  echo "--- $name"
  if bash "$suite"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    failed=1
  fi
done

if [ "$found" -eq 0 ]; then
  echo "FAIL: no *.test.sh suites found in $TEST_DIR" >&2
  exit 1
fi
exit "$failed"
