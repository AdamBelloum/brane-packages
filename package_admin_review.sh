#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$SCRIPT_DIR"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
AUDIT_TOOL="${ADMIN_AUDIT_TOOL:-$ROOT_DIR/tools/admin_review_audit.py}"
MIGRATOR="${MIGRATOR:-$ROOT_DIR/.venv/bin/brane-package-migrate}"
MANIFEST_SCHEMA="$ROOT_DIR/schemas/migration-manifest.schema.yml"
PACKAGE_METADATA_SCHEMA="$ROOT_DIR/schemas/package-metadata.schema.yml"
REVIEW_BASE="$ROOT_DIR/.admin-review"
REPORT_DIR="$REVIEW_BASE/reports"
WORKTREE_DIR=""
WORKTREE_CREATED=0
KEEP_WORKTREE=0
BRANCH=""
REQUESTED_PACKAGE=""

usage() {
  cat <<'USAGE'
Usage:
  ./package_admin_review.sh --branch <remote-branch> [--package <name-or-path>] [--keep-worktree]

Creates an isolated, detached review worktree from origin/<remote-branch>.
Compares it with origin/main and records a structural package audit locally.
It does not modify the submitted branch, publish a package, or merge a PR.

Options:
  --branch <name>     Remote branch containing the submitted package PR.
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

[[ -n "$BRANCH" ]] || {
  usage >&2
  fail 'Provide the submitted remote branch with --branch.'
}

git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "Not a Git repository: $ROOT_DIR"
[[ -x "$PYTHON" ]] || fail "Pinned Python interpreter is unavailable: $PYTHON"
[[ -f "$AUDIT_TOOL" ]] || fail "Structural audit tool is unavailable: $AUDIT_TOOL"
[[ -x "$MIGRATOR" ]] || fail "Pinned migration tool is unavailable: $MIGRATOR"
[[ -f "$MANIFEST_SCHEMA" ]] || fail "Migration schema is unavailable: $MANIFEST_SCHEMA"
[[ -f "$PACKAGE_METADATA_SCHEMA" ]] || fail "Package metadata schema is unavailable: $PACKAGE_METADATA_SCHEMA"

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
CONTAINER:    NOT RUN
BRANE TEST:   NOT RUN
DECISION:     REVIEW IN PROGRESS
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

"$PYTHON" - "$REPORT_PATH" "$METADATA_STATUS" "$SELECTED_TARGET" "$SELECTED_MANIFEST" "$VALIDATION_LOG" <<'METADATA_PY'
from pathlib import Path
import sys

report_path = Path(sys.argv[1])
status, target, manifest, log = sys.argv[2:]
existing = report_path.read_text(encoding="utf-8").replace(
    "METADATA:     NOT RUN",
    f"METADATA:     {status}",
    1,
)
section = f"""
## Metadata and repository validation

- **Selected package:** `{target}`
- **Selected intake manifest:** `{manifest}`
- **Result:** {status}
- **Technical log:** `{log}`
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
printf '  Report: %s\n' "$REPORT_PATH"

if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
  printf '  Worktree retained: %s\n' "$WORKTREE_DIR"
else
  printf '  Worktree: temporary; it will be removed when this script exits.\n'
fi
