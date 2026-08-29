from pathlib import Path
import shutil
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "scripts" / "admin" / "package_admin_review.sh"


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
    assert "--pr <number>" in result.stdout
    assert "--keep-worktree" in result.stdout
    assert "--package <value>" in result.stdout
    assert "origin/main" in result.stdout
    assert "does not execute submitted test.sh files" in result.stdout


def test_branch_or_pr_is_required_without_a_terminal() -> None:
    result = run_admin_review()

    assert result.returncode == 1
    assert "Provide --branch or --pr" in result.stderr


def test_branch_and_pr_cannot_be_combined() -> None:
    result = run_admin_review("--branch", "submitted/package", "--pr", "42")

    assert result.returncode == 1
    assert "Use either --branch or --pr, not both" in result.stderr


def test_pr_selector_resolves_an_open_pr_head_branch(
    tmp_path: Path,
    monkeypatch,
) -> None:
    fake_gh = tmp_path / "gh"
    fake_gh.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        '[[ "$1" == "pr" && "$2" == "view" ]]\n'
        'printf "%s\\n" "main"\n',
        encoding="utf-8",
    )
    fake_gh.chmod(0o755)
    monkeypatch.setenv("GH", str(fake_gh))

    result = run_admin_review("--pr", "42")

    assert result.returncode == 1
    assert "protected default branch" in result.stderr


def test_pr_menu_formatter_uses_shell_safe_python_string_formatting() -> None:
    script = SCRIPT.read_text(encoding="utf-8")

    assert '"{}\\t{}\\t{}\\t{}".format(' in script
    assert 'f\'{item["number"]}' not in script


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
    # The fixture remote must test the working-tree version of the review
    # script, including changes that have not yet been committed in PROJECT_ROOT.
    (seed / "scripts" / "admin").mkdir(parents=True, exist_ok=True)
    shutil.copy2(SCRIPT, seed / "scripts" / "admin" / "package_admin_review.sh")
    git_command(seed, "add", "scripts/admin/package_admin_review.sh")
    git_command(seed, "commit", "--allow-empty", "-m", "Use package admin review script under test")

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
            str(administrator / "scripts" / "admin" / "package_admin_review.sh"),
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
    assert "## Review decision" in report
    assert "**PENDING MANUAL TEST**" in report
    assert "test-fixtures/hello_world/test.sh" in report
    assert "Reviewed commit:" in record
    assert "Status:** MANUAL REQUIRED" in record
