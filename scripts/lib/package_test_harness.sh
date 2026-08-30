#!/usr/bin/env bash
#
# Shared interactive test harness for Brane packages.
#
# A package test.sh sources this file and uses:
#
#   brane_package_test_begin
#   brane_package_test_case "action" "stated inputs" "expected result" [result file]
#   brane_package_test_finish
#
# The harness builds the package locally, invokes Brane's interactive local
# package tester once per stated case, records operator attestations, and
# ensures every action declared in container.yml has a completed test case.

_bpt_fail() {
  printf 'package test harness: %s\n' "$*" >&2
  return 1
}

_bpt_require_started() {
  [[ "${BPT_STARTED:-}" == "1" ]] \
    || _bpt_fail 'call brane_package_test_begin before defining test cases'
}

_bpt_record() {
  printf '%s\n' "$*" >>"$BPT_RECORD"
}

_bpt_action_is_declared() {
  local wanted="$1"
  local action

  for action in "${BPT_DECLARED_ACTIONS[@]}"; do
    [[ "$action" == "$wanted" ]] && return 0
  done

  return 1
}

_bpt_action_was_completed() {
  local wanted="$1"
  local action

  for action in "${BPT_COMPLETED_ACTIONS[@]-}"; do
    [[ "$action" == "$wanted" ]] && return 0
  done

  return 1
}

brane_package_test_begin() {
  local package_dir="${1:-$PWD}"
  local container
  local metadata_line
  local build_log
  local -a metadata
  local -a build_command

  [[ -t 0 && -t 1 ]] \
    || _bpt_fail 'interactive testing requires a terminal on standard input and output' \
    || return 1

  BPT_BRANE_BIN="${BRANE_BIN:-}"
  if [[ -z "$BPT_BRANE_BIN" ]]; then
    BPT_BRANE_BIN="$HOME/.local/bin/brane"
  fi

  [[ -x "$BPT_BRANE_BIN" ]] \
    || _bpt_fail "Brane CLI is unavailable or not executable: $BPT_BRANE_BIN" \
    || return 1

  BPT_PYTHON="${BRANE_PACKAGE_TEST_PYTHON:-python3}"
  command -v "$BPT_PYTHON" >/dev/null 2>&1 \
    || _bpt_fail "Python interpreter is unavailable: $BPT_PYTHON" \
    || return 1

  BPT_SCRIPT_BIN="${BRANE_PACKAGE_TEST_SCRIPT_BIN:-}"
  if [[ -z "$BPT_SCRIPT_BIN" ]]; then
    BPT_SCRIPT_BIN="$(command -v script || true)"
  fi
  [[ -n "$BPT_SCRIPT_BIN" && -x "$BPT_SCRIPT_BIN" ]] \
    || _bpt_fail 'the script utility is unavailable; cannot retain interactive test transcripts' \
    || return 1

  package_dir="$(cd "$package_dir" && pwd)"
  container="$package_dir/container.yml"
  [[ -f "$container" ]] \
    || _bpt_fail "container.yml is missing: $container" \
    || return 1

  if [[ -n "${BRANE_PACKAGE_TEST_EVIDENCE_DIR:-}" ]]; then
    mkdir -p "$BRANE_PACKAGE_TEST_EVIDENCE_DIR"
    BPT_SESSION_DIR="$BRANE_PACKAGE_TEST_EVIDENCE_DIR/session-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$BPT_SESSION_DIR"
  else
    BPT_SESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/brane-package-test.XXXXXX")"
  fi

  BPT_RECORD="$BPT_SESSION_DIR/operator-attestations.txt"
  BPT_BUILD_LOG="$BPT_SESSION_DIR/package-build.log"

  metadata=()
  while IFS= read -r metadata_line; do
    metadata+=("$metadata_line")
  done < <(
    "$BPT_PYTHON" - "$container" <<'PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8")) or {}
name = document.get("name")
version = document.get("version")
actions = document.get("actions", document.get("functions", {}))

if not isinstance(name, str) or not name:
    raise SystemExit("container.yml has no package name")
if version is None or str(version) == "":
    raise SystemExit("container.yml has no package version")

if isinstance(actions, dict):
    action_names = list(actions)
elif isinstance(actions, list):
    action_names = [
        item.get("name")
        for item in actions
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    ]
else:
    raise SystemExit("container.yml actions/functions must be a mapping or list")

if not action_names:
    raise SystemExit("container.yml declares no actions/functions")

print(name)
print(version)
for action in action_names:
    print(action)
PY
  ) || {
    _bpt_fail 'could not read package name, version, and actions from container.yml'
    return 1
  }

  BPT_PACKAGE_NAME="${metadata[0]:-}"
  BPT_PACKAGE_VERSION="${metadata[1]:-}"
  BPT_DECLARED_ACTIONS=("${metadata[@]:2}")
  BPT_COMPLETED_ACTIONS=()

  [[ -n "$BPT_PACKAGE_NAME" && -n "$BPT_PACKAGE_VERSION" ]] \
    || _bpt_fail 'container.yml did not provide package name and version' \
    || return 1

  printf 'Brane package test session\n' >"$BPT_RECORD"
  printf 'package: %s\n' "$BPT_PACKAGE_NAME" >>"$BPT_RECORD"
  printf 'version: %s\n' "$BPT_PACKAGE_VERSION" >>"$BPT_RECORD"
  printf 'container: %s\n' "$container" >>"$BPT_RECORD"
  printf 'brane: %s\n' "$BPT_BRANE_BIN" >>"$BPT_RECORD"
  printf 'script: %s\n' "$BPT_SCRIPT_BIN" >>"$BPT_RECORD"
  printf 'started_utc: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$BPT_RECORD"
  printf 'declared_actions: %s\n' "${BPT_DECLARED_ACTIONS[*]}" >>"$BPT_RECORD"

  build_command=("$BPT_BRANE_BIN" package build "$container")
  if [[ -n "${BRANE_PACKAGE_TEST_ARCH:-}" ]]; then
    build_command+=(--arch "$BRANE_PACKAGE_TEST_ARCH")
  fi

  printf '\nBuilding %s:%s locally...\n' "$BPT_PACKAGE_NAME" "$BPT_PACKAGE_VERSION"
  if ! "${build_command[@]}" >"$BPT_BUILD_LOG" 2>&1; then
    printf 'Local package build failed. Last 30 log lines:\n' >&2
    tail -n 30 "$BPT_BUILD_LOG" >&2 || true
    _bpt_record 'build: FAILED'
    return 1
  fi

  _bpt_record 'build: PASSED'
  BPT_STARTED=1

  printf 'Local build passed.\n'
  printf 'Declared actions: %s\n' "${BPT_DECLARED_ACTIONS[*]}"
  printf 'Evidence directory: %s\n' "$BPT_SESSION_DIR"
}

