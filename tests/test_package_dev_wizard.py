"""Regression checks for the package developer wizard PR handoff."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
WIZARD = ROOT / "scripts" / "developer" / "package_dev_wizard.sh"


def wizard_text() -> str:
    return WIZARD.read_text(encoding="utf-8")


def test_package_developer_wizard_has_valid_shell_syntax() -> None:
    result = subprocess.run(
        ["bash", "-n", str(WIZARD)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr


def test_wizard_offers_safe_opt_in_pull_request_creation() -> None:
    text = wizard_text()

    assert 'GH="${GH:-gh}"' in text
    assert "Create the Pull Request now" in text
    assert '"$GH" auth status' in text
    assert '"$GH" pr list' in text
    assert '--head "$BRANCH"' in text
    assert '--state open' in text
    assert '"$GH" pr create' in text
    assert '--base main' in text
    assert '--title "Add $PACKAGE_NAME package"' in text
    assert "Pull Request could not be created automatically" in text
    assert "Next step — open a Pull Request on GitHub" in text


def test_wizard_checks_for_an_existing_pr_before_creating_one() -> None:
    text = wizard_text()

    existing_check = text.index('"$GH" pr list')
    create_command = text.index('"$GH" pr create')
    existing_message = text.index("An open Pull Request already exists")

    assert existing_check < create_command
    assert existing_message < create_command


def test_wizard_runs_interactive_tests_with_shared_harness_environment() -> None:
    text = wizard_text()

    assert 'BRANE_PACKAGE_TEST_HARNESS="$ROOT_DIR/scripts/lib/package_test_harness.sh"' in text
    assert 'BRANE_PACKAGE_TEST_EVIDENCE_DIR="$TEST_EVIDENCE_DIR"' in text
    assert 'BRANE_PACKAGE_TEST_PYTHON="$ROOT_DIR/.venv/bin/python"' in text

    assert 'TEST_EVIDENCE_DIR="$INTAKE_DIR/${PACKAGE_NAME}-functional-test-evidence"' in text
    assert 'Test evidence directory:' in text

    # Interactive Brane prompts must retain access to the invoking terminal.
    assert '(cd "$SOURCE_DIR" && ./test.sh) >"$TEST_LOG" 2>&1' not in text
