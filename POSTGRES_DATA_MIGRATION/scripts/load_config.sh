#!/usr/bin/env bash
set -euo pipefail

load_migration_config() {
  local config_file="$1"
  if [[ ! -f "${config_file}" ]]; then
    echo "[ERROR] config file not found: ${config_file}" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "${config_file}"
}

require_config_keys() {
  local missing=0
  for key in "$@"; do
    if [[ -z "${!key:-}" ]]; then
      echo "[ERROR] config key is required but empty: ${key}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    return 1
  fi
}
