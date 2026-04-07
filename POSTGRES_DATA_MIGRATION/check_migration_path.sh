#!/usr/bin/env bash
set -euo pipefail

# Non-destructive precheck for migration path (VM/DB/table privilege).
# - No DML/DDL executed
# - Reads mapping CSV and validates:
#   1) TCP reachability to source/target host:port
#   2) DB login for source/target
#   3) source table readable (SELECT)
#   4) target table exists + INSERT privilege
#
# Usage:
#   bash check_migration_path.sh <mapping.csv>

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <mapping.csv>"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load_config.sh"

CONFIG_FILE="${MIGRATION_CONFIG:-${ROOT_DIR}/config/migration.env}"
load_migration_config "${CONFIG_FILE}"
require_config_keys ASIS_HOST ASIS_PORT ASIS_USER TOBE_HOST TOBE_PORT TOBE_USER

MAPPING_FILE="$1"
if [[ ! -f "${MAPPING_FILE}" ]]; then
  echo "[ERROR] mapping file not found: ${MAPPING_FILE}"
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "[ERROR] psql command not found in PATH"
  exit 1
fi

has_nc="false"
if command -v nc >/dev/null 2>&1; then
  has_nc="true"
fi

tmp_endpoints="$(mktemp)"
tmp_rows="$(mktemp)"
trap 'rm -f "${tmp_endpoints}" "${tmp_rows}"' EXIT

# Supported CSV format:
# 1) minimal:
#    source_db,source_schema,source_table,target_db,target_schema,target_table[,where_clause]
# 2) full (backward compatibility):
#    source_host,source_port,source_user,source_db,source_schema,source_table,target_host,target_port,target_user,target_db,target_schema,target_table[,where_clause]
awk -F',' \
  -v asis_host="${ASIS_HOST}" -v asis_port="${ASIS_PORT}" -v asis_user="${ASIS_USER}" \
  -v tobe_host="${TOBE_HOST}" -v tobe_port="${TOBE_PORT}" -v tobe_user="${TOBE_USER}" '
NR==1 {
  for (i=1; i<=NF; i++) idx[$i]=i;
  is_full = (("source_host" in idx) && ("target_host" in idx));
  next;
}
NR>1 {
  if (is_full) {
    sh=$idx["source_host"]; sp=$idx["source_port"]; su=$idx["source_user"];
    sd=$idx["source_db"];   ss=$idx["source_schema"]; st=$idx["source_table"];
    th=$idx["target_host"]; tp=$idx["target_port"]; tu=$idx["target_user"];
    td=$idx["target_db"];   ts=$idx["target_schema"]; tt=$idx["target_table"];
  } else {
    sh=asis_host; sp=asis_port; su=asis_user;
    sd=$idx["source_db"]; ss=$idx["source_schema"]; st=$idx["source_table"];
    th=tobe_host; tp=tobe_port; tu=tobe_user;
    td=$idx["target_db"]; ts=$idx["target_schema"]; tt=$idx["target_table"];
  }

  if (sd == "" || ss == "" || st == "" || td == "" || ts == "" || tt == "") {
    next;
  }

  print "S|" sh "|" sp "|" su "|" sd;
  print "T|" th "|" tp "|" tu "|" td;
  print sh "|" sp "|" su "|" sd "|" ss "|" st "|" th "|" tp "|" tu "|" td "|" ts "|" tt;
}' "${MAPPING_FILE}" > "${tmp_rows}"

if [[ ! -s "${tmp_rows}" ]]; then
  echo "[ERROR] mapping file has no data rows: ${MAPPING_FILE}"
  exit 1
fi

sort -u "${tmp_rows}" | awk -F'|' '{print "S|" $1 "|" $2 "|" $3 "|" $4 "|" $5; print "T|" $7 "|" $8 "|" $9 "|" $10}' | sort -u > "${tmp_endpoints}"

fail_count=0

echo "== Endpoint Check =="
while IFS='|' read -r role host port user db; do
  [[ -z "${role}" ]] && continue
  echo "[CHECK] ${role} host=${host} port=${port} db=${db} user=${user}"

  if [[ "${has_nc}" == "true" ]]; then
    if nc -z -w 3 "${host}" "${port}" >/dev/null 2>&1; then
      echo "  [PASS] TCP reachable"
    else
      echo "  [FAIL] TCP unreachable (${host}:${port})"
      fail_count=$((fail_count + 1))
      continue
    fi
  else
    echo "  [SKIP] nc not found; TCP probe skipped"
  fi

  if psql "host=${host} port=${port} dbname=${db} user=${user}" -v ON_ERROR_STOP=1 -At -c "select 1" >/dev/null 2>&1; then
    echo "  [PASS] DB login/query ok"
  else
    echo "  [FAIL] DB login/query failed"
    fail_count=$((fail_count + 1))
  fi
done < "${tmp_endpoints}"

echo
echo "== Table Access Check =="
while IFS='|' read -r sh sp su sd ss st th tp tu td ts tt; do
  echo "[CHECK] ${sd}.${ss}.${st} -> ${td}.${ts}.${tt}"

  src_sql="SELECT 1 FROM \"${ss}\".\"${st}\" LIMIT 1;"
  if psql "host=${sh} port=${sp} dbname=${sd} user=${su}" -v ON_ERROR_STOP=1 -At -c "${src_sql}" >/dev/null 2>&1; then
    echo "  [PASS] source SELECT ok"
  else
    echo "  [FAIL] source SELECT failed"
    fail_count=$((fail_count + 1))
  fi

  tgt_sql="SELECT CASE WHEN to_regclass('\"${ts}\".\"${tt}\"') IS NULL THEN 'NO_TABLE' WHEN has_table_privilege(current_user, '\"${ts}\".\"${tt}\"', 'INSERT') THEN 'OK' ELSE 'NO_INSERT_PRIV' END;"
  tgt_result="$(psql "host=${th} port=${tp} dbname=${td} user=${tu}" -v ON_ERROR_STOP=1 -At -c "${tgt_sql}" 2>/dev/null || true)"
  if [[ "${tgt_result}" == "OK" ]]; then
    echo "  [PASS] target table exists + INSERT privilege"
  elif [[ "${tgt_result}" == "NO_TABLE" ]]; then
    echo "  [FAIL] target table not found"
    fail_count=$((fail_count + 1))
  elif [[ "${tgt_result}" == "NO_INSERT_PRIV" ]]; then
    echo "  [FAIL] target INSERT privilege missing"
    fail_count=$((fail_count + 1))
  else
    echo "  [FAIL] target privilege check failed"
    fail_count=$((fail_count + 1))
  fi
done < "${tmp_rows}"

echo
if [[ "${fail_count}" -eq 0 ]]; then
  echo "[RESULT] PASS: migration path precheck succeeded."
  exit 0
else
  echo "[RESULT] FAIL: ${fail_count} check(s) failed."
  exit 2
fi
