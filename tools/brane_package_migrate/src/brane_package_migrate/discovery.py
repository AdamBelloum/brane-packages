"""Non-destructive package candidate discovery."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import re
from typing import Any

import yaml

DEFAULT_CONFIG_NAMES = {
    "container.yml",
}

SKIPPED_DIRECTORIES = {
    ".git",
    ".venv",
    "venv",
    "__pycache__",
    "node_modules",
    "target",
    "build",
    "dist",
}

SENSITIVE_NAME_PATTERN = re.compile(
    r"(^|[-_.])(secret|token|password|credential|private[-_]?key)([-_.]|$)",
    re.IGNORECASE,
)

CONTENT_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("privileged container setting", re.compile(r"\bprivileged\s*:\s*true\b", re.IGNORECASE)),
    ("host network setting", re.compile(r"\bnetwork_mode\s*:\s*host\b", re.IGNORECASE)),
    ("Docker socket reference", re.compile(r"docker\.sock", re.IGNORECASE)),
    ("remote download command", re.compile(r"\b(curl|wget)\b", re.IGNORECASE)),
    ("SSH command or reference", re.compile(r"\bssh\b", re.IGNORECASE)),
)


def _is_within_skipped_directory(path: Path, source: Path) -> bool:
    return any(part in SKIPPED_DIRECTORIES for part in path.relative_to(source).parts)


def _find_candidate_directories(source: Path, config_names: set[str]) -> list[Path]:
    candidates: set[Path] = set()

    for path in source.rglob("*"):
        if _is_within_skipped_directory(path, source) or not path.is_file():
            continue
        if path.name.lower() in config_names:
            candidates.add(path.parent)

    return sorted(candidates, key=lambda item: item.as_posix())


def _findings_for(candidate: Path) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []

    for path in sorted(candidate.rglob("*")):
        if not path.is_file():
            continue

        relative = path.relative_to(candidate).as_posix()
        if SENSITIVE_NAME_PATTERN.search(path.name):
            findings.append(
                {
                    "severity": "blocking",
                    "message": f"Potentially sensitive filename detected: {relative}",
                }
            )

        if path.stat().st_size > 1_000_000:
            findings.append(
                {
                    "severity": "warning",
                    "message": f"Large file requires review before migration: {relative}",
                }
            )
            continue

        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue

        for label, pattern in CONTENT_RULES:
            if pattern.search(content):
                findings.append(
                    {
                        "severity": "warning",
                        "message": f"Review {label} in: {relative}",
                    }
                )

    return findings


def discover(source: Path, config_names: set[str] | None = None) -> dict[str, Any]:
    """Return a manifest proposal without copying or changing source files."""
    source = source.expanduser().resolve()
    if not source.is_dir():
        raise ValueError(f"Source directory does not exist: {source}")

    names = {name.lower() for name in (config_names or DEFAULT_CONFIG_NAMES)}
    candidates = []

    for candidate in _find_candidate_directories(source, names):
        relative_path = candidate.relative_to(source).as_posix()
        findings = _findings_for(candidate)
        review_required = [
            "Confirm this directory is a valid Brane package.",
            "Review all findings and remove sensitive or generated material.",
            "Identify the package author or responsible team in the manifest.",
            "Set an explicit classification and migration action.",
        ]

        candidates.append(
            {
                "source_path": relative_path,
                "discovered_name": candidate.name,
                "classification": "needs-review",
                "action": "manual-review",
                "review_required": review_required,
                "findings": findings,
            }
        )

    return {
        "schema_version": "1.0",
        "source": {
            "type": "local-path",
            "location": str(source),
            "acquired_at": datetime.now(timezone.utc).isoformat(),
        },
        "candidates": candidates,
    }


def write_manifest(manifest: dict[str, Any], output: Path) -> None:
    """Write a proposed manifest. Refuse to overwrite an existing file."""
    output = output.expanduser()
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite existing manifest: {output}")

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        yaml.safe_dump(manifest, handle, sort_keys=False, allow_unicode=True)
