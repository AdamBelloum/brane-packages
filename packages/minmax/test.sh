#!/usr/bin/env bash
#
# Interactive local test for the minmax package.
#
# This test registers, or safely reuses, the tracked deterministic CSV fixture
# as local Brane Data. It then asks the operator to execute and attest the max
# and min package actions.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"
FIXTURE_MANIFEST="$REPOSITORY_ROOT/tests/fixtures/minmax/data.yml"
FIXTURE_PATH="$REPOSITORY_ROOT/tests/fixtures/minmax/numbers.csv"
DATASET_NAME="minmax-test-data"

BRANE_BIN="${BRANE_BIN:-$HOME/.local/bin/brane}"

if [[ ! -x "$BRANE_BIN" ]]; then
  printf 'minmax test: Brane CLI is unavailable or not executable: %s\n' \
    "$BRANE_BIN" >&2
  exit 1
fi

if [[ ! -f "$FIXTURE_MANIFEST" || ! -f "$FIXTURE_PATH" ]]; then
  printf 'minmax test: fixture files are missing below: %s\n' \
    "$REPOSITORY_ROOT/tests/fixtures/minmax" >&2
  exit 1
fi

if registered_path="$("$BRANE_BIN" data path "$DATASET_NAME" 2>/dev/null)"; then
  if [[ "$registered_path" != "$FIXTURE_PATH" ]]; then
    printf "minmax test: local Data '%s' already exists at a different path:\n" \
      "$DATASET_NAME" >&2
    printf '  registered: %s\n' "$registered_path" >&2
    printf '  expected:   %s\n' "$FIXTURE_PATH" >&2
    printf 'Refusing to replace an existing local Data asset.\n' >&2
    exit 1
  fi

  printf "Reusing local fixture Data '%s': %s\n" \
    "$DATASET_NAME" "$registered_path"
else
  printf 'Registering local fixture Data asset from: %s\n' "$FIXTURE_MANIFEST"
  "$BRANE_BIN" data build "$FIXTURE_MANIFEST"
fi

# shellcheck source=scripts/lib/package_test_harness.sh
source "$REPOSITORY_ROOT/scripts/lib/package_test_harness.sh"

brane_package_test_begin "$PACKAGE_DIR"

brane_package_test_case \
  "max" \
  "column=value; file=minmax-test-data" \
  "the displayed value.txt content is exactly 9.25" \
  "value.txt"

brane_package_test_case \
  "min" \
  "column=value; file=minmax-test-data" \
  "the displayed value.txt content is exactly -2" \
  "value.txt"

brane_package_test_finish