brane_package_test_case() {
  local action="${1:-}"
  local stated_inputs="${2:-}"
  local expected_result="${3:-}"
  local result_file="${4:-}"
  local selected_action
  local verdict
  local safe_action
  local case_log
  local command_runner
  local -a command

  _bpt_require_started || return 1

  [[ -n "$action" && -n "$stated_inputs" && -n "$expected_result" ]] \
    || _bpt_fail 'usage: brane_package_test_case ACTION INPUTS EXPECTED_RESULT [RESULT_FILE]' \
    || return 1

  _bpt_action_is_declared "$action" \
    || _bpt_fail "test case names an action not declared in container.yml: $action" \
    || return 1

  _bpt_action_was_completed "$action" && {
    _bpt_fail "action already has a completed test case: $action"
    return 1
  }

  printf '\n============================================================\n'
  printf 'Required action:  %s\n' "$action"
  printf 'Use these inputs: %s\n' "$stated_inputs"
  printf 'Expected result:  %s\n' "$expected_result"
  printf '============================================================\n'
  printf 'Brane will now ask you to select an action and enter inputs.\n'
  printf 'Select exactly "%s" and use the stated inputs above.\n\n' "$action"

  command=("$BPT_BRANE_BIN" package test "$BPT_PACKAGE_NAME" "$BPT_PACKAGE_VERSION")
  if [[ -n "$result_file" ]]; then
    command+=(--show-result "$result_file")
  fi

  safe_action="${action//[^A-Za-z0-9_.-]/_}"
  case_log="$BPT_SESSION_DIR/action-${safe_action}.log"
  command_runner="$BPT_SESSION_DIR/run-action-${safe_action}.sh"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec'
    printf ' %q' "${command[@]}"
    printf '\n'
  } >"$command_runner"
  chmod 700 "$command_runner"

  _bpt_record ''
  _bpt_record "case_action: $action"
  _bpt_record "case_inputs: $stated_inputs"
  _bpt_record "case_expected_result: $expected_result"
  _bpt_record "case_transcript: $case_log"
  _bpt_record "case_started_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if ! (
    case "$(uname -s)" in
      Darwin)
        "$BPT_SCRIPT_BIN" -q -e "$case_log" "$command_runner"
        ;;
      Linux)
        "$BPT_SCRIPT_BIN" -q -e -c "$command_runner" "$case_log"
        ;;
      *)
        _bpt_fail "unsupported platform for interactive transcript capture: $(uname -s)"
        return 1
        ;;
    esac
  ); then
    _bpt_record 'case_command: FAILED'
    _bpt_fail "Brane reported a failed test command for action: $action"
    return 1
  fi

  _bpt_record 'case_command: PASSED'

  read -r -p "Type the action you selected, to confirm it was \"$action\": " selected_action
  if [[ "$selected_action" != "$action" ]]; then
    _bpt_record "case_selected_action: $selected_action"
    _bpt_record 'case_attestation: FAILED'
    _bpt_fail "selected action confirmation did not match required action: $action"
    return 1
  fi

  read -r -p 'Did the displayed result match the stated expected result? Type PASSED or FAILED: ' verdict
  _bpt_record "case_selected_action: $selected_action"
  _bpt_record "case_attestation: $verdict"
  _bpt_record "case_finished_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$verdict" != "PASSED" ]]; then
    _bpt_fail "operator marked the action test as failed: $action"
    return 1
  fi

  BPT_COMPLETED_ACTIONS+=("$action")
  printf 'Recorded passed test case for action: %s\n' "$action"
}

brane_package_test_finish() {
  local action
  local missing=()

  _bpt_require_started || return 1

  for action in "${BPT_DECLARED_ACTIONS[@]}"; do
    _bpt_action_was_completed "$action" || missing+=("$action")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    _bpt_record "coverage: FAILED; missing actions: ${missing[*]}"
    _bpt_fail "required action coverage is incomplete; missing: ${missing[*]}"
    return 1
  fi

  _bpt_record 'coverage: PASSED'
  _bpt_record "finished_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\nAll declared actions were tested and operator-attested as passed.\n'
  printf 'Evidence directory: %s\n' "$BPT_SESSION_DIR"
}
