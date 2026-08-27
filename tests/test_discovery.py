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
