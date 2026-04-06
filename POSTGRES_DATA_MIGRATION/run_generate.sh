#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <mapping.csv> [fk_edges.csv] [out_dir]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPPING_FILE="$1"
FK_FILE="${2:-}"
OUT_DIR="${3:-${ROOT_DIR}/generated}"

mkdir -p "${OUT_DIR}"

if [[ -n "${FK_FILE}" ]]; then
  python3 "${ROOT_DIR}/scripts/generate_migration_commands.py" \
    --mapping "${MAPPING_FILE}" \
    --fk-edges "${FK_FILE}" \
    --out-dir "${OUT_DIR}"
else
  python3 "${ROOT_DIR}/scripts/generate_migration_commands.py" \
    --mapping "${MAPPING_FILE}" \
    --out-dir "${OUT_DIR}"
fi

echo
echo "[done] generated artifacts:"
ls -1 "${OUT_DIR}"
