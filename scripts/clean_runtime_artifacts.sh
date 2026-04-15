#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

mkdir -p logs state state/reports state/tmp

# Only clear runtime artifacts; keep directories, source, and git metadata intact.
find logs -mindepth 1 -delete 2>/dev/null || true
find state -mindepth 1 -delete 2>/dev/null || true

find . -path './.git' -prune -o -name '.DS_Store' -type f -delete
find . -path './.git' -prune -o -name '__MACOSX' -exec rm -rf {} +
find . -path './.git' -prune -o -type f \( -name '*.bak' -o -name '*.tmp' \) -delete

mkdir -p logs state state/reports state/tmp

printf '%s\n' "Runtime artifacts cleaned."
