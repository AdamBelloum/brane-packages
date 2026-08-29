#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
AUDIT_TOOL="${ADMIN_AUDIT_TOOL:-$ROOT_DIR/tools/admin_review_audit.py}"
MIGRATOR="${MIGRATOR:-$ROOT_DIR/.venv/bin/brane-package-migrate}"
GH="${GH:-gh}"
MANIFEST_SCHEMA="$ROOT_DIR/schemas/migration-manifest.schema.yml"
PACKAGE_METADATA_SCHEMA="$ROOT_DIR/schemas/package-metadata.schema.yml"
REVIEW_BASE="$ROOT_DIR/.admin-review"
REPORT_DIR="$REVIEW_BASE/reports"
WORKTREE_DIR=""
WORKTREE_CREATED=0
KEEP_WORKTREE=0
BRANCH=""
PR_NUMBER=""
REQUESTED_PACKAGE=""

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/admin/package_admin_review.sh [--branch <remote-branch> | --pr <number>] [--package <name-or-path>] [--keep-worktree]

Interactively selects an open GitHub Pull Request when no --branch or --pr is
provided from a terminal. Creates an isolated, detached review worktree from
the selected PR head branch.
Compares it with origin/main and records a structural package audit locally.
It does not execute submitted test.sh files, modify the submitted branch,
publish a package, or merge a PR.

Options:
  --branch <name>     Remote branch containing the submitted package PR.
  --pr <number>       Open GitHub Pull Request number to review.
  --package <value>   Select a changed package by name or packages/<name> path.
  --keep-worktree     Retain the temporary review worktree for diagnostics.
  -h, --help          Show this help text.
