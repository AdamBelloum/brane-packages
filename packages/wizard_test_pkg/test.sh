#!/usr/bin/env bash
set -euo pipefail

test -f container.yml
test -f hello_world.sh
grep -qx 'name: wizard_test_pkg' container.yml

echo "Package structure checks passed."
