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
    assert "does not execute submitted test.sh files" in result.stdout


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


def git_command(cwd: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=True,
    )


def test_review_prepares_manual_test_record_without_executing_submitted_code(
    tmp_path: Path,
    monkeypatch,
) -> None:
    remote = tmp_path / "review-remote.git"
    seed = tmp_path / "seed"
    submission = tmp_path / "submission"
    administrator = tmp_path / "administrator"

    subprocess.run(
        ["git", "init", "--bare", str(remote)],
        text=True,
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["git", "clone", str(PROJECT_ROOT), str(seed)],
        text=True,
        capture_output=True,
        check=True,
    )
    git_command(seed, "remote", "set-url", "origin", str(remote))
    git_command(seed, "push", "--force", "origin", "HEAD:main")

    subprocess.run(
        ["git", "clone", "--branch", "main", str(remote), str(submission)],
        text=True,
        capture_output=True,
        check=True,
    )
    git_command(submission, "config", "user.name", "Admin review test")
    git_command(submission, "config", "user.email", "admin-review-test@example.invalid")
    git_command(submission, "switch", "-c", "submitted/hello-world-test")

    submitted_test = submission / "test-fixtures" / "hello_world" / "test.sh"
    submitted_test.write_text(
        "#!/bin/sh\n"
        "# This must not be executed by package_admin_review.sh.\n"
        "exit 99\n",
        encoding="utf-8",
    )
    submitted_test.chmod(0o755)
    git_command(submission, "add", "test-fixtures/hello_world/test.sh")
    git_command(submission, "commit", "-m", "Add hello world test script")
    git_command(submission, "push", "-u", "origin", "submitted/hello-world-test")

    subprocess.run(
        ["git", "clone", "--branch", "main", str(remote), str(administrator)],
        text=True,
        capture_output=True,
        check=True,
    )

    monkeypatch.setenv("PYTHON", str(PROJECT_ROOT / ".venv" / "bin" / "python"))
    monkeypatch.setenv(
        "ADMIN_AUDIT_TOOL",
        str(PROJECT_ROOT / "tools" / "admin_review_audit.py"),
    )
    monkeypatch.setenv(
        "MIGRATOR",
        str(PROJECT_ROOT / ".venv" / "bin" / "brane-package-migrate"),
    )

    result = subprocess.run(
        [
            "bash",
            str(administrator / "package_admin_review.sh"),
            "--branch",
            "submitted/hello-world-test",
        ],
        cwd=administrator,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "Review environment prepared." in result.stdout
    assert "Manual test record:" in result.stdout

    reports = list((administrator / ".admin-review" / "reports").glob("review-*.md"))
    records = list((administrator / ".admin-review" / "logs").glob("manual-test-*.md"))
    assert len(reports) == 1
    assert len(records) == 1

    report = reports[0].read_text(encoding="utf-8")
    record = records[0].read_text(encoding="utf-8")

    assert "AUDIT:        PASSED" in report
    assert "METADATA:     PASSED" in report
    assert "PACKAGE TEST: MANUAL REQUIRED" in report
    assert "test-fixtures/hello_world/test.sh" in report
    assert "Reviewed commit:" in record
    assert "Status:** MANUAL REQUIRED" in record