USAGE
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  if [[ "$WORKTREE_CREATED" -eq 1 && "$KEEP_WORKTREE" -eq 0 ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 ]] || fail '--branch requires a branch name.'
      BRANCH="$2"
      shift 2
      ;;
    --pr)
      [[ $# -ge 2 ]] || fail '--pr requires a Pull Request number.'
      PR_NUMBER="$2"
      shift 2
      ;;
    --package)
      [[ $# -ge 2 ]] || fail '--package requires a package name or path.'
      REQUESTED_PACKAGE="$2"
      shift 2
      ;;
    --keep-worktree)
      KEEP_WORKTREE=1
      shift
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

select_open_pull_request() {
  [[ -t 0 && -t 1 ]] || {
    usage >&2
    fail 'Provide --branch or --pr when standard input or output is not a terminal.'
  }
  command -v "$GH" >/dev/null 2>&1     || fail "GitHub CLI is unavailable: $GH"

  local repository pr_json rows choice selected
  local -a entries=()

  repository="$("$GH" repo view --json nameWithOwner --jq '.nameWithOwner')"     || fail 'Could not determine the GitHub repository.'
  pr_json="$("$GH" pr list --repo "$repository" --state open --limit 100     --json number,title,headRefName,author)"     || fail "Could not list open Pull Requests for $repository."

  rows="$("$PYTHON" -c '
import json
import sys

for item in json.load(sys.stdin):
    clean = lambda value: " ".join((value or "").split())
    print(
        "{}\t{}\t{}\t{}".format(
            item["number"],
            item["headRefName"],
            clean(item["title"]),
            clean(item["author"]["login"]),
        )
    )
' <<<"$pr_json")"

  while IFS=$'\t' read -r number head title author; do
    [[ -n "$number" ]] || continue
    entries+=("$number"$'\t'"$head"$'\t'"$title"$'\t'"$author")
  done <<<"$rows"

  ((${#entries[@]} > 0)) || fail 'There are no open Pull Requests to review.'

  printf '\nOpen Pull Requests:\n'
  local index=1 entry number head title author
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r number head title author <<<"$entry"
    printf '  %d) PR #%s — %s [%s; %s]\n'       "$index" "$number" "$title" "$head" "$author"
    ((index += 1))
  done

  read -r -p 'Select Pull Request number: ' choice
  [[ "$choice" =~ ^[1-9][0-9]*$ ]]     && ((choice <= ${#entries[@]}))     || fail 'Pull Request selection is invalid.'

  selected="${entries[choice - 1]}"
  IFS=$'\t' read -r PR_NUMBER BRANCH _ <<<"$selected"
  printf 'Selected PR #%s, branch %s.\n' "$PR_NUMBER" "$BRANCH"
}

git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "Not a Git repository: $ROOT_DIR"
[[ -x "$PYTHON" ]] || fail "Pinned Python interpreter is unavailable: $PYTHON"
[[ -f "$AUDIT_TOOL" ]] || fail "Structural audit tool is unavailable: $AUDIT_TOOL"
[[ -x "$MIGRATOR" ]] || fail "Pinned migration tool is unavailable: $MIGRATOR"
[[ -f "$MANIFEST_SCHEMA" ]] || fail "Migration schema is unavailable: $MANIFEST_SCHEMA"
[[ -f "$PACKAGE_METADATA_SCHEMA" ]] || fail "Package metadata schema is unavailable: $PACKAGE_METADATA_SCHEMA"

[[ -z "$BRANCH" || -z "$PR_NUMBER" ]]   || fail 'Use either --branch or --pr, not both.'

if [[ -n "$PR_NUMBER" ]]; then
  [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]     || fail "Invalid Pull Request number: $PR_NUMBER"
  command -v "$GH" >/dev/null 2>&1     || fail "GitHub CLI is unavailable: $GH"
  BRANCH="$("$GH" pr view "$PR_NUMBER"     --json state,headRefName     --jq 'select(.state == "OPEN") | .headRefName')"     || fail "Could not resolve Pull Request #$PR_NUMBER."
  [[ -n "$BRANCH" ]]     || fail "Pull Request #$PR_NUMBER is not open or has no head branch."
elif [[ -z "$BRANCH" ]]; then
  select_open_pull_request
fi

git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
  || fail "Invalid branch name: $BRANCH"

case "$BRANCH" in
  main|master)
    fail 'Refusing to review the protected default branch as a package submission.'
    ;;
esac

[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] \
  || fail 'The current checkout has uncommitted changes. Commit, stash, or remove them first.'

mkdir -p "$REPORT_DIR" "$REVIEW_BASE/worktrees" "$REVIEW_BASE/audits" "$REVIEW_BASE/logs"

printf 'Fetching origin/main …\n'
git -C "$ROOT_DIR" fetch --no-tags origin \
  "refs/heads/main:refs/remotes/origin/main" \
  || fail "Could not fetch origin/main."

printf 'Fetching origin/%s …\n' "$BRANCH"
git -C "$ROOT_DIR" fetch --no-tags origin \
  "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" \
  || fail "Could not fetch origin/$BRANCH."

BASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse "origin/main^{commit}")"
REVIEW_COMMIT="$(git -C "$ROOT_DIR" rev-parse "origin/$BRANCH^{commit}")"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
WORKTREE_DIR="$REVIEW_BASE/worktrees/review-$TIMESTAMP"
REPORT_PATH="$REPORT_DIR/review-$TIMESTAMP.md"
AUDIT_JSON="$REVIEW_BASE/audits/audit-$TIMESTAMP.json"

git -C "$ROOT_DIR" worktree add --detach "$WORKTREE_DIR" "$REVIEW_COMMIT" >/dev/null
WORKTREE_CREATED=1

cat > "$REPORT_PATH" <<REPORT
# Brane Package Administrator Review

- **Review source branch:** \`origin/$BRANCH\`
- **Base commit:** \`$BASE_COMMIT\`
- **Reviewed commit:** \`$REVIEW_COMMIT\`
- **Created:** \`$(date '+%Y-%m-%d %H:%M:%S %Z')\`
- **Review worktree:** \`$WORKTREE_DIR\`

## Review status

AUDIT:        NOT RUN
METADATA:     NOT RUN
PACKAGE TEST: NOT RUN
DECISION:     PENDING REVIEW
REPORT

if ! "$PYTHON" "$AUDIT_TOOL" \
  --worktree "$WORKTREE_DIR" \
  --base "$BASE_COMMIT" \
  --head "$REVIEW_COMMIT" \
  --output "$AUDIT_JSON"; then
  fail "Structural audit could not inspect the reviewed commit."
fi

"$PYTHON" - "$AUDIT_JSON" "$REPORT_PATH" <<'AUDIT_PY'
from pathlib import Path
import json
import sys

audit_path = Path(sys.argv[1])
report_path = Path(sys.argv[2])
audit = json.loads(audit_path.read_text(encoding="utf-8"))
candidates = audit["candidates"]
errors = [error for candidate in candidates for error in candidate["errors"]]

lines = [
    "",
    "## Structural audit",
    "",
    f"- **Changed repository paths:** {len(audit['changed_paths'])}",
    f"- **Changed package directories:** {len(candidates)}",
]
if not candidates:
    audit_status = "FAILED"
    lines.extend(
        [
            "- **Result:** FAILED",
            "- No changed package directory was found below `packages/` or `test-fixtures/`.",
        ]
    )
elif errors:
    audit_status = "FAILED"
    lines.append("- **Result:** FAILED")
else:
    audit_status = "PASSED"
    lines.append("- **Result:** PASSED")

for candidate in candidates:
    lines.extend(
        [
            "",
            f"### `{candidate['target_path']}`",
            "",
            f"- **Files:** {len(candidate['files'])}",
            f"- **Matching intake manifest(s):** "
            + (", ".join(f"`{item}`" for item in candidate["manifest_paths"]) or "none"),
        ]
    )
    if candidate["errors"]:
        lines.append("- **Findings:**")
        lines.extend(f"  - FAIL: {finding}" for finding in candidate["errors"])
    else:
        lines.append("- **Findings:** PASS — structural requirements satisfied.")

existing_report = report_path.read_text(encoding="utf-8")
existing_report = existing_report.replace(
    "AUDIT:        NOT RUN",
    f"AUDIT:        {audit_status}",
    1,
)
report_path.write_text(existing_report + "\n".join(lines) + "\n", encoding="utf-8")
AUDIT_PY

if [[ -z "$REQUESTED_PACKAGE" && -t 0 && -t 1 ]]; then
  PACKAGE_ROWS="$("$PYTHON" - "$AUDIT_JSON" <<'PACKAGE_LIST_PY'
import json
import sys
from pathlib import Path

for candidate in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["candidates"]:
    print(f"{candidate['target_path']}\t{candidate['package_name']}")
PACKAGE_LIST_PY
)"
  PACKAGE_COUNT=0
  while IFS=$'\t' read -r target package_name; do
    [[ -n "$target" ]] && ((PACKAGE_COUNT += 1))
  done <<<"$PACKAGE_ROWS"

  if ((PACKAGE_COUNT > 1)); then
    printf '\nChanged packages:\n'
    PACKAGE_INDEX=1
    while IFS=$'\t' read -r target package_name; do
      [[ -n "$target" ]] || continue
      printf '  %d) %s [%s]\n' "$PACKAGE_INDEX" "$package_name" "$target"
      ((PACKAGE_INDEX += 1))
    done <<<"$PACKAGE_ROWS"

    read -r -p 'Select package number: ' PACKAGE_CHOICE
    [[ "$PACKAGE_CHOICE" =~ ^[1-9][0-9]*$ ]]       && ((PACKAGE_CHOICE <= PACKAGE_COUNT))       || fail 'Package selection is invalid.'

    PACKAGE_INDEX=1
    while IFS=$'\t' read -r target package_name; do
      [[ -n "$target" ]] || continue
      if ((PACKAGE_INDEX == PACKAGE_CHOICE)); then
        REQUESTED_PACKAGE="$target"
        break
      fi
      ((PACKAGE_INDEX += 1))
    done <<<"$PACKAGE_ROWS"
  fi
fi

SELECTION="$(
  "$PYTHON" - "$AUDIT_JSON" "$REQUESTED_PACKAGE" <<'SELECTION_PY'
import json
import sys
from pathlib import Path

audit = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
requested = sys.argv[2]
candidates = audit["candidates"]

if not candidates:
    raise SystemExit("No changed package directory is available for review.")

if requested:
    selected = [
        candidate
        for candidate in candidates
        if candidate["package_name"] == requested
        or candidate["target_path"] == requested
    ]
    if len(selected) != 1:
        available = ", ".join(candidate["target_path"] for candidate in candidates)
        raise SystemExit(
            f"Package selection '{requested}' is not unique or not found. "
            f"Available: {available}"
        )
else:
    if len(candidates) != 1:
        available = ", ".join(candidate["target_path"] for candidate in candidates)
        raise SystemExit(
            "Multiple changed packages require --package <name-or-path>. "
            f"Available: {available}"
        )
    selected = candidates

candidate = selected[0]
manifests = candidate["manifest_paths"]
if len(manifests) != 1:
    raise SystemExit(
        f"Selected package {candidate['target_path']} does not have exactly one "
        "matching intake review manifest."
    )

print(f"{candidate['target_path']}\t{manifests[0]}")
SELECTION_PY
)" || {
  printf '  Report: %s\n' "$REPORT_PATH" >&2
  fail "A package could not be selected for metadata validation."
}

IFS=$'\t' read -r SELECTED_TARGET SELECTED_MANIFEST <<< "$SELECTION"
VALIDATION_LOG="$REVIEW_BASE/logs/validation-$TIMESTAMP.log"
METADATA_STATUS="PASSED"

{
  printf 'Selected package: %s\n' "$SELECTED_TARGET"
  printf 'Selected intake manifest: %s\n\n' "$SELECTED_MANIFEST"
  printf '%s\n' '--- Intake manifest schema validation ---'
} >"$VALIDATION_LOG"

if ! "$MIGRATOR" validate   --document "$WORKTREE_DIR/$SELECTED_MANIFEST"   --schema "$MANIFEST_SCHEMA" >>"$VALIDATION_LOG" 2>&1; then
  METADATA_STATUS="FAILED"
fi

{
  printf '\n%s\n' '--- Package metadata schema validation ---'
} >>"$VALIDATION_LOG"

if ! "$MIGRATOR" validate   --document "$WORKTREE_DIR/$SELECTED_TARGET/package.yml"   --schema "$PACKAGE_METADATA_SCHEMA" >>"$VALIDATION_LOG" 2>&1; then
  METADATA_STATUS="FAILED"
fi

{
  printf '\n%s\n' '--- Repository metadata and catalogue validation ---'
} >>"$VALIDATION_LOG"

if ! "$MIGRATOR" validate-repository   --repository-root "$WORKTREE_DIR" >>"$VALIDATION_LOG" 2>&1; then
  METADATA_STATUS="FAILED"
fi

TEST_RECORD="$REVIEW_BASE/logs/manual-test-$TIMESTAMP.md"
cat >"$TEST_RECORD" <<TEST_RECORD_TEMPLATE
# Manual functional-test record

- **Reviewed commit:** \`$REVIEW_COMMIT\`
- **Selected package:** \`$SELECTED_TARGET\`
- **Required script:** \`$SELECTED_TARGET/test.sh\`
- **Status:** MANUAL REQUIRED

This administrator workflow deliberately does not execute submitted package code.
Perform the test only in an approved environment, then complete this record.

## Execution evidence

- **Reviewer:**
- **Date and time:**
- **Approved execution environment:**
- **Command executed:**
- **Result:** PASSED / FAILED
- **Full output or log location:**
- **Notes:**
TEST_RECORD_TEMPLATE

"$PYTHON" - "$REPORT_PATH" "$METADATA_STATUS" "$SELECTED_TARGET" "$SELECTED_MANIFEST" "$VALIDATION_LOG" "$TEST_RECORD" <<'METADATA_PY'
from pathlib import Path
import sys

report_path = Path(sys.argv[1])
status, target, manifest, log, test_record = sys.argv[2:]
existing = report_path.read_text(encoding="utf-8").replace(
    "METADATA:     NOT RUN",
    f"METADATA:     {status}",
    1,
).replace(
    "PACKAGE TEST: NOT RUN",
    "PACKAGE TEST: MANUAL REQUIRED",
    1,
).replace(
    "DECISION:     PENDING REVIEW",
    "DECISION:     PENDING MANUAL TEST",
    1,
)
section = f"""
## Metadata and repository validation

- **Selected package:** `{target}`
- **Selected intake manifest:** `{manifest}`
- **Result:** {status}
- **Technical log:** `{log}`

## Functional test hand-off

- **Required script:** `{target}/test.sh`
- **Status:** MANUAL REQUIRED
- **Policy:** This workflow never executes submitted package code.
- **Manual test record:** `{test_record}`

## Review decision

**PENDING MANUAL TEST**

No package is accepted, published, or merged by this workflow. An administrator
must complete the manual functional-test record in an approved environment before
making an explicit acceptance or rejection decision.
"""
report_path.write_text(existing + section, encoding="utf-8")
METADATA_PY

if [[ "$METADATA_STATUS" != "PASSED" ]]; then
  printf '  Report: %s\n' "$REPORT_PATH" >&2
  printf '  Validation log: %s\n' "$VALIDATION_LOG" >&2
  fail "Metadata or repository validation failed for $SELECTED_TARGET."
fi

printf '\nReview environment prepared.\n'
printf '  Source branch: %s\n' "origin/$BRANCH"
printf '  Base commit: %s\n' "$BASE_COMMIT"
printf '  Reviewed commit: %s\n' "$REVIEW_COMMIT"
printf '  Structural audit evidence: %s\n' "$AUDIT_JSON"
printf '  Validation log: %s\n' "$VALIDATION_LOG"
printf '  Manual test record: %s\n' "$TEST_RECORD"
printf '  Decision: PENDING MANUAL TEST\n'
printf '  Report: %s\n' "$REPORT_PATH"

if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
  printf '  Worktree retained: %s\n' "$WORKTREE_DIR"
else
  printf '  Worktree: temporary; it will be removed when this script exits.\n'
fi
