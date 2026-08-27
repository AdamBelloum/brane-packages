from pathlib import Path

import pytest
import yaml

from brane_package_migrate.discovery import discover, write_manifest


def test_discover_allows_an_empty_source_directory(tmp_path: Path) -> None:
    manifest = discover(tmp_path)

    assert manifest["schema_version"] == "1.0"
    assert manifest["source"]["location"] == str(tmp_path.resolve())
    assert manifest["candidates"] == []


def test_discover_marks_candidates_for_manual_review(tmp_path: Path) -> None:
    candidate = tmp_path / "example-package"
    candidate.mkdir()
    (candidate / "branelet.yml").write_text("name: example\n", encoding="utf-8")
    (candidate / "api_token.txt").write_text("not a real token\n", encoding="utf-8")
    (candidate / "Dockerfile").write_text(
        "FROM alpine:3.20\nRUN curl https://example.invalid/tool\n",
        encoding="utf-8",
    )

    manifest = discover(tmp_path)

    assert len(manifest["candidates"]) == 1
    discovered = manifest["candidates"][0]
    assert discovered["source_path"] == "example-package"
    assert discovered["classification"] == "needs-review"
    assert discovered["action"] == "manual-review"
    assert any(
        finding["severity"] == "blocking"
        and "Potentially sensitive filename" in finding["message"]
        for finding in discovered["findings"]
    )
    assert any(
        "remote download command" in finding["message"]
        for finding in discovered["findings"]
    )


def test_write_manifest_refuses_to_overwrite(tmp_path: Path) -> None:
    output = tmp_path / "manifest.yml"
    output.write_text("reviewed: true\n", encoding="utf-8")

    with pytest.raises(FileExistsError):
        write_manifest({"schema_version": "1.0", "candidates": []}, output)


def test_write_manifest_creates_parent_directory(tmp_path: Path) -> None:
    output = tmp_path / "new" / "manifest.yml"

    write_manifest({"schema_version": "1.0", "candidates": []}, output)

    assert yaml.safe_load(output.read_text(encoding="utf-8")) == {
        "schema_version": "1.0",
        "candidates": [],
    }


def test_generated_empty_manifest_conforms_to_migration_schema(tmp_path: Path) -> None:
    output = tmp_path / "manifest.yml"
    write_manifest(discover(tmp_path), output)

    from brane_package_migrate.validation import validate_document

    schema = Path(__file__).resolve().parents[1] / "schemas" / "migration-manifest.schema.yml"
    assert validate_document(output, schema) == []


def _valid_package_metadata(name: str, classification: str) -> dict[str, object]:
    return {
        "schema_version": "1.0",
        "name": name,
        "version": "1.2.3",
        "classification": classification,
        "status": "candidate",
        "maintainers": ["Package Team"],
        "source": {
            "type": "manually-created",
            "location": "this repository",
            "source_path": f"packages/{name}",
        },
        "compatibility": {
            "architectures": ["x86_64"],
            "brane_baseline": "3.0.0-test+dcf91ca6",
        },
        "data_handling": {
            "accepts_user_data": False,
            "bundled_data": "none",
        },
    }


def _write_validation_repository(tmp_path: Path) -> Path:
    repository = tmp_path / "repository"
    (repository / "catalogue").mkdir(parents=True)
    (repository / "schemas").mkdir()
    (repository / "packages" / "example").mkdir(parents=True)

    project_root = Path(__file__).resolve().parents[1]
    for schema_name in (
        "migration-manifest.schema.yml",
        "package-catalogue.schema.yml",
        "package-metadata.schema.yml",
    ):
        (repository / "schemas" / schema_name).write_text(
            (project_root / "schemas" / schema_name).read_text(encoding="utf-8"),
            encoding="utf-8",
        )

    yaml.safe_dump(
        {
            "schema_version": "1.0",
            "packages": [
                {
                    "name": "example",
                    "classification": "shared-package",
                    "status": "candidate",
                    "path": "packages/example",
                    "maintainers": ["Package Team"],
                    "latest_version": "1.2.3",
                }
            ],
        },
        (repository / "catalogue" / "packages.yml").open("w", encoding="utf-8"),
        sort_keys=False,
    )
    yaml.safe_dump(
        _valid_package_metadata("example", "shared-package"),
        (repository / "packages" / "example" / "package.yml").open(
            "w", encoding="utf-8"
        ),
        sort_keys=False,
    )
    return repository


def test_repository_validation_accepts_matching_catalogue_and_metadata(
    tmp_path: Path,
) -> None:
    from brane_package_migrate.repository import validate_repository

    assert validate_repository(_write_validation_repository(tmp_path)) == []


def test_repository_validation_rejects_unindexed_package_directory(
    tmp_path: Path,
) -> None:
    from brane_package_migrate.repository import validate_repository

    repository = _write_validation_repository(tmp_path)
    (repository / "packages" / "unindexed").mkdir()

    assert validate_repository(repository) == [
        "Unindexed shared-package directory: packages/unindexed"
    ]


