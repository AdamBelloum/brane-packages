#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
MIGRATOR="${MIGRATOR:-$ROOT_DIR/.venv/bin/brane-package-migrate}"
GH="${GH:-gh}"
RUNTIME_DIR="$ROOT_DIR/.admin-review"
WORKTREE_DIR=""
BRANCH=""
WORKTREE_CREATED=0
OPERATION_LOG=""

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/admin/package_admin.sh
  ./scripts/admin/package_admin.sh --list
  ./scripts/admin/package_admin.sh --remove <package-name> --confirm <package-name>

Curated package administration.

Enabled operations:
  - View current catalogue-backed packages and test fixtures.
  - Remove one selected package with its catalogue entry and reviewed intake evidence.
    The removal is validated, tested, and submitted as a Pull Request automatically.

The interface presents package outcomes rather than implementation steps.
USAGE
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

operation_failed() {
  printf 'The package operation could not be completed safely.\n' >&2
  if [[ -n "$OPERATION_LOG" ]]; then
    printf 'A support log was recorded at: %s\n' "$OPERATION_LOG" >&2
  fi
  exit 1
}

cleanup() {
  if [[ "$WORKTREE_CREATED" -eq 1 ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" \
      >>"$OPERATION_LOG" 2>&1 || true
  fi
  if [[ -n "$BRANCH" ]]; then
    git -C "$ROOT_DIR" branch -D "$BRANCH" >>"$OPERATION_LOG" 2>&1 || true
  fi
}
trap cleanup EXIT

catalogue_rows() {
  "$PYTHON" - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

import yaml

root = Path(sys.argv[1])
catalogue_path = root / "catalogue" / "packages.yml"
try:
    catalogue = yaml.safe_load(catalogue_path.read_text(encoding="utf-8"))
except (OSError, yaml.YAMLError) as error:
    raise SystemExit(f"Could not read the package catalogue: {error}")

entries = catalogue.get("packages") if isinstance(catalogue, dict) else None
if not isinstance(entries, list):
    raise SystemExit("The package catalogue does not contain a packages list.")

for entry in entries:
    if not isinstance(entry, dict):
        raise SystemExit("The package catalogue contains an invalid entry.")
    name = entry.get("name")
    classification = entry.get("classification")
    path = entry.get("path")
    if not all(isinstance(value, str) and value for value in (name, classification, path)):
        raise SystemExit("The package catalogue contains an incomplete entry.")
    print(f"{name}\t{classification}\t{path}")
PY
}

CATALOGUE_ENTRIES=()

load_catalogue_entries() {
  local rows entry

  rows="$(catalogue_rows)" || return 1
  CATALOGUE_ENTRIES=()

  while IFS= read -r entry; do
    [[ -n "$entry" ]] && CATALOGUE_ENTRIES+=("$entry")
  done <<<"$rows"
}

show_packages() {
  load_catalogue_entries     || fail "Could not read the current package catalogue."

  printf '\nCurrent curated packages\n'
  if ((${#CATALOGUE_ENTRIES[@]} == 0)); then
    printf '  No catalogue-backed packages are currently available.\n'
    return
  fi

  local entry name classification path index=1
  for entry in "${CATALOGUE_ENTRIES[@]}"; do
    IFS=$'\t' read -r name classification path <<<"$entry"
    printf '  %d) %s [%s] %s\n' "$index" "$name" "$classification" "$path"
    ((index += 1))
  done
}

find_catalogue_entry() {
  local requested_name="$1"
  local entry name classification path

  while IFS=$'\t' read -r name classification path; do
    if [[ "$name" == "$requested_name" ]]; then
      printf '%s\t%s\t%s\n' "$name" "$classification" "$path"
      return 0
    fi
  done < <(catalogue_rows)

  return 1
}

run_internal() {
  "$@" >>"$OPERATION_LOG" 2>&1
}

request_removal() {
  local package_name="$1"
  local confirmation="$2"
  local selected name classification path timestamp safe_name repository pr_url

  selected="$(find_catalogue_entry "$package_name")" \
    || fail "No current package named '$package_name' is available for removal."

  IFS=$'\t' read -r name classification path <<<"$selected"

  printf '\nSelected package\n'
  printf '  Name: %s\n' "$name"
  printf '  Classification: %s\n' "$classification"
  printf '  Repository path: %s\n' "$path"

  [[ "$confirmation" == "$name" ]] \
    || fail "Removal was not confirmed. Enter the exact package name: $name"

  [[ -x "$PYTHON" ]] || fail "The pinned Python interpreter is unavailable."
  [[ -x "$MIGRATOR" ]] || fail "The package migration tool is unavailable."
  command -v "$GH" >/dev/null 2>&1 \
    || fail "GitHub access is unavailable for this administrator environment."

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$RUNTIME_DIR/logs" "$RUNTIME_DIR/worktrees"
  OPERATION_LOG="$RUNTIME_DIR/logs/removal-$timestamp.log"
  : >"$OPERATION_LOG"

  run_internal git -C "$ROOT_DIR" rev-parse --is-inside-work-tree \
    || operation_failed
  run_internal "$GH" auth status \
    || operation_failed
  repository="$("$GH" repo view --json nameWithOwner --jq '.nameWithOwner' \
    2>>"$OPERATION_LOG")" || operation_failed
  [[ -n "$repository" ]] || operation_failed

  printf '\nPreparing a safe removal request …\n'
  run_internal git -C "$ROOT_DIR" fetch --no-tags origin \
    "refs/heads/main:refs/remotes/origin/main" || operation_failed

  safe_name="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-')"
  BRANCH="admin/remove-$safe_name-$timestamp"
  WORKTREE_DIR="$RUNTIME_DIR/worktrees/removal-$timestamp"

  run_internal git -C "$ROOT_DIR" worktree add -b "$BRANCH" \
    "$WORKTREE_DIR" origin/main || operation_failed
  WORKTREE_CREATED=1

  printf 'Validating the selected removal …\n'
  run_internal "$MIGRATOR" remove \
    --name "$name" \
    --repository-root "$WORKTREE_DIR" \
    --remove-review-evidence || operation_failed

  run_internal "$MIGRATOR" remove \
    --name "$name" \
    --repository-root "$WORKTREE_DIR" \
    --remove-review-evidence \
    --execute || operation_failed

  run_internal "$MIGRATOR" validate-repository \
    --repository-root "$WORKTREE_DIR" || operation_failed

  printf 'Running repository checks …\n'
  (
    cd "$WORKTREE_DIR"
    "$PYTHON" -m pytest -q \
      tests/test_discovery.py \
      tests/test_removal_review_evidence.py
  ) >>"$OPERATION_LOG" 2>&1 || operation_failed

  run_internal git -C "$WORKTREE_DIR" add --all || operation_failed
  if git -C "$WORKTREE_DIR" diff --cached --quiet; then
    operation_failed
  fi
  run_internal git -C "$WORKTREE_DIR" commit \
    -m "Remove package $name" || operation_failed
  run_internal git -C "$WORKTREE_DIR" push --set-upstream origin "$BRANCH" \
    || operation_failed

  pr_url="$("$GH" pr create \
    --repo "$repository" \
    --base main \
    --head "$BRANCH" \
    --title "Remove package: $name" \
    --body "Removes $name ($classification) from the curated package catalogue, package directory, and reviewed intake evidence." \
    2>>"$OPERATION_LOG")" || operation_failed
  [[ -n "$pr_url" ]] || operation_failed

  printf '\nRemoval request created.\n'
  printf '  Package: %s [%s]\n' "$name" "$classification"
  printf '  Repository validation: passed\n'
  printf '  Repository checks: passed\n'
  printf '  Pull request: %s\n' "$pr_url"
}

interactive_menu() {
  local choice selected name classification path confirmation
  local -a entries=()

  while true; do
    printf '\nCurated package administration\n'
    printf '  1) View current packages\n'
    printf '  2) Remove a package\n'
    printf '  3) Exit\n'
    read -r -p 'Select an operation: ' choice

    case "$choice" in
      1)
        show_packages
        ;;
      2)
        load_catalogue_entries           || fail "Could not read the current package catalogue."
        entries=("${CATALOGUE_ENTRIES[@]}")
        ((${#entries[@]} > 0)) || {
          printf 'No packages are available for removal.\n'
          continue
        }

        show_packages
        read -r -p 'Select package number: ' choice
        [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#entries[@]})) || {
          printf 'Selection is invalid.\n'
          continue
        }

        selected="${entries[choice - 1]}"
        IFS=$'\t' read -r name classification path <<<"$selected"
        printf 'To request removal of %s [%s], enter its exact name: ' \
          "$name" "$classification"
        read -r confirmation
        request_removal "$name" "$confirmation"
        ;;
      3)
        return
        ;;
      *)
        printf 'Selection is invalid.\n'
        ;;
    esac
  done
}

REMOVE_NAME=""
CONFIRMATION=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --remove)
      [[ $# -ge 2 ]] || fail "--remove requires a package name."
      REMOVE_NAME="$2"
      shift 2
      ;;
    --confirm)
      [[ $# -ge 2 ]] || fail "--confirm requires the exact package name."
      CONFIRMATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$LIST_ONLY" -eq 0 || -z "$REMOVE_NAME" ]] \
  || fail "Use either --list or --remove, not both."
[[ -z "$CONFIRMATION" || -n "$REMOVE_NAME" ]] \
  || fail "--confirm can only be used with --remove."

if [[ "$LIST_ONLY" -eq 1 ]]; then
  show_packages
elif [[ -n "$REMOVE_NAME" ]]; then
  [[ -n "$CONFIRMATION" ]] \
    || fail "--remove requires --confirm with the exact selected package name."
  request_removal "$REMOVE_NAME" "$CONFIRMATION"
else
  [[ -t 0 && -t 1 ]] || {
    usage >&2
    fail "Run with --list or --remove when standard input or output is not a terminal."
  }
  interactive_menu
fi
