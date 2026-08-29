from pathlib import Path
import subprocess
import sys

import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from tools.admin_review_audit import audit_changed_packages, changed_package_paths


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def commit_all(repository: Path, message: str) -> str:
    git(repository, "add", ".")
    git(repository, "commit", "-m", message)
    return git(repository, "rev-parse", "HEAD")


def write_reviewed_package(repository: Path, *, executable_test: bool = True) -> None:
    package = repository / "packages" / "example"
    package.mkdir(parents=True)
    (package / "container.yml").write_text(
        yaml.safe_dump({"name": "example", "version": "1.0.0"}, sort_keys=False),
        encoding="utf-8",
    )
    (package / "package.yml").write_text(
        yaml.safe_dump({"name": "example", "version": "1.0.0"}, sort_keys=False),
        encoding="utf-8",
    )
    test_script = package / "test.sh"
    test_script.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    if executable_test:
        test_script.chmod(0o755)

    intake = repository / "intake"
    intake.mkdir()
    (intake / "example-review.yml").write_text(
        yaml.safe_dump(
            {
                "schema_version": "1.0",
                "candidates": [{"target_path": "packages/example"}],
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )


def make_repository(tmp_path: Path) -> tuple[Path, str]:
    repository = tmp_path / "repository"
    repository.mkdir()
    git(repository, "init")
    git(repository, "config", "user.name", "Test User")
    git(repository, "config", "user.email", "test@example.invalid")
    (repository / "README.md").write_text("baseline\n", encoding="utf-8")
    return repository, commit_all(repository, "Baseline")


def test_changed_package_paths_uses_package_roots_only() -> None:
    assert changed_package_paths(
        [
            "README.md",
            "packages/minmax/container.yml",
            "packages/minmax/test.sh",
            "test-fixtures/hello_world/container.yml",
            "intake/minmax-review.yml",
        ]
    ) == ["packages/minmax", "test-fixtures/hello_world"]


def test_audit_accepts_a_complete_changed_package(tmp_path: Path) -> None:
    repository, base = make_repository(tmp_path)
    write_reviewed_package(repository)
    head = commit_all(repository, "Add example package")

    report = audit_changed_packages(repository, base, head)

    assert report["candidates"][0]["target_path"] == "packages/example"
    assert report["candidates"][0]["errors"] == []
    assert report["candidates"][0]["manifest_paths"] == ["intake/example-review.yml"]


def test_audit_requires_an_executable_test_script(tmp_path: Path) -> None:
    repository, base = make_repository(tmp_path)
    write_reviewed_package(repository, executable_test=False)
    head = commit_all(repository, "Add incomplete example package")

    report = audit_changed_packages(repository, base, head)

    assert "Required functional test is not executable: test.sh" in report["candidates"][0][
        "errors"
    ]


def test_audit_flags_sensitive_filenames(tmp_path: Path) -> None:
    repository, base = make_repository(tmp_path)
    write_reviewed_package(repository)
    (repository / "packages" / "example" / "api_token.txt").write_text(
        "not a real token\n", encoding="utf-8"
    )
    head = commit_all(repository, "Add sensitive-looking file")

    report = audit_changed_packages(repository, base, head)

    assert any(
        "Potentially sensitive filename(s): api_token.txt" == finding
        for finding in report["candidates"][0]["errors"]
    )
