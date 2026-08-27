"""Controlled, metadata-gated migration of reviewed package candidates."""

from __future__ import annotations

from pathlib import Path
import shutil
from typing import Any

import yaml

from brane_package_migrate.repository import validate_repository
from brane_package_migrate.validation import load_yaml_mapping, validate_document

_CLASSIFICATION_TARGETS = {
    "reusable": ("shared-package", "packages"),
    "fixture": ("test-fixture", "test-fixtures"),
}


def _safe_relative_path(value: str, root: Path, label: str) -> Path:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"{label} must be a relative path without '..': {value!r}")

    return root / path


def _reject_symlink_ancestors(path: Path, root: Path) -> None:
    current = path.parent
    while current != root:
        if current.is_symlink():
            raise ValueError(f"Refusing path beneath a symlink: {path}")
        current = current.parent


def _reject_symlinks(directory: Path) -> None:
    for path in (directory, *directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Refusing candidate containing a symlink: {path}")


def _load_approved_candidates(
    manifest_path: Path, repository_root: Path
) -> list[dict[str, Any]]:
    manifest_schema = repository_root / "schemas" / "migration-manifest.schema.yml"
    errors = validate_document(manifest_path, manifest_schema)
    if errors:
        detail = "\n".join(f"  - {error}" for error in errors)
        raise ValueError(f"Migration manifest validation failed:\n{detail}")

    manifest = load_yaml_mapping(manifest_path)
    source = manifest["source"]
    if source["type"] != "local-path":
        raise ValueError("Only local-path manifest sources are supported")

    source_root = Path(source["location"]).expanduser().resolve()
    if not source_root.is_dir():
        raise ValueError(f"Manifest source directory does not exist: {source_root}")

    metadata_schema = repository_root / "schemas" / "package-metadata.schema.yml"
    approved: list[dict[str, Any]] = []
    target_paths: set[Path] = set()
    package_names: set[str] = set()

    for index, candidate in enumerate(manifest["candidates"]):
        if candidate["action"] != "migrate":
            continue

        label = f"candidates.{index}"
        classification = candidate["classification"]
        if classification not in _CLASSIFICATION_TARGETS:
            raise ValueError(
                f"{label}: action 'migrate' requires classification "
                f"'reusable' or 'fixture'"
            )

        if any(finding["severity"] == "blocking" for finding in candidate.get("findings", [])):
            raise ValueError(f"{label}: migration is blocked by a blocking finding")

        if "target_path" not in candidate:
            raise ValueError(f"{label}: action 'migrate' requires target_path")

        candidate_dir = _safe_relative_path(
            candidate["source_path"], source_root, f"{label}.source_path"
        )
        if not candidate_dir.is_dir():
            raise ValueError(f"{label}: source candidate is not a directory: {candidate_dir}")
        _reject_symlinks(candidate_dir)

        metadata_path = candidate_dir / "package.yml"
        if not metadata_path.is_file():
            raise ValueError(f"{label}: source candidate lacks required package.yml")

        metadata_errors = validate_document(metadata_path, metadata_schema)
        if metadata_errors:
            detail = "\n".join(f"  - {error}" for error in metadata_errors)
            raise ValueError(f"{label}: source package.yml is invalid:\n{detail}")
        metadata = load_yaml_mapping(metadata_path)

        metadata_classification, target_root = _CLASSIFICATION_TARGETS[classification]
        if metadata["classification"] != metadata_classification:
            raise ValueError(
                f"{label}: manifest classification does not match package.yml "
                f"classification"
            )

        target_path = _safe_relative_path(
            candidate["target_path"], repository_root, f"{label}.target_path"
        )
        _reject_symlink_ancestors(target_path, repository_root)
        expected_target = repository_root / target_root / metadata["name"]
        if target_path != expected_target:
            raise ValueError(
                f"{label}: target_path must be "
                f"{expected_target.relative_to(repository_root).as_posix()!r}"
            )
        if target_path.exists():
            raise ValueError(f"{label}: target already exists: {target_path}")
        if target_path in target_paths:
            raise ValueError(f"{label}: duplicate migration target: {target_path}")
        if metadata["name"] in package_names:
            raise ValueError(f"{label}: duplicate migrated package name: {metadata['name']!r}")

        target_paths.add(target_path)
        package_names.add(metadata["name"])
        approved.append(
            {
                "source": candidate_dir,
                "target": target_path,
                "metadata": metadata,
            }
        )

    return approved


def migrate(manifest_path: Path, repository_root: Path, *, execute: bool = False) -> list[str]:
    """Validate a reviewed manifest and optionally perform its approved migrations."""
    root = repository_root.resolve()
    existing_errors = validate_repository(root)
    if existing_errors:
        detail = "\n".join(f"  - {error}" for error in existing_errors)
        raise ValueError(f"Repository is invalid before migration:\n{detail}")

    approved = _load_approved_candidates(manifest_path, root)
    if not execute:
        return [item["target"].relative_to(root).as_posix() for item in approved]

    catalogue_path = root / "catalogue" / "packages.yml"
    original_catalogue = catalogue_path.read_text(encoding="utf-8")
    catalogue = load_yaml_mapping(catalogue_path)
    created_targets: list[Path] = []

    try:
        for item in approved:
            target = item["target"]
            target.parent.mkdir(parents=True, exist_ok=True)
            created_targets.append(target)
            shutil.copytree(item["source"], target)

            metadata = item["metadata"]
            entry: dict[str, Any] = {
                "name": metadata["name"],
                "classification": metadata["classification"],
                "status": metadata["status"],
                "path": target.relative_to(root).as_posix(),
                "maintainers": metadata["maintainers"],
                "latest_version": metadata["version"],
            }
            if "description" in metadata:
                entry["description"] = metadata["description"]
            catalogue["packages"].append(entry)

        with catalogue_path.open("w", encoding="utf-8") as handle:
            yaml.safe_dump(catalogue, handle, sort_keys=False, allow_unicode=True)

        resulting_errors = validate_repository(root)
        if resulting_errors:
            detail = "\n".join(f"  - {error}" for error in resulting_errors)
            raise ValueError(f"Repository is invalid after migration:\n{detail}")
    except Exception:
        for target in reversed(created_targets):
            shutil.rmtree(target, ignore_errors=True)
        catalogue_path.write_text(original_catalogue, encoding="utf-8")
        raise

    return [item["target"].relative_to(root).as_posix() for item in approved]
