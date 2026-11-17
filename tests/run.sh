#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for script in "$root"/scripts/*.sh; do bash -n "$script"; done
if command -v node >/dev/null 2>&1; then node --check "$root/scripts/start-guard.js"; fi
python3 "$root/tests/test_scripts.py"