def test_repository_validation_rejects_catalogue_metadata_mismatch(
    tmp_path: Path,
) -> None:
    from brane_package_migrate.repository import validate_repository

    repository = _write_validation_repository(tmp_path)
    metadata_path = repository / "packages" / "example" / "package.yml"
    metadata = yaml.safe_load(metadata_path.read_text(encoding="utf-8"))
    metadata["status"] = "stable"
    metadata_path.write_text(yaml.safe_dump(metadata, sort_keys=False), encoding="utf-8")

    assert validate_repository(repository) == [
        "catalogue entry 'example': 'status' does not match packages/example/package.yml"
    ]


def _write_migration_manifest(
    repository: Path,
    source: Path,
    *,
    action: str = "migrate",
    findings: list[dict[str, str]] | None = None,
) -> Path:
    manifest = {
        "schema_version": "1.0",
        "source": {
            "type": "local-path",
            "location": str(source),
            "acquired_at": "2026-08-27T12:00:00+00:00",
        },
        "candidates": [
            {
                "source_path": "incoming",
                "target_path": "packages/incoming",
                "classification": "reusable",
                "action": action,
                "findings": findings or [],
            }
        ],
    }
    path = repository / "intake" / "incoming.yml"
    path.parent.mkdir()
    path.write_text(yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8")
    return path


def _write_migration_source(tmp_path: Path) -> Path:
    source = tmp_path / "source"
    incoming = source / "incoming"
    incoming.mkdir(parents=True)
    metadata = _valid_package_metadata("incoming", "shared-package")
    metadata["source"]["source_path"] = "incoming"
    (incoming / "package.yml").write_text(
        yaml.safe_dump(metadata, sort_keys=False), encoding="utf-8"
    )
    (incoming / "branelet.yml").write_text("name: incoming\n", encoding="utf-8")
    return source


def test_migration_dry_run_is_non_destructive(tmp_path: Path) -> None:
    from brane_package_migrate.migration import migrate

    repository = _write_validation_repository(tmp_path)
    source = _write_migration_source(tmp_path)
    manifest = _write_migration_manifest(repository, source)

    assert migrate(manifest, repository) == ["packages/incoming"]
    assert not (repository / "packages" / "incoming").exists()


def test_migration_copies_metadata_valid_package_and_updates_catalogue(
    tmp_path: Path,
) -> None:
    from brane_package_migrate.migration import migrate
    from brane_package_migrate.repository import validate_repository

    repository = _write_validation_repository(tmp_path)
    source = _write_migration_source(tmp_path)
    manifest = _write_migration_manifest(repository, source)

    assert migrate(manifest, repository, execute=True) == ["packages/incoming"]
    assert (repository / "packages" / "incoming" / "branelet.yml").is_file()

    catalogue = yaml.safe_load(
        (repository / "catalogue" / "packages.yml").read_text(encoding="utf-8")
    )
    assert catalogue["packages"][-1]["name"] == "incoming"
    assert catalogue["packages"][-1]["latest_version"] == "1.2.3"
    assert validate_repository(repository) == []


def test_migration_refuses_a_candidate_with_a_blocking_finding(tmp_path: Path) -> None:
    from brane_package_migrate.migration import migrate

    repository = _write_validation_repository(tmp_path)
    source = _write_migration_source(tmp_path)
    manifest = _write_migration_manifest(
        repository,
        source,
        findings=[{"severity": "blocking", "message": "Sensitive material found"}],
    )

    with pytest.raises(ValueError, match="migration is blocked"):
        migrate(manifest, repository, execute=True)

    assert not (repository / "packages" / "incoming").exists()


def test_migration_refuses_a_symlinked_source_candidate(tmp_path: Path) -> None:
    from brane_package_migrate.migration import migrate

    repository = _write_validation_repository(tmp_path)
    source = _write_migration_source(tmp_path)
    incoming = source / "incoming"
    actual_source = source / "actual-incoming"
    incoming.rename(actual_source)
    incoming.symlink_to(actual_source.name, target_is_directory=True)
    manifest = _write_migration_manifest(repository, source)

    with pytest.raises(ValueError, match="containing a symlink"):
        migrate(manifest, repository, execute=True)

    assert not (repository / "packages" / "incoming").exists()


def test_migration_removes_a_partial_target_when_copy_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from brane_package_migrate import migration

    repository = _write_validation_repository(tmp_path)
    source = _write_migration_source(tmp_path)
    manifest = _write_migration_manifest(repository, source)

    def failing_copytree(_: Path, target: Path) -> None:
        target.mkdir()
        raise OSError("simulated copy failure")

    monkeypatch.setattr(migration.shutil, "copytree", failing_copytree)

    with pytest.raises(OSError, match="simulated copy failure"):
        migration.migrate(manifest, repository, execute=True)

    assert not (repository / "packages" / "incoming").exists()
    assert yaml.safe_load(
        (repository / "catalogue" / "packages.yml").read_text(encoding="utf-8")
    )["packages"] == [
        {
            "name": "example",
            "classification": "shared-package",
            "status": "candidate",
            "path": "packages/example",
            "maintainers": ["Package Team"],
            "latest_version": "1.2.3",
        }
    ]
