from pathlib import Path
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "package_admin_review.sh"


def run_admin_review(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *arguments],
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_help_describes_branch_review_interface() -> None:
    result = run_admin_review("--help")

    assert result.returncode == 0
    assert "Usage:" in result.stdout
    assert "--branch <remote-branch>" in result.stdout
    assert "--keep-worktree" in result.stdout
    assert "--package <value>" in result.stdout
    assert "origin/main" in result.stdout


def test_branch_is_required() -> None:
    result = run_admin_review()

    assert result.returncode == 1
    assert "Provide the submitted remote branch" in result.stderr


def test_default_branch_is_rejected_as_a_submission() -> None:
    result = run_admin_review("--branch", "main")

    assert result.returncode == 1
    assert "protected default branch" in result.stderr


def test_invalid_branch_name_is_rejected() -> None:
    result = run_admin_review("--branch", "invalid branch name")

    assert result.returncode == 1
    assert "Invalid branch name" in result.stderr
