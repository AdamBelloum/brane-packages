#!/usr/bin/env bash
# Guided entry point for package authors and repository maintainers.
# This script never pushes, opens Pull Requests, or merges branches.

set -u

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPOSITORY_ROOT"

if [[ -x .venv/bin/brane-package-migrate ]]; then
    PACKAGE_TOOL=(.venv/bin/brane-package-migrate)
elif command -v brane-package-migrate >/dev/null 2>&1; then
    PACKAGE_TOOL=(brane-package-migrate)
else
    echo "error: brane-package-migrate is unavailable." >&2
    echo "Create the virtual environment and install the repository dependencies first." >&2
    exit 2
fi

MANIFEST="intake/package-review.yml"
SOURCE_DIRECTORY=""

pause() {
    printf '\nPress Enter to continue...'
    read -r _
}

prompt_value() {
    local label="$1"
    local current="$2"
    local value

    printf '%s [%s]: ' "$label" "$current" >&2
    read -r value
    printf '%s' "${value:-$current}"
}

confirm() {
    local prompt="$1"
    local answer

    printf '%s [y/N]: ' "$prompt"
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

show_environment() {
    echo
    echo "Repository: $REPOSITORY_ROOT"
    echo "Branch: $(git branch --show-current)"
    echo "Tool: ${PACKAGE_TOOL[*]}"
    echo
    git status --short
}

choose_source() {
    SOURCE_DIRECTORY="$(prompt_value "Folder containing the package" "$SOURCE_DIRECTORY")"
    if [[ -z "$SOURCE_DIRECTORY" ]]; then
        echo "A package folder is required."
        return 1
    fi
    if [[ ! -d "$SOURCE_DIRECTORY" ]]; then
        echo "error: package folder does not exist: $SOURCE_DIRECTORY" >&2
        return 1
    fi

    PACKAGE_NAME="$(basename "$SOURCE_DIRECTORY")"
    MANIFEST="intake/${PACKAGE_NAME}-review.yml"
}

choose_submission() {
    local package_name

    if [[ -z "${PACKAGE_NAME:-}" ]]; then
        package_name="$(prompt_value "Package folder name" "")"
        if [[ -z "$package_name" || "$package_name" == */* ]]; then
            echo "Enter the package folder name only, without a path."
            return 1
        fi
        PACKAGE_NAME="$package_name"
    fi

    MANIFEST="intake/${PACKAGE_NAME}-review.yml"
    if [[ ! -f "$MANIFEST" ]]; then
        echo "No saved submission was found for '$PACKAGE_NAME'."
        echo "Choose 'Start sharing a new package' first."
        return 1
    fi
}

start_submission() {
    choose_source || return

    if [[ -e "$MANIFEST" ]]; then
        echo "A saved submission already exists for '$PACKAGE_NAME'."
        echo "Choose 'Continue a package submission' to work on it."
        return 1
    fi

    mkdir -p "$(dirname "$MANIFEST")"
    "${PACKAGE_TOOL[@]}" discover --source "$SOURCE_DIRECTORY" --output "$MANIFEST" || return

    echo
    echo "Answer the following questions about the package."
    "${PACKAGE_TOOL[@]}" review --manifest "$MANIFEST"
}

continue_submission() {
    choose_submission || return
    echo
    echo "You can now add or correct information about this package."
    "${PACKAGE_TOOL[@]}" review --manifest "$MANIFEST"
}

check_submission() {
    choose_submission || return
    "${PACKAGE_TOOL[@]}" validate \
        --document "$MANIFEST" \
        --schema schemas/migration-manifest.schema.yml
}

preview_package_addition() {
    choose_submission || return
    echo
    echo "This preview does not change any files."
    "${PACKAGE_TOOL[@]}" migrate --manifest "$MANIFEST"
}

add_package_to_branch() {
    choose_submission || return
    echo
    echo "This adds the approved package to the current local branch."
    echo "It does not send anything to the shared repository."
    if ! confirm "Add this package to the branch"; then
        echo "No files were changed."
        return
    fi
    "${PACKAGE_TOOL[@]}" migrate --manifest "$MANIFEST" --execute
}

validate_repository() {
    "${PACKAGE_TOOL[@]}" validate-repository
}

run_tests() {
    if [[ -x .venv/bin/pytest ]]; then
        .venv/bin/pytest -q
    else
        echo "error: .venv/bin/pytest is unavailable." >&2
        return 2
    fi
}

show_pull_request_changes() {
    echo
    echo "--- Git status ---"
    git status --short
    echo
    echo "--- Unstaged change summary ---"
    git diff --stat
    echo
    echo "--- Staged change summary ---"
    git diff --cached --stat
    echo
    echo "Review these changes, commit them on a feature branch, push, and open a Pull Request."
}

author_menu() {
    while true; do
        cat <<'MENU'

Share a Brane package
  1. Start sharing a new package
  2. Continue a package submission
  3. Check whether my package is ready
  4. Preview what will be added to the shared collection
  5. Add the package to my local submission branch
  6. Prepare my changes for sharing with the repository team
  0. Back
MENU
        printf 'Choose an action: '
        read -r choice
        case "$choice" in
            1) start_submission ;;
            2) continue_submission ;;
            3) check_submission ;;
            4) preview_package_addition ;;
            5) add_package_to_branch ;;
            6) show_pull_request_changes ;;
            0) return ;;
            *) echo "Choose a number from the menu." ;;
        esac
        pause
    done
}

maintainer_menu() {
    while true; do
        cat <<'MENU'

Repository maintainer menu
  1. Check environment and Git state
  2. Validate complete repository
  3. Run automated tests
  4. Show changes to review in the Pull Request branch
  0. Return to role selection
MENU
        printf 'Choose an action: '
        read -r choice
        case "$choice" in
            1) show_environment ;;
            2) validate_repository ;;
            3) run_tests ;;
            4) show_pull_request_changes ;;
            0) return ;;
            *) echo "Choose a number from the menu." ;;
        esac
        pause
    done
}

while true; do
    cat <<'MENU'

Brane Packages
  1. Share a package
  2. Review package submissions
  0. Exit
MENU
    printf 'Choose your role: '
    read -r role
    case "$role" in
        1) author_menu ;;
        2) maintainer_menu ;;
        0) exit 0 ;;
        *) echo "Choose a number from the menu." ;;
    esac
done
