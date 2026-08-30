#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:    scripts/developer/package_dev_wizard.sh
# Purpose: Guide a package author through preparing and submitting a new Brane
#          package. This wizard never approves, merges, or deploys a package.
# Version: 2.7.0
# Date:    2026-08-29
# Author:  Adam Belloum
# -----------------------------------------------------------------------------
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PYTHON="$ROOT_DIR/.venv/bin/python"
MIGRATOR="$ROOT_DIR/.venv/bin/brane-package-migrate"
GH="${GH:-gh}"
SCHEMA="$ROOT_DIR/schemas/migration-manifest.schema.yml"
INTAKE_DIR="$ROOT_DIR/intake"
BRANE_BASELINE="${BRANE_BASELINE:-3.0.0}"

# ── Colours (disabled when not a terminal) ────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
  GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
else
  BOLD=''; DIM=''; RESET=''; GREEN=''; YELLOW=''; RED=''; CYAN=''
fi

# ── UI helpers ────────────────────────────────────────────────────────────────
banner() {
  printf '\n'
  printf "${CYAN}${BOLD}%s${RESET}\n" "╔══════════════════════════════════════════╗"
  printf "${CYAN}${BOLD}%s${RESET}\n" "║      Brane Package Submission Wizard     ║"
  printf "${CYAN}${BOLD}%s${RESET}\n" "╚══════════════════════════════════════════╝"
  printf '\n'
}

step() {
  printf '\n'
  printf "${BOLD}${CYAN}── Step %s of %s  %s ${RESET}\n" "$1" "$2" "$3"
  printf "${DIM}%s${RESET}\n" "────────────────────────────────────────────"
}

ok()    { printf "  ${GREEN}✓${RESET}  %s\n" "$1"; }
info()  { printf "  ${CYAN}ⓘ${RESET}  %s\n" "$1"; }
warn()  { printf "  ${YELLOW}⚠${RESET}  %s\n" "$1"; }
fail()  { printf "\n${RED}${BOLD}Problem:${RESET} %s\n\n" "$1" >&2; exit 1; }
blank() { printf '\n'; }
divider() { printf "${DIM}%s${RESET}\n" "────────────────────────────────────────────"; }

# ── Package file inventory and final report ─────────────────────────────────
PACKAGE_FILES=()
SOURCE_FILES=()
TEST_FILES=()
FUNCTIONAL_TEST_STATUS="not-run"

