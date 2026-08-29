from pathlib import Path
import shutil
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "scripts" / "admin" / "package_admin.sh"


def run_package_admin(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT), *arguments],
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def git_command(cwd: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=True,
    )


def test_help_describes_only_administrator_package_operations() -> None:
    result = run_package_admin("--help")

    assert result.returncode == 0
    assert "Curated package administration" in result.stdout
    assert "--list" in result.stdout
    assert "--remove <package-name>" in result.stdout
    assert "package outcomes rather than implementation steps" in result.stdout
    assert "Git" not in result.stdout


def test_list_shows_catalogue_backed_packages_and_classifications() -> None:
    result = run_package_admin("--list")

    assert result.returncode == 0
    assert "hello_world [test-fixture] test-fixtures/hello_world" in result.stdout
    assert "minmax [shared-package] packages/minmax" in result.stdout


def test_removal_requires_an_exact_confirmation() -> None:
    result = run_package_admin("--remove", "minmax", "--confirm", "not-minmax")

    assert result.returncode == 1
    assert "Removal was not confirmed" in result.stderr


def test_removal_rejects_a_name_that_is_not_in_the_catalogue() -> None:
    result = run_package_admin("--remove", "missing", "--confirm", "missing")

    assert result.returncode == 1
    assert "No current package named 'missing'" in result.stderr


def test_removal_creates_a_valid_pull_request_without_exposing_git_details(
    tmp_path: Path,
) -> None:
    remote = tmp_path / "remote.git"
    seed = tmp_path / "seed"
    administrator = tmp_path / "administrator"
    fake_gh = tmp_path / "gh"

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

    (seed / "scripts" / "admin").mkdir(parents=True, exist_ok=True)
    shutil.copy2(SCRIPT, seed / "scripts" / "admin" / "package_admin.sh")
    shutil.copy2(
        PROJECT_ROOT / "tests" / "test_removal_review_evidence.py",
        seed / "tests" / "test_removal_review_evidence.py",
    )
    git_command(
        seed,
        "add",
        "scripts/admin/package_admin.sh",
        "tests/test_removal_review_evidence.py",
    )
    git_command(
        seed,
        "commit",
        "--allow-empty",
        "-m",
        "Use administrator package interface under test",
    )

    git_command(seed, "remote", "set-url", "origin", str(remote))
    git_command(seed, "push", "--force", "origin", "HEAD:main")

    subprocess.run(
        ["git", "clone", "--branch", "main", str(remote), str(administrator)],
        text=True,
        capture_output=True,
        check=True,
    )
    git_command(administrator, "config", "user.name", "Package Administrator")
    git_command(
        administrator,
        "config",
        "user.email",
        "package-admin@example.invalid",
    )

    fake_gh.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        'case "$1 $2" in\n'
        '  "auth status") exit 0 ;;\n'
        '  "repo view") printf "%s\\n" "example/brane-packages" ;;\n'
        '  "pr create") printf "%s\\n" "https://example.invalid/pr/1" ;;\n'
        '  *) printf "unexpected gh command: %s %s\\n" "$1" "$2" >&2; exit 2 ;;\n'
        "esac\n",
        encoding="utf-8",
    )
    fake_gh.chmod(0o755)

    result = subprocess.run(
        [
            "bash",
            str(administrator / "scripts" / "admin" / "package_admin.sh"),
            "--remove",
            "minmax",
            "--confirm",
            "minmax",
        ],
        cwd=administrator,
        text=True,
        capture_output=True,
        check=False,
        env={
            **__import__("os").environ,
            "PYTHON": str(PROJECT_ROOT / ".venv" / "bin" / "python"),
            "MIGRATOR": str(PROJECT_ROOT / ".venv" / "bin" / "brane-package-migrate"),
            "GH": str(fake_gh),
        },
    )

    assert result.returncode == 0, result.stderr
    assert "Removal request created." in result.stdout
    assert "Package: minmax [shared-package]" in result.stdout
    assert "Repository validation: passed" in result.stdout
    assert "Repository checks: passed" in result.stdout
    assert "Pull request: https://example.invalid/pr/1" in result.stdout
    assert "admin/remove-" not in result.stdout
    assert "Fetching origin" not in result.stdout

    removal_checkout = tmp_path / "removal-checkout"
    subprocess.run(
        [
            "git",
            "clone",
            "--branch",
            next(
                line.removeprefix("  ")
                for line in subprocess.run(
                    ["git", "--git-dir", str(remote), "branch", "--format=%(refname:short)"],
                    text=True,
                    capture_output=True,
                    check=True,
                ).stdout.splitlines()
                if line.strip().startswith("admin/remove-")
            ).strip(),
            str(remote),
            str(removal_checkout),
        ],
        text=True,
        capture_output=True,
        check=True,
    )

    assert not (removal_checkout / "packages" / "minmax").exists()
    assert not (removal_checkout / "intake" / "minmax-review.yml").exists()
    assert "name: minmax" not in (
        removal_checkout / "catalogue" / "packages.yml"
    ).read_text(encoding="utf-8")
