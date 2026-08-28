#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# File:        run_wizzard.sh
# Purpose:     Guide package authors and repository maintainers through one
#              clear workflow at a time.
# Version:     1.0.0
# Date:        2026-08-28
# Author:      Adam Belloum
# Repository:  Brane Packages
# -----------------------------------------------------------------------------
# This script never pushes, opens Pull Requests, or merges changes.
# Each workflow starts from its first step. If it stops, return to the menu and
# start the workflow again when ready.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ -x .venv/bin/brane-package-migrate ]]; then
    TOOL=(.venv/bin/brane-package-migrate)
elif command -v brane-package-migrate >/dev/null 2>&1; then
    TOOL=(brane-package-migrate)
else
    echo "The package helper is not available. Set up the repository environment first." >&2
    exit 2
fi

# Safe plain-text defaults. Colours are enabled only for an interactive terminal.
RESET=""
BOLD=""
DIM=""
CYAN=""
GREEN=""

setup_display() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        RESET=$'\033[0m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        CYAN=$'\033[36m'
        GREEN=$'\033[32m'
    fi
}

clear_screen() {
    [[ -t 1 ]] && printf '\033[2J\033[H'
}

pause() {
    printf '\nPress Enter to return to the main menu...'
    read -r _
}

confirm() {
    local answer
    printf '%s [y/N]: ' "$1"
    read -r answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

prompt() {
    local answer
    printf '%s%s: ' "$1" "${2:+ [$2]}" >&2
    read -r answer
    printf '%s' "${answer:-${2:-}}"
}

show_environment() {
    clear_screen
    printf '%sRepository status%s\n\n' "$BOLD" "$RESET"
    echo "Repository: $ROOT"
    echo "Current branch: $(git branch --show-current)"
    echo
    git status --short
}

show_changes() {
    echo
    echo "Files changed or waiting to be added:"
    git status --short
    echo
    echo "Summary of changed tracked files:"
    git diff --stat
    echo
    echo "Summary of staged files:"
    git diff --cached --stat
}

run_tests() {
    if [[ -x .venv/bin/pytest ]]; then
        .venv/bin/pytest -q
    else
        echo "The test runner is not available." >&2
        return 1
    fi
}

share_package_workflow() {
    local source_directory package_name review_file current_branch suggested_branch chosen_branch

    clear_screen
    printf '%sShare a package%s\n' "$BOLD" "$RESET"
    echo "This guide prepares one package for review. It does not send anything to the shared repository."

    echo
    echo "Step 1 of 6 — Choose the package folder"
    echo "Enter the folder for one package. It must contain container.yml."
    source_directory="$(prompt "Package folder" "")"
    if [[ -z "$source_directory" || ! -d "$source_directory" ]]; then
        echo "That folder does not exist."
        return 1
    fi
    if [[ ! -f "$source_directory/container.yml" ]]; then
        echo "This is not a single package folder because container.yml was not found."
        echo "Choose the specific package folder, for example packages/hello_world."
        return 1
    fi

    package_name="$(basename "$source_directory")"
    review_file="intake/${package_name}-review.yml"

    mkdir -p intake

    if [[ -e "$review_file" ]]; then
       echo "Starting fresh: replacing the previous review information for '$package_name'."
       rm -f "$review_file" || {
	       echo "Could not remove the previous review file: $review_file" >&2
		      return 1
       }
    fi

    "${TOOL[@]}" discover --source "$source_directory" --output "$review_file" || return 1

    echo
    echo "Step 2 of 6 — Describe the package"
    echo "The next questions describe how this package may be used."
    echo "  reusable: intended for others to use"
    echo "  fixture: used only for tests or demonstrations"
    echo "  unsupported: kept for reference, but not supported"
    echo "  needs-review: a maintainer must decide later"
    echo
    echo "For an ordinary new package, normally choose reusable, migrate, and candidate."
    echo "Target path means the folder where the package will live in the collection."
    "${TOOL[@]}" review --manifest "$review_file" || return 1

    echo
    echo "Step 3 of 6 — Check that the information is complete"
    "${TOOL[@]}" validate --document "$review_file" --schema schemas/migration-manifest.schema.yml || return 1

    echo
    echo "Step 4 of 6 — Preview the result"
    echo "This shows what would be added. No files are changed in this step."
    "${TOOL[@]}" migrate --manifest "$review_file" || return 1

    echo
    echo "Step 5 of 6 — Choose a safe working branch"
    current_branch="$(git branch --show-current)"
    suggested_branch="share/${package_name}-candidate"
    if [[ -n "$current_branch" && "$current_branch" != "main" && "$current_branch" != "master" ]]; then
        echo "Current working branch: $current_branch"
        confirm "Use this branch" || return 1
    else
        chosen_branch="$(prompt "Name for a new working branch" "$suggested_branch")"
        [[ -n "$chosen_branch" ]] || return 1
        if git show-ref --verify --quiet "refs/heads/$chosen_branch"; then
            git switch "$chosen_branch" || return 1
        else
            git switch -c "$chosen_branch" || return 1
        fi
    fi

    echo
    echo "Step 6 of 6 — Add the package locally"
    echo "This adds the package to your current working branch. It does not push changes."
    confirm "Add the package now" || return 1
    "${TOOL[@]}" migrate --manifest "$review_file" --execute || return 1

    echo
    echo "Package added locally. Next, use 'Review a submitted package' before committing and opening a Pull Request."
}

review_submission_workflow() {
    clear_screen
    printf '%sReview a submitted package%s\n' "$BOLD" "$RESET"
    echo "This checks the current branch before its changes are shared."

    echo
    echo "Step 1 of 3 — Check the repository"
    "${TOOL[@]}" validate-repository || return 1

    echo
    echo "Step 2 of 3 — Run automatic checks"
    run_tests || return 1

    echo
    echo "Step 3 of 3 — Review the changes"
    show_changes
    echo
    echo "If these changes are correct, commit them on this branch, push it, and open a Pull Request."
}

setup_display

while true; do
    clear_screen
    printf '%s%sBrane Packages%s\n' "$BOLD" "$CYAN" "$RESET"
    printf '%sA guided way to share and review reusable Brane packages.%s\n' "$DIM" "$RESET"
    printf '%s\n\n' "────────────────────────────────────────────────────────"

    printf '%s%s1. Share a package%s  %s[AUTHOR]%s\n' "$BOLD" "$GREEN" "$RESET" "$CYAN" "$RESET"
    echo "   Prepare one package for review, with guidance at every step."
    echo
    printf '%s%s2. Review a submitted package%s  %s[MAINTAINER]%s\n' "$BOLD" "$GREEN" "$RESET" "$CYAN" "$RESET"
    echo "   Check a proposed package before it is added to the collection."
    echo
    printf '%s%s3. Show repository status%s  %s[STATUS]%s\n' "$BOLD" "$GREEN" "$RESET" "$CYAN" "$RESET"
    echo "   See the current branch and files that have changed."
    echo
    printf '%s0. Exit%s\n\n' "$BOLD" "$RESET"

    printf '%sChoose an option:%s ' "$BOLD" "$RESET"
    read -r choice

    case "$choice" in
        1)
            share_package_workflow
            result=$?
            [[ $result -eq 0 ]] || echo "The workflow stopped. You can start it again from Step 1 when ready."
            pause
            ;;
        2)
            review_submission_workflow
            result=$?
            [[ $result -eq 0 ]] || echo "The workflow stopped. You can start it again from Step 1 when ready."
            pause
            ;;
        3) show_environment; pause ;;
        0) clear_screen; exit 0 ;;
        *) echo "Please choose 1, 2, 3, or 0."; sleep 1 ;;
    esac
done
