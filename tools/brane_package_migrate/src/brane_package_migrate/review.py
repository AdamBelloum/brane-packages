"""Interactive completion of package-intake review manifests."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from typing import Any

import yaml

from brane_package_migrate.validation import load_yaml_mapping, validate_mapping

Input = Callable[[str], str]
Output = Callable[[str], None]

CLASSIFICATIONS = ("reusable", "fixture", "unsupported", "needs-review")
ACTIONS = ("manual-review", "migrate", "ignore")
STATUSES = ("intake", "candidate", "stable", "deprecated", "retired")
ARCHITECTURES = ("x86_64", "aarch64")
BUNDLED_DATA = ("none", "synthetic-fixtures-only")


def _text(
    input_fn: Input,
    prompt: str,
    current: str | None = None,
    *,
    default: str | None = None,
    required: bool = True,
) -> str:
    if current:
        return current

    suffix = f" [{default}]" if default else ""
    while True:
        value = input_fn(f"{prompt}{suffix}: ").strip() or (default or "")
        if value or not required:
            return value
        print("A value is required.")


def _choice(
    input_fn: Input, prompt: str, choices: tuple[str, ...], current: str | None = None
) -> str:
    default = current if current in choices else None
    suffix = f" [{default}]" if default else ""
    while True:
        value = input_fn(f"{prompt} ({', '.join(choices)}){suffix}: ").strip()
        value = value or default or ""
        if value in choices:
            return value
        print(f"Choose one of: {', '.join(choices)}.")


def _yes_no(input_fn: Input, prompt: str, current: bool | None = None) -> bool:
    if isinstance(current, bool):
        return current

    while True:
        value = input_fn(f"{prompt} (yes/no): ").strip().lower()
        if value in {"yes", "y"}:
            return True
        if value in {"no", "n"}:
            return False
        print("Answer yes or no.")


def _string_list(
    input_fn: Input,
    prompt: str,
    current: object = None,
    *,
    default: list[str] | None = None,
) -> list[str]:
    if isinstance(current, list) and current and all(
        isinstance(value, str) and value.strip() for value in current
    ):
        return current

    rendered_default = ", ".join(default or [])
    suffix = f" [{rendered_default}]" if rendered_default else ""
    while True:
        value = input_fn(f"{prompt} (comma-separated){suffix}: ").strip()
        values = [item.strip() for item in value.split(",") if item.strip()]
        if not values and default:
            values = default
        if values:
            return values
        print("At least one value is required.")


def _curation(
    candidate: dict[str, Any], input_fn: Input, author_name: str
) -> None:
    curation = candidate.setdefault("curation", {})
    if not isinstance(curation, dict):
        raise ValueError(f"{candidate['source_path']}: curation must be a mapping")

    discovered_name = candidate.get("discovered_name") or Path(
        candidate["source_path"]
    ).name
    target_root = (
        "packages" if candidate["classification"] == "reusable" else "test-fixtures"
    )
    candidate["target_path"] = _text(
        input_fn,
        "Target path",
        candidate.get("target_path"),
        default=f"{target_root}/{discovered_name}",
    )
    curation["status"] = _choice(
        input_fn, "Curation status", STATUSES, curation.get("status")
    )
    curation["description"] = _text(
        input_fn, "Package description", curation.get("description")
    )
    curation["maintainers"] = _string_list(
        input_fn,
        "Maintainers",
        curation.get("maintainers"),
        default=[author_name],
    )
    compatibility = curation.setdefault("compatibility", {})
    if not isinstance(compatibility, dict):
        raise ValueError(f"{candidate['source_path']}: compatibility must be a mapping")
    compatibility["architectures"] = _string_list(
        input_fn, "Supported architectures", compatibility.get("architectures")
    )
    invalid_architectures = set(compatibility["architectures"]) - set(ARCHITECTURES)
    if invalid_architectures:
        raise ValueError(
            f"{candidate['source_path']}: unsupported architectures: "
            f"{', '.join(sorted(invalid_architectures))}"
        )
    compatibility["brane_baseline"] = _text(
        input_fn, "Brane baseline", compatibility.get("brane_baseline")
    )

    data_handling = curation.setdefault("data_handling", {})
    if not isinstance(data_handling, dict):
        raise ValueError(f"{candidate['source_path']}: data_handling must be a mapping")
    data_handling["accepts_user_data"] = _yes_no(
        input_fn, "Accepts user data", data_handling.get("accepts_user_data")
    )
    data_handling["bundled_data"] = _choice(
        input_fn,
        "Bundled data",
        BUNDLED_DATA,
        data_handling.get("bundled_data"),
    )


def review_manifest(
    manifest_path: Path,
    schema_path: Path,
    *,
    input_fn: Input = input,
    output_fn: Output = print,
) -> None:
    """Prompt for missing review data and overwrite only a valid manifest."""
    document = load_yaml_mapping(manifest_path)
    candidates = document.get("candidates")
    if not isinstance(candidates, list):
        raise ValueError("Manifest candidates must be a list")

    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise ValueError("Each manifest candidate must be a mapping")

        source_path = candidate.get("source_path", "<unknown>")
        output_fn(f"\nReviewing {source_path}")
        if candidate.get("action") == "ignore":
            output_fn("Candidate is ignored; no review questions asked.")
            continue

        author = candidate.setdefault("author", {})
        if not isinstance(author, dict):
            raise ValueError(f"{source_path}: author must be a mapping")
        author_name = _text(input_fn, "Author or responsible team", author.get("name"))
        author["name"] = author_name
        contact = _text(
            input_fn, "Author contact (optional)", author.get("contact"), required=False
        )
        if contact:
            author["contact"] = contact

        candidate["classification"] = _choice(
            input_fn,
            "Classification",
            CLASSIFICATIONS,
            candidate.get("classification"),
        )
        candidate["action"] = _choice(
            input_fn, "Review action", ACTIONS, candidate.get("action")
        )
        if candidate["action"] == "migrate":
            _curation(candidate, input_fn, author_name)

    errors = validate_mapping(document, schema_path)
    if errors:
        raise ValueError("Reviewed manifest is invalid:\n- " + "\n- ".join(errors))

    manifest_path.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    output_fn(f"Updated reviewed manifest: {manifest_path}")
