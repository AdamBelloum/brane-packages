#!/usr/bin/env python3
"""Brane package entry point for column-wise CSV minimum and maximum values."""

import csv
import json
import os
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path


def read_json_environment(name: str) -> str:
    """Returns a JSON-encoded Brane input environment variable as a string."""
    try:
        value = json.loads(os.environ[name])
    except KeyError as error:
        raise RuntimeError(f"Missing required Brane input environment variable: {name}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Brane input {name} is not valid JSON: {error}") from error

    if not isinstance(value, str):
        raise RuntimeError(f"Brane input {name} must resolve to a string")
    return value


def aggregate(csv_path: str, column: str, operation: str) -> Decimal:
    """Computes the requested aggregate over a numeric CSV column."""
    try:
        with open(csv_path, newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)

            if not reader.fieldnames:
                raise RuntimeError("Input CSV has no header row")
            if column not in reader.fieldnames:
                available = ", ".join(reader.fieldnames)
                raise RuntimeError(
                    f"Column {column!r} was not found in the input CSV; "
                    f"available columns: {available}"
                )

            values: list[Decimal] = []
            for row_number, row in enumerate(reader, start=2):
                raw_value = (row.get(column) or "").strip()
                if not raw_value:
                    raise RuntimeError(
                        f"Empty value in column {column!r} at CSV row {row_number}"
                    )
                try:
                    values.append(Decimal(raw_value))
                except InvalidOperation as error:
                    raise RuntimeError(
                        f"Non-numeric value {raw_value!r} in column {column!r} "
                        f"at CSV row {row_number}"
                    ) from error
    except OSError as error:
        raise RuntimeError(f"Cannot read input CSV {csv_path!r}: {error}") from error

    if not values:
        raise RuntimeError(f"Input CSV contains no data rows for column {column!r}")

    return max(values) if operation == "max" else min(values)


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"min", "max"}:
        print(f"Usage: {sys.argv[0]} min|max", file=sys.stderr)
        return 2

    operation = sys.argv[1]
    column = read_json_environment("COLUMN")
    csv_path = read_json_environment("FILE")
    result = aggregate(csv_path, column, operation)

    result_dir = Path("/result")
    result_dir.mkdir(parents=True, exist_ok=True)
    (result_dir / "value.txt").write_text(f"{result}\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"minmax: {error}", file=sys.stderr)
        raise SystemExit(1)
