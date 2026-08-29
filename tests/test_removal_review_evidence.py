from pathlib import Path

import pytest
import yaml

from brane_package_migrate.migration import remove_package


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _write_repository(tmp_path: Path) -> Path:
    repository = tmp_path / "repository"
    (repository / "catalogue").mkdir(parents=True)
    (repository / "schemas").mkdir()
    (repository / "packages" / "example").mkdir(parents=True)

    for schema_name in (
        "migration-manifest.schema.yml",
        "package-catalogue.schema.yml",
        "package-metadata.schema.yml",
    ):
        (repository / "schemas" / schema_name).write_text(
            (PROJECT_ROOT / "schemas" / schema_name).read_text(encoding="utf-8"),
            encoding="utf-8",
        )

    catalogue = {
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
    }
    metadata = {
        "schema_version": "1.0",
        "name": "example",
        "version": "1.2.3",
        "classification": "shared-package",
        "status": "candidate",
        "maintainers": ["Package Team"],
        "source": {
            "type": "local-path",
            "location": "source",
            "source_path": ".",
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

    (repository / "catalogue" / "packages.yml").write_text(
        yaml.safe_dump(catalogue, sort_keys=False),
        encoding="utf-8",
    )
    (repository / "packages" / "example" / "package.yml").write_text(
        yaml.safe_dump(metadata, sort_keys=False),
        encoding="utf-8",
    )
    return repository


def _candidate(target_path: str) -> dict[str, str]:
    return {
        "source_path": target_path.rsplit("/", 1)[-1],
        "classification": "reusable",
        "action": "manual-review",
        "target_path": target_path,
    }


def _write_manifest(repository: Path, candidates: list[dict[str, str]]) -> Path:
    manifest = repository / "intake" / "example-review.yml"
    manifest.parent.mkdir()
    manifest.write_text(
        yaml.safe_dump(
            {
                "schema_version": "1.0",
                "source": {
                    "type": "local-path",
                    "location": "source",
                    "acquired_at": "2026-08-29T12:00:00+00:00",
                },
                "candidates": candidates,
            },
            sort_keys=False,
        ),
        encoding="utf-8",
    )
    return manifest


def test_removal_deletes_a_single_matching_review_manifest(tmp_path: Path) -> None:
    repository = _write_repository(tmp_path)
    manifest = _write_manifest(repository, [_candidate("packages/example")])

    assert remove_package(
        "example",
        repository,
        execute=True,
        remove_review_evidence=True,
    ) == ["packages/example"]

    assert not (repository / "packages" / "example").exists()
    assert not manifest.exists()


def test_removal_preserves_unrelated_candidates_in_shared_manifest(
    tmp_path: Path,
) -> None:
    repository = _write_repository(tmp_path)
    manifest = _write_manifest(
        repository,
        [
            _candidate("packages/example"),
            _candidate("packages/unrelated"),
        ],
    )

    remove_package(
        "example",
        repository,
        execute=True,
        remove_review_evidence=True,
    )

    retained = yaml.safe_load(manifest.read_text(encoding="utf-8"))
    assert retained["candidates"] == [_candidate("packages/unrelated")]


def test_removal_with_evidence_requires_one_matching_candidate(tmp_path: Path) -> None:
    repository = _write_repository(tmp_path)

    with pytest.raises(ValueError, match="exactly one matching intake review candidate"):
        remove_package(
            "example",
            repository,
            execute=True,
            remove_review_evidence=True,
        )

    assert (repository / "packages" / "example").is_dir()
    catalogue = yaml.safe_load(
        (repository / "catalogue" / "packages.yml").read_text(encoding="utf-8")
    )
    assert [entry["name"] for entry in catalogue["packages"]] == ["example"]
