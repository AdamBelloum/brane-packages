"""Command-line interface for safe Brane package intake."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from brane_package_migrate import __version__
from brane_package_migrate.discovery import discover, write_manifest
from brane_package_migrate.repository import validate_repository
from brane_package_migrate.validation import validate_document


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="brane-package-migrate",
        description="Discover and safely migrate Brane package candidates.",
    )
    parser.add_argument("--version", action="version", version=__version__)

    subcommands = parser.add_subparsers(dest="command", required=True)

    discover_parser = subcommands.add_parser(
        "discover",
        help="Scan a source directory and create a review-only migration manifest.",
    )
    discover_parser.add_argument(
        "--source",
        type=Path,
        required=True,
        help="Directory or repository checkout to inspect.",
    )
    discover_parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="New manifest path to create; existing files are never overwritten.",
    )
    discover_parser.add_argument(
        "--config-name",
        action="append",
        default=[],
        help=(
            "Additional package configuration filename to recognise. "
            "May be specified more than once."
        ),
    )

    validate_parser = subcommands.add_parser(
        "validate",
        help="Validate a YAML document against a repository JSON Schema.",
    )
    validate_parser.add_argument(
        "--document",
        type=Path,
        required=True,
        help="YAML document to validate.",
    )
    validate_parser.add_argument(
        "--schema",
        type=Path,
        required=True,
        help="JSON Schema expressed as YAML.",
    )

    repository_parser = subcommands.add_parser(
        "validate-repository",
        help="Validate the catalogue, package metadata, and package layout.",
    )
    repository_parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path("."),
        help="Repository root to validate (default: current directory).",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "validate-repository":
        errors = validate_repository(args.repository_root)
        if errors:
            print("Repository validation failed:", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
            return 1

        print(f"Repository validation passed: {args.repository_root.resolve()}")
        return 0

    if args.command == "validate":
        try:
            errors = validate_document(args.document, args.schema)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2

        if errors:
            print(f"Validation failed: {args.document}", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
            return 1

        print(f"Validation passed: {args.document}")
        return 0

    if args.command == "discover":
        config_names = set(args.config_name) if args.config_name else None
        try:
            manifest = discover(args.source, config_names)
            write_manifest(manifest, args.output)
        except (FileExistsError, ValueError, OSError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2

        print(
            f"Created review-only manifest: {args.output} "
            f"({len(manifest['candidates'])} candidate(s))"
        )
        return 0

    parser.error(f"Unsupported command: {args.command}")
    return 2
