#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$SCRIPT_DIR"
REVIEW_BASE="$ROOT_DIR/.admin-review"
REPORT_DIR="$REVIEW_BASE/reports"
WORKTREE_DIR=""
WORKTREE_CREATED=0
KEEP_WORKTREE=0
BRANCH=""

usage() {
  cat <<'USAGE'
Usage:
  ./package_admin_review.sh --branch <remote-branch> [--keep-worktree]

Creates an isolated, detached review worktree from origin/<remote-branch>.
This initial version records the reviewed commit and creates a local report.
It does not modify the submitted branch, publish a package, or merge a PR.

Options:
  --branch <name>     Remote branch containing the submitted package PR.
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

git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
  || fail "Invalid branch name: $BRANCH"

case "$BRANCH" in
  main|master)
    fail 'Refusing to review the protected default branch as a package submission.'
    ;;
esac

[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] \
  || fail 'The current checkout has uncommitted changes. Commit, stash, or remove them first.'

mkdir -p "$REPORT_DIR" "$REVIEW_BASE/worktrees"

printf 'Fetching origin/%s …\n' "$BRANCH"
git -C "$ROOT_DIR" fetch --no-tags origin \
  "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" \
  || fail "Could not fetch origin/$BRANCH."

REVIEW_COMMIT="$(git -C "$ROOT_DIR" rev-parse "origin/$BRANCH^{commit}")"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
WORKTREE_DIR="$REVIEW_BASE/worktrees/review-$TIMESTAMP"
REPORT_PATH="$REPORT_DIR/review-$TIMESTAMP.md"

git -C "$ROOT_DIR" worktree add --detach "$WORKTREE_DIR" "$REVIEW_COMMIT" >/dev/null
WORKTREE_CREATED=1

cat > "$REPORT_PATH" <<REPORT
# Brane Package Administrator Review

- **Review source branch:** \`origin/$BRANCH\`
- **Reviewed commit:** \`$REVIEW_COMMIT\`
- **Created:** \`$(date '+%Y-%m-%d %H:%M:%S %Z')\`
- **Review worktree:** \`$WORKTREE_DIR\`

## Review status

AUDIT:        NOT RUN  
PACKAGE TEST: NOT RUN  
CONTAINER:    NOT RUN  
BRANE TEST:   NOT RUN  
DECISION:     REVIEW IN PROGRESS
REPORT

printf '\nReview environment prepared.\n'
printf '  Source branch: %s\n' "origin/$BRANCH"
printf '  Reviewed commit: %s\n' "$REVIEW_COMMIT"
printf '  Report: %s\n' "$REPORT_PATH"

if [[ "$KEEP_WORKTREE" -eq 1 ]]; then
  printf '  Worktree retained: %s\n' "$WORKTREE_DIR"
else
  printf '  Worktree: temporary; it will be removed when this script exits.\n'
fi
