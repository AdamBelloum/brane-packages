"""YAML document validation against repository JSON Schemas."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError


def load_yaml_mapping(path: Path) -> dict[str, Any]:
    """Load one YAML mapping and reject empty or non-mapping documents."""
    try:
        with path.open("r", encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except yaml.YAMLError as error:
        raise ValueError(f"Invalid YAML in {path}: {error}") from error
    except OSError as error:
        raise ValueError(f"Cannot read {path}: {error}") from error

    if not isinstance(document, dict):
        raise ValueError(f"Expected a YAML mapping in {path}")
    return document


def validate_mapping(document: dict[str, Any], schema_path: Path) -> list[str]:
    """Return validation errors for an in-memory mapping."""
    schema = load_yaml_mapping(schema_path)

    try:
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
    except SchemaError as error:
        raise ValueError(f"Invalid schema {schema_path}: {error.message}") from error

    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )

    messages: list[str] = []
    for error in errors:
        location = ".".join(str(part) for part in error.absolute_path) or "$"
        messages.append(f"{location}: {error.message}")

    return messages


def validate_document(document_path: Path, schema_path: Path) -> list[str]:
    """Return human-readable validation errors; an empty list means valid."""
    return validate_mapping(load_yaml_mapping(document_path), schema_path)
