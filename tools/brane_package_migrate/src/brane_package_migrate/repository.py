"""Repository-level validation beyond individual JSON Schema documents."""

from __future__ import annotations

from pathlib import Path
from brane_package_migrate.validation import load_yaml_mapping, validate_document


_PACKAGE_ROOTS = {
    "shared-package": "packages",
    "test-fixture": "test-fixtures",
}


def validate_repository(repository_root: Path) -> list[str]:
    """Return all catalogue, metadata, and package-layout validation errors."""
    root = repository_root.resolve()
    catalogue_path = root / "catalogue" / "packages.yml"
    catalogue_schema = root / "schemas" / "package-catalogue.schema.yml"
    metadata_schema = root / "schemas" / "package-metadata.schema.yml"

    errors: list[str] = []

    for required_path in (catalogue_path, catalogue_schema, metadata_schema):
        if not required_path.is_file():
            errors.append(f"Missing required file: {required_path.relative_to(root)}")

    if errors:
        return errors

    try:
        catalogue_errors = validate_document(catalogue_path, catalogue_schema)
    except ValueError as error:
        return [str(error)]

    errors.extend(f"catalogue/packages.yml: {error}" for error in catalogue_errors)
    if catalogue_errors:
        return errors

    catalogue = load_yaml_mapping(catalogue_path)
    entries = catalogue["packages"]
    indexed_paths: set[str] = set()
    indexed_names: set[str] = set()

    for entry in entries:
        name = entry["name"]
        classification = entry["classification"]
        package_path = entry["path"]
        label = f"catalogue entry {name!r}"

        if name in indexed_names:
            errors.append(f"{label}: duplicate package name")
        indexed_names.add(name)

        if package_path in indexed_paths:
            errors.append(f"{label}: duplicate package path {package_path!r}")
        indexed_paths.add(package_path)

        expected_path = f"{_PACKAGE_ROOTS[classification]}/{name}"
        if package_path != expected_path:
            errors.append(
                f"{label}: path must be {expected_path!r} for classification "
                f"{classification!r}"
            )
            continue

        package_dir = root / package_path
        try:
            package_dir.resolve().relative_to(root)
        except ValueError:
            errors.append(f"{label}: path resolves outside the repository")
            continue

        if not package_dir.is_dir():
            errors.append(f"{label}: package directory does not exist: {package_path}")
            continue

        metadata_path = package_dir / "package.yml"
        if not metadata_path.is_file():
            errors.append(f"{label}: missing required metadata file: {package_path}/package.yml")
            continue

        try:
            metadata_errors = validate_document(metadata_path, metadata_schema)
        except ValueError as error:
            errors.append(str(error))
            continue

        errors.extend(
            f"{package_path}/package.yml: {error}" for error in metadata_errors
        )
        if metadata_errors:
            continue

        metadata = load_yaml_mapping(metadata_path)
        for field in ("name", "classification", "status", "maintainers"):
            if entry[field] != metadata[field]:
                errors.append(
                    f"{label}: {field!r} does not match "
                    f"{package_path}/package.yml"
                )

        if "latest_version" in entry and entry["latest_version"] != metadata["version"]:
            errors.append(
                f"{label}: 'latest_version' does not match "
                f"{package_path}/package.yml version"
            )

    for classification, directory_name in _PACKAGE_ROOTS.items():
        package_root = root / directory_name
        if not package_root.exists():
            continue
        if not package_root.is_dir():
            errors.append(f"{directory_name} must be a directory")
            continue

        for child in sorted(package_root.iterdir()):
            if child.name.startswith(".") or not child.is_dir():
                continue

            relative_path = child.relative_to(root).as_posix()
            if relative_path not in indexed_paths:
                errors.append(
                    f"Unindexed {classification} directory: {relative_path}"
                )

    return errors
