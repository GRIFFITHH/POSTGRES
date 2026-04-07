#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <asis_scan.csv> <tobe_scan.csv> <out_mapping.csv> [join_key]"
  echo "join_key: table | schema_table (default: table)"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASIS_SCAN="$1"
TOBE_SCAN="$2"
OUT_MAPPING="$3"
JOIN_KEY="${4:-table}"

python3 "${ROOT_DIR}/scripts/merge_scan_results.py" \
  --asis "${ASIS_SCAN}" \
  --tobe "${TOBE_SCAN}" \
  --output "${OUT_MAPPING}" \
  --join-key "${JOIN_KEY}" \
  --unmatched-asis "${ROOT_DIR}/out/unmatched_asis.csv" \
  --unmatched-tobe "${ROOT_DIR}/out/unmatched_tobe.csv"
