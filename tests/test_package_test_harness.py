from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "scripts" / "lib" / "package_test_harness.sh"


def test_harness_is_valid_bash():
    result = subprocess.run(
        ["bash", "-n", str(HARNESS)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr


def test_harness_exposes_interactive_package_test_contract():
    text = HARNESS.read_text(encoding="utf-8")

    assert "brane_package_test_begin()" in text
    assert "brane_package_test_case()" in text
    assert "brane_package_test_finish()" in text

    assert 'package build "$container"' in text
    assert 'package test "$BPT_PACKAGE_NAME" "$BPT_PACKAGE_VERSION"' in text

    assert '[[ -t 0 && -t 1 ]]' in text
    assert 'Type the action you selected' in text
    assert 'Type PASSED or FAILED' in text


def test_harness_requires_coverage_of_declared_actions():
    text = HARNESS.read_text(encoding="utf-8")

    assert "BPT_DECLARED_ACTIONS" in text
    assert "BPT_COMPLETED_ACTIONS" in text
    assert "required action coverage is incomplete" in text
    assert "coverage: PASSED" in text