scan_package_files() {
  local file relative

  PACKAGE_FILES=()
  SOURCE_FILES=()
  TEST_FILES=()

  while IFS= read -r -d '' file; do
    relative="${file#"$SOURCE_DIR"/}"
    PACKAGE_FILES+=("$relative")

    case "$relative" in
      container.yml)
        ;;
      tests/*|test.*|test_*|*_test.*|*_tests.*)
        TEST_FILES+=("$relative")
        ;;
      *)
        SOURCE_FILES+=("$relative")
        ;;
    esac
  done < <(find "$SOURCE_DIR" -type f -print0 | sort -z)
}

report_ok()   { printf "  [OK]   %s
" "$1"; }
report_fail() { printf "  [FAIL] %s
" "$1"; }

package_file_report() {
  local timestamp total_passed=0 total_failed=0 file

  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  blank
  printf '%s
' '──────────────────────────────────────────────────────────────────────'
  printf '  Package file and test report — %s
' "$timestamp"
  printf '%s
' '──────────────────────────────────────────────────────────────────────'
  blank

  report_ok "package | configuration: container.yml"
  total_passed=$((total_passed + 1))

  for file in "${SOURCE_FILES[@]}"; do
    report_ok "package | source file: $file"
    total_passed=$((total_passed + 1))
  done

  if (( ${#SOURCE_FILES[@]} == 0 )); then
    report_fail 'package | source files: none found'
    total_failed=$((total_failed + 1))
  fi

  if (( ${#TEST_FILES[@]} == 0 )); then
    report_fail 'package | test file: none found'
    total_failed=$((total_failed + 1))
  else
    for file in "${TEST_FILES[@]}"; do
      report_ok "package | test file present: $file"
      total_passed=$((total_passed + 1))
    done
  fi

  case "$FUNCTIONAL_TEST_STATUS" in
    passed)
      report_ok 'package | functional test: passed'
      total_passed=$((total_passed + 1))
      ;;
    failed)
      report_fail 'package | functional test: failed'
      total_failed=$((total_failed + 1))
      ;;
    *)
      report_fail 'package | functional test: not run'
      total_failed=$((total_failed + 1))
      ;;
  esac

  if [[ "$BRANCH" == 'main' || "$BRANCH" == 'master' ]]; then
    report_fail "git     | active branch: $BRANCH (a package must use a working branch)"
    total_failed=$((total_failed + 1))
  else
    report_ok "git     | active branch: $BRANCH"
    total_passed=$((total_passed + 1))
  fi

  blank
  printf '  Total: %s passed  %s failed
' "$total_passed" "$total_failed"
  printf '%s
' '──────────────────────────────────────────────────────────────────────'
  blank

  if (( total_failed == 0 )); then
    report_ok 'Package file requirements and functional testing are complete.'
    return 0
  fi

  report_fail 'Package submission checks are incomplete.'
  return 1
}

# ask <prompt> [default]
# Prompt is written to stderr so the subshell $() captures only the answer.
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    printf "  ${BOLD}▶${RESET} %s [%s]: " "$prompt" "$default" >&2
  else
    printf "  ${BOLD}▶${RESET} %s: " "$prompt" >&2
  fi
  read -r answer </dev/tty
  printf '%s' "${answer:-$default}"
}

# yesno <prompt> [Y|N]
yesno() {
  # Prompt and validation feedback go to stderr so $(yesno ...) captures
  # only the final answer: yes or no.
  local prompt="$1" default="${2:-N}" answer

  while true; do
    printf "  ${BOLD}▶${RESET} %s (y/n) [%s]: " "$prompt" "$default" >&2
    read -r answer </dev/tty
    answer="${answer:-$default}"

    case "$answer" in
      y|Y|yes|Yes|YES) printf 'yes'; return ;;
      n|N|no|No|NO)    printf 'no';  return ;;
      *) printf "  ${YELLOW}⚠${RESET}  Please answer y or n.\n" >&2 ;;
    esac
  done
}

require() { [[ -n "${1// /}" ]] || fail 'This answer is required. Please start again.'; }

report_stop() {
  # report_stop <package> <headline> [extra lines…]
  local pkg="$1" headline="$2"; shift 2
  blank
  printf "${BOLD}Package submission report${RESET}\n"
  divider
  printf "  Package : ${BOLD}%s${RESET}\n" "$pkg"
  blank
  printf "  ${BOLD}%s${RESET}\n" "$headline"
  for msg in "$@"; do
    [[ -z "$msg" ]] && blank || printf "     %s\n" "$msg"
  done
  divider
  blank
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ -x "$PYTHON"   ]] || fail 'Python virtual environment not found. Run repository setup first.'
[[ -x "$MIGRATOR" ]] || fail 'Package migration tool not found. Run repository setup first.'
[[ -f "$SCHEMA"   ]] || fail "Migration manifest schema not found: $SCHEMA"
git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail 'This directory is not inside a Git repository.'
mkdir -p "$INTAKE_DIR"

# ── Welcome ───────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
banner
printf '%s\n' 'This wizard guides you through preparing a new Brane package for review.'
printf '%s\n' 'It will check your package, record your details, and help you submit a'
printf '%s\n' 'Pull Request. The package is not accepted until an administrator reviews'
printf '%s\n' 'and tests it.'
blank
info 'You do not need Git experience. The wizard handles Git for you.'
info 'Each step explains what is happening and why.'

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — Select the package
# ═════════════════════════════════════════════════════════════════════════════
step 1 5 "Select your package"
printf '%s\n' 'Provide the path to the folder that contains your Brane package.'
printf '%s\n' 'The folder must contain a container.yml file.'
blank

SOURCE_DIR="$(ask 'Path to your package folder')"
SOURCE_DIR="${SOURCE_DIR%/}"

[[ -d "$SOURCE_DIR" ]] \
  || fail "The folder \"$SOURCE_DIR\" does not exist. Check the path and try again."
[[ -f "$SOURCE_DIR/container.yml" ]] \
  || fail "No container.yml was found in \"$SOURCE_DIR\". Make sure you are pointing to the package top-level folder."

PACKAGE_NAME="$(basename "$SOURCE_DIR")"
ok "Package folder found: $SOURCE_DIR"
ok "Package name: $PACKAGE_NAME"

scan_package_files
scan_package_files

# ── Duplicate-name guard ──────────────────────────────────────────────────────
if [[ -e "$ROOT_DIR/packages/$PACKAGE_NAME" || -e "$ROOT_DIR/test-fixtures/$PACKAGE_NAME" ]]; then
  report_stop "$PACKAGE_NAME" "ⓘ  Package already exists in this catalogue." \
    "A package named \"$PACKAGE_NAME\" is already registered." \
    "" \
    "This wizard is for submitting NEW packages only." \
    "To update an existing package, use the package-update workflow" \
    "or contact an administrator." \
    "" \
    "No repository files were changed."
  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — Prepare the Git branch
# ═════════════════════════════════════════════════════════════════════════════
step 2 5 "Check your Git branch"
printf '%s\n' 'The wizard checks whether you are on main or on a working branch.'
blank

CURRENT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
START_BRANCH="$CURRENT_BRANCH"
[[ -n "$CURRENT_BRANCH" ]] \
  || fail 'Git is in a detached state. Switch to main or a working branch, then run the wizard again.'

printf '%s\n' '──────────────────────────────────────────────────────────────────────'
printf '%s\n' '  Git branch status'
printf '%s\n' '──────────────────────────────────────────────────────────────────────'
blank

if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
  printf '  [INFO] Current branch: %s\n' "$CURRENT_BRANCH"
  printf '%s\n' '  [INFO] Status: main branch — a package working branch is needed.'
  blank

  SAFE_PACKAGE_NAME="$(printf '%s' "$PACKAGE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9._-')"
  BRANCH="package/${SAFE_PACKAGE_NAME}-$(date '+%Y%m%d-%H%M%S')"

  printf '%s\n' '  Proposed working branch:'
  printf '    %s\n' "$BRANCH"
  blank

  if [[ "$(yesno 'Create and switch to this branch now' Y)" != "yes" ]]; then
    info 'No branch was created. The wizard will now exit without changing package files.'
    exit 0
  fi

  git -C "$ROOT_DIR" checkout -b "$BRANCH" >/dev/null

  blank
  printf '  [OK]   Active branch: %s\n' "$BRANCH"
  printf '%s\n' '  [OK]   Status: working branch created and selected.'
else
  BRANCH="$CURRENT_BRANCH"

  printf '  [OK]   Active branch: %s\n' "$BRANCH"
  printf '%s\n' '  [OK]   Status: existing working branch selected.'
fi

blank
printf '%s\n' '──────────────────────────────────────────────────────────────────────'
blank

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Package information
# ═════════════════════════════════════════════════════════════════════════════
step 3 5 "Package information"
printf '%s\n' 'The following questions help the administrator understand your package.'
printf '%s\n' 'This information will be stored alongside the package in the catalogue.'
blank

MANIFEST="$INTAKE_DIR/${PACKAGE_NAME}-review.yml"
if [[ -e "$MANIFEST" ]]; then
  warn "A previous draft was found for \"$PACKAGE_NAME\"."
  if [[ "$(yesno 'Replace it with a fresh scan' N)" != yes ]]; then
    info 'Keeping the existing draft. Nothing was changed.'; exit 0
  fi
  rm -f "$MANIFEST"
fi

printf '%s\n' 'Scanning the package folder…'
"$MIGRATOR" discover --source "$SOURCE_DIR" --output "$MANIFEST" >/dev/null
ok 'Package folder structure is valid'
blank

printf '%s\n' 'What is the primary purpose of this package?'
printf '%s\n' '  1)  A reusable analysis or workflow package for production use'
printf '%s\n' '  2)  An example, tutorial, or test package'
blank
while true; do
  KIND="$(ask 'Enter 1 or 2' 1)"
  case "$KIND" in
    1) CLASSIFICATION=reusable; TARGET_PATH="packages/$PACKAGE_NAME"; break ;;
    2) CLASSIFICATION=fixture;  TARGET_PATH="test-fixtures/$PACKAGE_NAME"; break ;;
    *) warn 'Please enter 1 or 2.' ;;
  esac
done
blank

DESCRIPTION="$(ask 'Describe what the package does (one or two sentences)')"
require "$DESCRIPTION"
blank

DEFAULT_NAME="$(git -C "$ROOT_DIR" config user.name 2>/dev/null || true)"
AUTHOR="$(ask 'Your full name' "$DEFAULT_NAME")"
require "$AUTHOR"

CONTACT="$(ask 'Contact e-mail address (optional)')"
blank

USER_DATA="$(yesno 'Does this package process data provided by a user' N)"
blank

printf '%s\n' 'Does the package include data files?'
printf '%s\n' '  1)  No data files'
printf '%s\n' '  2)  Small synthetic or example data only'
printf '%s\n' '  3)  Real or potentially sensitive data'
blank
while true; do
  DATA="$(ask 'Enter 1, 2, or 3' 1)"
  case "$DATA" in
    1) BUNDLED=none;                    break ;;
    2) BUNDLED=synthetic-fixtures-only; break ;;
    3) fail 'Packages must not contain real or sensitive data. Remove the data files, replace them with synthetic examples, or contact an administrator.' ;;
    *) warn 'Please enter 1, 2, or 3.' ;;
  esac
done
blank

LICENCE="$(ask 'Licence (e.g. MIT, Apache-2.0) — leave blank if unknown')"
blank

# ── Confirmation summary ───────────────────────────────────────────────────────
divider
printf "  ${BOLD}Please confirm your submission details:${RESET}\n"
blank
printf "  %-14s %s\n" "Package:"      "$PACKAGE_NAME"
printf "  %-14s %s\n" "Description:"  "$DESCRIPTION"
printf "  %-14s %s\n" "Destination:"  "$TARGET_PATH"
printf "  %-14s %s\n" "Maintainer:"   "$AUTHOR"
[[ -n "$CONTACT" ]] && printf "  %-14s %s\n" "Contact:"    "$CONTACT"
[[ -n "$LICENCE" ]] && printf "  %-14s %s\n" "Licence:"    "$LICENCE"
printf "  %-14s %s\n" "User data:"    "$USER_DATA"
printf "  %-14s %s\n" "Bundled data:" "$BUNDLED"
divider
blank

[[ "$(yesno 'Are these details correct' Y)" == yes ]] \
  || { info 'Nothing was changed. Run the wizard again when ready.'; exit 0; }

# ── Write curation metadata into the manifest ─────────────────────────────────
MANIFEST="$MANIFEST" \
CLASSIFICATION="$CLASSIFICATION" \
TARGET_PATH="$TARGET_PATH" \
AUTHOR="$AUTHOR" \
CONTACT="$CONTACT" \
DESCRIPTION="$DESCRIPTION" \
USER_DATA="$USER_DATA" \
BUNDLED="$BUNDLED" \
LICENCE="$LICENCE" \
BRANE_BASELINE="$BRANE_BASELINE" \
"$PYTHON" - <<'PY'
import os
from pathlib import Path
import yaml

p = Path(os.environ['MANIFEST'])
d = yaml.safe_load(p.read_text(encoding='utf-8'))
c = d.get('candidates', [])
if len(c) != 1:
    raise SystemExit('The package scan did not produce exactly one candidate.')

author  = os.environ['AUTHOR'].strip()
contact = os.environ['CONTACT'].strip()
licence = os.environ['LICENCE'].strip()

c[0].update({
    'classification': os.environ['CLASSIFICATION'],
    'action':         'migrate',
    'target_path':    os.environ['TARGET_PATH'],
    'author': {
        'name': author,
        **({'contact': contact} if contact else {}),
    },
    'curation': {
        'status':      'candidate',
        'description': os.environ['DESCRIPTION'].strip(),
        'maintainers': [author],
        'compatibility': {
            'architectures':  ['x86_64'],
            'brane_baseline': os.environ['BRANE_BASELINE'],
        },
        'data_handling': {
            'accepts_user_data': os.environ['USER_DATA'] == 'yes',
            'bundled_data':      os.environ['BUNDLED'],
        },
        **({'licence': licence} if licence else {}),
    },
})
c[0].pop('review_required', None)
p.write_text(yaml.safe_dump(d, sort_keys=False, allow_unicode=True), encoding='utf-8')
PY

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — Validate and add the package
# ═════════════════════════════════════════════════════════════════════════════
manifest_checklist() {
  local manifest_path="$1"

  "$PYTHON" - "$manifest_path" <<'MANIFEST_PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
candidate = document["candidates"][0]
author = candidate["author"]
curation = candidate["curation"]
compatibility = curation["compatibility"]
data_handling = curation["data_handling"]

def value(item):
    if isinstance(item, list):
        return ", ".join(str(part) for part in item)
    if isinstance(item, bool):
        return "yes" if item else "no"
    return str(item) if item not in (None, "") else "not provided"

def show(label, item):
    print(f"  [OK]   {label}: {value(item)}")

print("  Manifest checklist")
print("  ──────────────────────────────────────────")
show("Manifest schema version", document["schema_version"])
show("Source type", document["source"]["type"])
show("Source location", document["source"]["location"])
show("Source acquired at", document["source"]["acquired_at"])
show("Discovered package name", candidate.get("discovered_name"))
show("Source path within submission", candidate["source_path"])
show("Package classification", candidate["classification"])
show("Requested action", candidate["action"])
show("Repository destination", candidate["target_path"])
show("Author", author["name"])
show("Author contact", author.get("contact"))
show("Catalogue status", curation["status"])
show("Description", curation["description"])
show("Maintainers", curation["maintainers"])
show("Target architectures", compatibility["architectures"])
show("Brane baseline", compatibility["brane_baseline"])
show("Accepts user data", data_handling["accepts_user_data"])
show("Bundled data", data_handling["bundled_data"])
show("Licence", curation.get("licence"))
MANIFEST_PY
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — Validate, test, and add the package
# ═════════════════════════════════════════════════════════════════════════════
step 4 5 "Validate, test, and add the package"
printf '%s\n' 'The wizard validates metadata, checks the migration plan, and runs'
printf '%s\n' 'the package test script before adding package files to the repository.'
blank

SOURCE_FILE_COUNT="$(find "$SOURCE_DIR" -type f | wc -l | tr -d ' ')"
REPOSITORY_PACKAGE_COUNT="$(
  find "$ROOT_DIR/packages" "$ROOT_DIR/test-fixtures" \
    -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
)"
REPOSITORY_TRACKED_FILE_COUNT="$(
  git -C "$ROOT_DIR" ls-files | wc -l | tr -d ' '
)"
LOG="$INTAKE_DIR/${PACKAGE_NAME}-submission-check.log"
TEST_EVIDENCE_DIR="$INTAKE_DIR/${PACKAGE_NAME}-functional-test-evidence"
TEST_SCRIPT="$SOURCE_DIR/test.sh"

printf '%s\n' '  Validation scope'
printf '%s\n' '  ──────────────────────────────────────────'
printf '  [INFO] Package name: %s\n' "$PACKAGE_NAME"
printf '  [INFO] Source folder: %s\n' "$SOURCE_DIR"
printf '  [INFO] Intended repository destination: %s\n' "$TARGET_PATH"
printf '  [INFO] Files in selected package folder: %s\n' "$SOURCE_FILE_COUNT"
blank

printf '%s\n' '  Package file inventory'
printf '%s\n' '  ──────────────────────────────────────────'
(
  cd "$SOURCE_DIR"
  find . -type f -print | LC_ALL=C sort | sed 's#^\./#  [FILE] #'
)
blank

printf '%s\n' '  Repository snapshot'
printf '%s\n' '  ──────────────────────────────────────────'
printf '  [INFO] Existing package directories: %s\n' "$REPOSITORY_PACKAGE_COUNT"
printf '  [INFO] Git-tracked files in repository: %s\n' "$REPOSITORY_TRACKED_FILE_COUNT"
blank

printf '%s\n' '  Submission manifest checks'
printf '%s\n' '  ──────────────────────────────────────────'
printf '  Checking manifest schema: %s\n' "$MANIFEST"

if ! "$MIGRATOR" validate --document "$MANIFEST" --schema "$SCHEMA" >"$LOG" 2>&1; then
  report_stop "$PACKAGE_NAME" "✗  Manifest schema validation failed." \
    "The submission manifest does not meet the repository metadata schema." \
    "" \
    "Checked:" \
    "  Manifest: $MANIFEST" \
    "  Schema:   $SCHEMA" \
    "" \
    "Technical log:" \
    "  $LOG"
  exit 0
fi

ok 'Manifest schema validation passed'
printf '%s\n' '       Required metadata fields and allowed values are valid.'
blank

manifest_checklist "$MANIFEST"
blank

printf '%s\n' '  Migration dry-run checks'
printf '%s\n' '  ──────────────────────────────────────────'
printf '%s\n' '  Simulating package migration without writing repository files…'
printf '       Planned destination: %s\n' "$TARGET_PATH"

if ! "$MIGRATOR" migrate --manifest "$MANIFEST" --repository-root "$ROOT_DIR" >>"$LOG" 2>&1; then
  report_stop "$PACKAGE_NAME" "✗  Migration dry run failed." \
    "The migrator could not produce a valid repository update plan." \
    "" \
    "Checked:" \
    "  Repository root: $ROOT_DIR" \
    "  Planned destination: $TARGET_PATH" \
    "  Manifest: $MANIFEST" \
    "" \
    "Technical log:" \
    "  $LOG"
  exit 0
fi

ok 'Migration dry run completed'
printf '%s\n' '       The manifest, catalogue, destination, and repository layout are compatible.'
blank

printf '%s\n' '  Functional package test'
printf '%s\n' '  ──────────────────────────────────────────'
printf '  Required test script: %s\n' "$TEST_SCRIPT"

if [[ ! -f "$TEST_SCRIPT" ]]; then
  report_stop "$PACKAGE_NAME" "✗  Functional package test cannot run." \
    "Each package must contain a conventional test.sh file." \
    "" \
    "Expected test script:" \
    "  $TEST_SCRIPT" \
    "" \
    "Create it and make it executable:" \
    "  chmod +x \"$TEST_SCRIPT\""
  exit 0
fi

if [[ ! -x "$TEST_SCRIPT" ]]; then
  report_stop "$PACKAGE_NAME" "✗  Functional package test is not executable." \
    "test.sh exists but does not have executable permission." \
    "" \
    "Fix with:" \
    "  chmod +x \"$TEST_SCRIPT\""
  exit 0
fi

warn 'The wizard will execute test.sh from the selected local package folder.'
warn 'Only continue when you trust the package contents and its dependencies.'
blank

if [[ "$(yesno 'Run the functional package test now' Y)" != yes ]]; then
  report_stop "$PACKAGE_NAME" "ⓘ  Functional package test was not run." \
    "The package was not migrated because test.sh was skipped." \
    "" \
    "Required test script:" \
    "  $TEST_SCRIPT"
  exit 0
fi

printf '%s\n' '  Running: ./test.sh'
printf '       Test evidence directory: %s\n' "$TEST_EVIDENCE_DIR"

rm -rf "$TEST_EVIDENCE_DIR"
mkdir -p "$TEST_EVIDENCE_DIR"

if (
  cd "$SOURCE_DIR"
  BRANE_PACKAGE_TEST_HARNESS="$ROOT_DIR/scripts/lib/package_test_harness.sh" \
  BRANE_PACKAGE_TEST_EVIDENCE_DIR="$TEST_EVIDENCE_DIR" \
  BRANE_PACKAGE_TEST_PYTHON="$ROOT_DIR/.venv/bin/python" \
  ./test.sh
); then
  FUNCTIONAL_TEST_STATUS="passed"
  ok 'Functional package test passed'
  printf '       Test script: %s\n' "$TEST_SCRIPT"
  printf '       Test evidence directory: %s\n' "$TEST_EVIDENCE_DIR"
else
  blank
  warn 'Functional package test failed.'
  printf '       Test evidence directory: %s\n' "$TEST_EVIDENCE_DIR"

  report_stop "$PACKAGE_NAME" "✗  Functional package test failed." \
    "test.sh returned a non-zero exit status. No package files were added." \
    "" \
    "Test script:" \
    "  $TEST_SCRIPT" \
    "" \
    "Test evidence directory:" \
    "  $TEST_EVIDENCE_DIR"
  exit 0
fi
blank

printf '%s\n' '  Validation result'
printf '%s\n' '  ──────────────────────────────────────────'
printf '%s\n' '  [OK]   Package file inventory: recorded'
printf '%s\n' '  [OK]   Manifest schema: valid'
printf '%s\n' '  [OK]   Manifest checklist: complete'
printf '%s\n' '  [OK]   Migration plan: valid'
printf '%s\n' '  [OK]   Functional package test: passed'
blank

[[ "$(yesno 'Add the package files to the repository now' Y)" == yes ]] \
  || {
    info 'No package files were added. Your validated manifest is saved at:'
    printf '       %s\n' "$MANIFEST"
    exit 0
  }

printf '%s\n' '  Adding package files…'

if ! "$MIGRATOR" migrate --manifest "$MANIFEST" --repository-root "$ROOT_DIR" --execute >>"$LOG" 2>&1; then
  report_stop "$PACKAGE_NAME" "✗  Package migration failed." \
    "The validated migration could not be applied to the repository." \
    "" \
    "A full technical log is saved at:" \
    "  $LOG"
  exit 0
fi

DESTINATION_FILE_COUNT="$(
  find "$ROOT_DIR/$TARGET_PATH" -type f 2>/dev/null | wc -l | tr -d ' '
)"

ok "Package migration completed"
printf '  [OK]   Destination created or updated: %s\n' "$TARGET_PATH"
printf '  [OK]   Files now in destination: %s\n' "$DESTINATION_FILE_COUNT"
printf '  [INFO] Technical migration log: %s\n' "$LOG"
blank

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — Commit and submit
# ═════════════════════════════════════════════════════════════════════════════
step 5 5 "Commit and submit"
printf '%s\n' 'The package files are ready. The next steps commit them to your branch,'
printf '%s\n' 'push it to GitHub, and optionally create a Pull Request for review.'
blank

printf "  ${BOLD}Files created or changed:${RESET}\n"
git -C "$ROOT_DIR" status --short | sed 's/^/    /'
blank
divider
printf "  ${BOLD}Submission summary${RESET}\n"
printf "  %-14s %s\n" "Package:"     "$PACKAGE_NAME"
printf "  %-14s %s\n" "Description:" "$DESCRIPTION"
printf "  %-14s %s\n" "Maintainer:"  "$AUTHOR"
printf "  %-14s %s\n" "Branch:"      "$BRANCH"
printf "  %-14s %s\n" "Baseline:"    "Brane $BRANE_BASELINE · x86_64"
divider
blank

# ── Commit ────────────────────────────────────────────────────────────────────
if [[ "$(yesno 'Commit these changes now' Y)" != yes ]]; then
  info 'Changes are on your branch but not yet committed.'
  blank
  printf '%s\n' 'When you are ready, commit them with:'
  printf "  ${BOLD}git add -A${RESET}\n"
  printf "  ${BOLD}git commit -m \"Add Brane package %s\"${RESET}\n" "$PACKAGE_NAME"
  printf '%s\n' 'Then push and open a Pull Request.'
  exit 0
fi
MANIFEST_REL="intake/${PACKAGE_NAME}-review.yml"
git -C "$ROOT_DIR" add -- \
  "catalogue/packages.yml" \
  "$TARGET_PATH" \
  "$MANIFEST_REL"
git -C "$ROOT_DIR" commit -m "Add Brane package $PACKAGE_NAME" >/dev/null
ok 'Changes committed'
blank

# ── Push ──────────────────────────────────────────────────────────────────────
printf '%s\n' 'Pushing sends your branch to GitHub so you can open a Pull Request.'
printf '%s\n' 'This does not merge or publish the package — it only makes it visible'
printf '%s\n' 'to the administrator for review.'
blank

if [[ "$(yesno "Push branch \"$BRANCH\" to GitHub now" Y)" != yes ]]; then
  info 'Branch was not pushed. Push it manually when ready:'
  printf "  ${BOLD}git push -u origin %s${RESET}\n" "$BRANCH"
  exit 0
fi

if ! git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
  report_stop "$PACKAGE_NAME" "ⓘ  No GitHub remote configured." \
    "The commit was saved locally, but no remote named 'origin' was found." \
    "" \
    "Add a remote and push manually:" \
    "  git remote add origin <your-repository-url>" \
    "  git push -u origin $BRANCH"
  exit 0
fi

if ! git -C "$ROOT_DIR" push -u origin "$BRANCH" 2>/dev/null; then
  report_stop "$PACKAGE_NAME" "✗  Push failed." \
    "The branch could not be pushed to GitHub." \
    "" \
    "Common causes:" \
    "  • You are not authenticated (check your SSH key or token)" \
    "  • You do not have write access to the repository" \
    "" \
    "Try pushing manually:" \
    "  git push -u origin $BRANCH"
  exit 0
fi
ok "Branch pushed to GitHub: $BRANCH"

# ── Pull Request creation ─────────────────────────────────────────────────────
PR_URL=""
PR_STATUS="manual"

blank
printf '%s\n' 'Your branch is ready for administrator review.'
if [[ "$(yesno 'Create the Pull Request now' Y)" == yes ]]; then
  if ! command -v "$GH" >/dev/null 2>&1; then
    warn 'GitHub CLI is not installed, so the Pull Request must be created manually.'
  elif ! (cd "$ROOT_DIR" && "$GH" auth status >/dev/null 2>&1); then
    warn 'GitHub CLI is not authenticated, so the Pull Request must be created manually.'
  else
    EXISTING_PR_URL="$(
      cd "$ROOT_DIR"
      "$GH" pr list \
        --head "$BRANCH" \
        --state open \
        --json url \
        --jq '.[0].url' 2>/dev/null || true
    )"

    if [[ -n "$EXISTING_PR_URL" ]]; then
      PR_URL="$EXISTING_PR_URL"
      PR_STATUS="existing"
      ok 'An open Pull Request already exists for this branch'
    else
      PR_BODY="## Package submission

**Package:** $PACKAGE_NAME
**Classification:** $CLASSIFICATION
**Maintainer:** $AUTHOR

$DESCRIPTION

Submitted through the Brane package developer wizard for administrator review."

      if PR_URL="$(
        cd "$ROOT_DIR"
        "$GH" pr create \
          --base main \
          --head "$BRANCH" \
          --title "Add $PACKAGE_NAME package" \
          --body "$PR_BODY" 2>/dev/null
      )"; then
        PR_STATUS="created"
        ok 'Pull Request created'
      else
        PR_URL=""
        warn 'The Pull Request could not be created automatically.'
        info 'You can create it manually using the details below.'
      fi
    fi
  fi
else
  info 'No Pull Request was created. You can create one manually when ready.'
fi

# ── Final report ──────────────────────────────────────────────────────────────
package_file_report

blank
printf '%s\n' '──────────────────────────────────────────────────────────────────────'
printf '  Submission report — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' '──────────────────────────────────────────────────────────────────────'
blank

report_ok "package | metadata: complete"
report_ok "package | validation: schema and catalogue checks passed"
report_ok "package | repository files: added"
report_ok "git     | starting branch: $START_BRANCH"

if [[ "$BRANCH" == 'main' || "$BRANCH" == 'master' ]]; then
  report_fail "git     | working branch: $BRANCH (package must not be submitted from main)"
else
  report_ok "git     | working branch: $BRANCH"
fi

report_ok "git     | commit: created"
report_ok "git     | branch: pushed to GitHub"

blank
printf '%s\n' '──────────────────────────────────────────────────────────────────────'
blank

if [[ -n "$PR_URL" ]]; then
  if [[ "$PR_STATUS" == "created" ]]; then
    printf "  ${BOLD}Pull Request created${RESET}\n"
  else
    printf "  ${BOLD}Existing Pull Request found${RESET}\n"
  fi
  blank
  printf "    %s\n" "$PR_URL"
  blank
else
  printf "  ${BOLD}Next step — open a Pull Request on GitHub${RESET}\n"
  blank
  printf '  1. Go to: https://github.com/AdamBelloum/brane-packages\n'
  printf '  2. Click the green "Compare & pull request" button for your branch.\n'
  printf '  3. Add a short description of your package.\n'
  printf '  4. Click "Create pull request".\n'
  blank
  printf '  Pull request:\n'
  printf "    from: ${BOLD}%s${RESET}\n" "$BRANCH"
  printf "    into: ${BOLD}main${RESET}\n"
  blank
fi
info 'The Pull Request submits the package for administrator review.'
info 'The administrator reviews the submitted evidence and performs '
info 'independent functional and infrastructure validation.'
info 'The package is accepted only after review, approval, and merge.'
printf '%s\n' '──────────────────────────────────────────────────────────────────────'
blank
