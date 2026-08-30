import csv
from decimal import Decimal
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "test-fixtures" / "minmax" / "numbers.csv"


def test_minmax_numbers_fixture_has_stable_expected_extremes() -> None:
    with FIXTURE.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    assert [row["label"] for row in rows] == ["alpha", "beta", "gamma", "delta"]

    values = [Decimal(row["value"]) for row in rows]
    assert min(values) == Decimal("-2")
    assert max(values) == Decimal("9.25")
