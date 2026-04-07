#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/generated_demo"
CONFIG_FILE="${MIGRATION_CONFIG:-${ROOT_DIR}/config/migration.env}"

mkdir -p "${OUT_DIR}"

python3 "${ROOT_DIR}/scripts/generate_migration_commands.py" \
  --mapping "${ROOT_DIR}/examples/table_mapping.demo.csv" \
  --config "${CONFIG_FILE}" \
  --fk-edges "${ROOT_DIR}/examples/fk_edges.demo.csv" \
  --out-dir "${OUT_DIR}"

echo
echo "[done] generated artifacts:"
ls -1 "${OUT_DIR}"
