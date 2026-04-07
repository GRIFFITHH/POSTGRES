#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <db_schema_table.csv> <out_mapping.csv> [target_mode]"
  echo "target_mode: same | empty"
  echo "example:"
  echo "  bash $0 tables.csv table_mapping.csv empty"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT_FILE="$1"
OUT_FILE="$2"
TARGET_MODE="${3:-empty}"

python3 "${ROOT_DIR}/scripts/build_mapping_csv.py" \
  --input "${INPUT_FILE}" \
  --output "${OUT_FILE}" \
  --target-db-mode "${TARGET_MODE}" \
  --target-schema-mode "${TARGET_MODE}" \
  --target-table-mode "${TARGET_MODE}"
