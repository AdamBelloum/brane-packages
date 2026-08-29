#!/usr/bin/env python3
"""Structural audit support for package Pull Request review."""

from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path, PurePosixPath
import subprocess
from typing import Any

import yaml


PACKAGE_ROOTS = {
    "packages": {"manifest_classification": "reusable"},
    "test-fixtures": {"manifest_classification": "fixture"},
}
SENSITIVE_FILE_PATTERNS = (
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.crt",
    "*.cer",
    "*.csr",
    "*.jwt",
    "*.token",
    "*secret*",
    "*token*",
)


class AuditError(RuntimeError):
    """Raised when Git history cannot be inspected."""


def _git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "Git command failed."
        raise AuditError(message)
    return result.stdout


def changed_paths(repository: Path, base_commit: str, head_commit: str) -> list[str]:
    """Return added, copied, modified, or renamed paths between two commits."""
    output = _git(
        repository,
        "diff",
        "--name-only",
        "--diff-filter=ACMR",
        base_commit,
        head_commit,
    )
    return sorted(path for path in output.splitlines() if path)


def changed_package_paths(paths: list[str]) -> list[str]:
    """Return unique package roots touched by a set of repository-relative paths."""
    candidates: set[str] = set()

    for changed_path in paths:
        parts = PurePosixPath(changed_path).parts
        if len(parts) >= 2 and parts[0] in PACKAGE_ROOTS:
            candidates.add(f"{parts[0]}/{parts[1]}")

    return sorted(candidates)


def _read_yaml(path: Path, errors: list[str], label: str) -> dict[str, Any] | None:
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        errors.append(f"Cannot read {label}: {exc}")
        return None

    if not isinstance(document, dict):
        errors.append(f"{label} must contain a YAML mapping.")
        return None
    return document


def _matching_manifests(worktree: Path, target_path: str) -> list[Path]:
    matches: list[Path] = []

    for manifest_path in sorted((worktree / "intake").glob("*-review.yml")):
        try:
            document = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError):
            continue

        if not isinstance(document, dict):
            continue
        candidates = document.get("candidates")
        if not isinstance(candidates, list):
            continue

        for candidate in candidates:
            if isinstance(candidate, dict) and candidate.get("target_path") == target_path:
                matches.append(manifest_path)
                break

    return matches


def _sensitive_files(files: list[str]) -> list[str]:
    return [
        file_name
        for file_name in files
        if any(
            fnmatch.fnmatch(Path(file_name).name.lower(), pattern)
            for pattern in SENSITIVE_FILE_PATTERNS
        )
    ]


def audit_package(worktree: Path, target_path: str) -> dict[str, Any]:
    """Audit one changed package directory and return JSON-serialisable findings."""
    package_dir = worktree / target_path
    path_parts = PurePosixPath(target_path).parts
    package_name = path_parts[1]
    package_root = path_parts[0]
    errors: list[str] = []
    warnings: list[str] = []

    result: dict[str, Any] = {
        "target_path": target_path,
        "package_name": package_name,
        "kind": package_root,
        "required_manifest_classification": PACKAGE_ROOTS[package_root][
            "manifest_classification"
        ],
        "files": [],
        "manifest_paths": [],
        "errors": errors,
        "warnings": warnings,
    }

    if not package_dir.is_dir():
        errors.append(f"Changed package directory is absent at reviewed commit: {target_path}")
        return result

    files = sorted(
        item.relative_to(package_dir).as_posix()
        for item in package_dir.rglob("*")
        if item.is_file()
    )
    result["files"] = files

    container_path = package_dir / "container.yml"
    metadata_path = package_dir / "package.yml"
    test_path = package_dir / "test.sh"

    if not container_path.is_file():
        errors.append("Required package descriptor is missing: container.yml")
    if not metadata_path.is_file():
        errors.append("Required package metadata is missing: package.yml")
    if not test_path.is_file():
        errors.append("Required functional test is missing: test.sh")
    elif not test_path.stat().st_mode & 0o111:
        errors.append("Required functional test is not executable: test.sh")

    descriptor = (
        _read_yaml(container_path, errors, "container.yml") if container_path.is_file() else None
    )
    metadata = (
        _read_yaml(metadata_path, errors, "package.yml") if metadata_path.is_file() else None
    )

    if descriptor is not None and descriptor.get("name") != package_name:
        errors.append(
            f"container.yml name must match directory name '{package_name}'."
        )
    if metadata is not None and metadata.get("name") != package_name:
        errors.append(
            f"package.yml name must match directory name '{package_name}'."
        )

    manifests = _matching_manifests(worktree, target_path)
    result["manifest_paths"] = [
        manifest.relative_to(worktree).as_posix() for manifest in manifests
    ]
    if not manifests:
        errors.append(
            f"No intake/*-review.yml candidate targets {target_path}."
        )
    elif len(manifests) > 1:
        errors.append(
            f"Multiple intake review manifests target {target_path}: "
            + ", ".join(result["manifest_paths"])
        )

    sensitive_files = _sensitive_files(files)
    if sensitive_files:
        errors.append(
            "Potentially sensitive filename(s): " + ", ".join(sensitive_files)
        )

    return result


def audit_changed_packages(
    worktree: Path, base_commit: str, head_commit: str
) -> dict[str, Any]:
    """Audit every package directory changed between base and reviewed commits."""
    paths = changed_paths(worktree, base_commit, head_commit)
    package_paths = changed_package_paths(paths)

    return {
        "base_commit": _git(worktree, "rev-parse", f"{base_commit}^{{commit}}").strip(),
        "head_commit": _git(worktree, "rev-parse", f"{head_commit}^{{commit}}").strip(),
        "changed_paths": paths,
        "candidates": [audit_package(worktree, path) for path in package_paths],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Brane package directories changed in a Git review range."
    )
    parser.add_argument("--worktree", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()

    try:
        report = audit_changed_packages(
            arguments.worktree.resolve(), arguments.base, arguments.head
        )
    except AuditError as exc:
        parser.error(str(exc))

    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
