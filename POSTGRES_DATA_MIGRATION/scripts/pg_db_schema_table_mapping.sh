#!/usr/bin/env bash

# If invoked with `sh script.sh`, re-exec with bash for bash-specific syntax.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pg_db_schema_table_mapping.sh --role asis|tobe [--bootstrap-db DB] [--dbs DB1,DB2,...] [--db-pattern REGEX] [--schema-pattern REGEX] [--mapping-csv FILE] [--full-csv FILE]

Description:
  - PostgreSQL 인스턴스의 DB/Schema/Table 목록을 깔끔하게 조회
  - migration 입력용 최소 CSV(source_db,source_schema,source_table) 생성 가능

Options:
  --role ROLE            접속 대상 역할(as-is/tobe): asis | tobe
  --config FILE          migration env 파일 경로 (기본: ./config/migration.env)
  --bootstrap-db DB      DB 목록 조회 기준 DB (기본: postgres)
  --dbs LIST             조회할 DB 이름 목록(쉼표 구분). 예: cpw_g,cpw_h
  --db-pattern REGEX     조회할 DB 이름 정규식 (기본: .* )
  --schema-pattern REGEX 조회할 schema 이름 정규식 (기본: .* )
  --mapping-csv FILE     최소 매핑 CSV 출력 경로
  --full-csv FILE        상세 CSV 출력 경로
  -h, --help             도움말

Connection:
  psql 기본 연결 설정 사용.
  필요 시 환경변수 사용: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGSSLMODE
EOF
}

BOOTSTRAP_DB='postgres'
DBS_LIST=''
DB_PATTERN='.*'
SCHEMA_PATTERN='.*'
ROLE=''
CONFIG_FILE=''
MAPPING_CSV=''
FULL_CSV=''

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/load_config.sh"
CONFIG_FILE_DEFAULT="${MIGRATION_CONFIG:-${ROOT_DIR}/config/migration.env}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      ROLE="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --bootstrap-db)
      BOOTSTRAP_DB="${2:-}"
      shift 2
      ;;
    --db-pattern)
      DB_PATTERN="${2:-}"
      shift 2
      ;;
    --dbs)
      DBS_LIST="${2:-}"
      shift 2
      ;;
    --schema-pattern)
      SCHEMA_PATTERN="${2:-}"
      shift 2
      ;;
    --mapping-csv)
      MAPPING_CSV="${2:-}"
      shift 2
      ;;
    --full-csv)
      FULL_CSV="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="${CONFIG_FILE_DEFAULT}"
fi
load_migration_config "${CONFIG_FILE}"
require_config_keys ASIS_HOST ASIS_PORT ASIS_USER TOBE_HOST TOBE_PORT TOBE_USER
if [[ "${DB_PATTERN}" == ".*" && -n "${DEFAULT_DB_PATTERN:-}" ]]; then
  DB_PATTERN="${DEFAULT_DB_PATTERN}"
fi
if [[ "${SCHEMA_PATTERN}" == ".*" && -n "${DEFAULT_SCHEMA_PATTERN:-}" ]]; then
  SCHEMA_PATTERN="${DEFAULT_SCHEMA_PATTERN}"
fi

if [[ -z "${ROLE}" ]]; then
  echo "--role is required: asis | tobe" >&2
  exit 1
fi

case "${ROLE}" in
  asis)
    export PGHOST="${ASIS_HOST}" PGPORT="${ASIS_PORT}" PGUSER="${ASIS_USER}"
    ;;
  tobe)
    export PGHOST="${TOBE_HOST}" PGPORT="${TOBE_PORT}" PGUSER="${TOBE_USER}"
    ;;
  *)
    echo "invalid --role: ${ROLE}. expected: asis | tobe" >&2
    exit 1
    ;;
esac

if ! command -v psql >/dev/null 2>&1; then
  echo "psql command not found" >&2
  exit 1
fi

if [[ -z "$BOOTSTRAP_DB" ]]; then
  echo "--bootstrap-db must not be empty" >&2
  exit 1
fi

# Escape single quote for safe SQL string literal embedding.
DB_PATTERN_SQL=${DB_PATTERN//\'/\'\'}
SCHEMA_PATTERN_SQL=${SCHEMA_PATTERN//\'/\'\'}

db_filter_sql="AND d.datname ~ '${DB_PATTERN_SQL}'"
if [[ -n "${DBS_LIST}" ]]; then
  IFS=',' read -r -a db_items <<< "${DBS_LIST}"
  in_list=''
  for raw in "${db_items[@]}"; do
    db="$(echo "${raw}" | xargs)"
    [[ -z "${db}" ]] && continue
    db_esc=${db//\'/\'\'}
    if [[ -n "${in_list}" ]]; then
      in_list="${in_list}, "
    fi
    in_list="${in_list}'${db_esc}'"
  done
  if [[ -z "${in_list}" ]]; then
    echo "[ERROR] --dbs is empty after parsing" >&2
    exit 1
  fi
  db_filter_sql="AND d.datname IN (${in_list})"
fi

run_psql_tsv() {
  local db="$1"
  local sql="$2"
  PGDATABASE="$db" psql -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' -c "$sql"
}

db_list_sql="
SELECT d.datname
FROM pg_database d
WHERE d.datallowconn = true
  AND d.datistemplate = false
  ${db_filter_sql}
ORDER BY d.datname;
"

mapfile -t DBS < <(run_psql_tsv "$BOOTSTRAP_DB" "$db_list_sql")
if [[ ${#DBS[@]} -eq 0 ]]; then
  echo "No databases matched pattern: ${DB_PATTERN}"
  exit 0
fi

tmp_rows="$(mktemp)"
trap 'rm -f "${tmp_rows}"' EXIT

echo "== PostgreSQL DB-Schema-Table Mapping =="
echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Role: ${ROLE}"
echo "PGHOST: ${PGHOST}"
echo "PGPORT: ${PGPORT}"
echo "PGUSER: ${PGUSER}"
echo "Bootstrap DB: ${BOOTSTRAP_DB}"
if [[ -n "${DBS_LIST}" ]]; then
  echo "DB List: ${DBS_LIST}"
else
  echo "DB Pattern: ${DB_PATTERN}"
fi
echo "Schema Pattern: ${SCHEMA_PATTERN}"
echo

for db in "${DBS[@]}"; do
  sql="
  SELECT
    current_database() AS source_db,
    n.nspname AS source_schema,
    c.relname AS source_table,
    CASE c.relkind
      WHEN 'r' THEN 'table'
      WHEN 'p' THEN 'partitioned_table'
      WHEN 'f' THEN 'foreign_table'
      ELSE c.relkind::text
    END AS relation_type,
    c.reltuples::bigint AS est_rows,
    pg_total_relation_size(c.oid)::bigint AS total_size_bytes
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'f')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    AND n.nspname ~ '${SCHEMA_PATTERN_SQL}'
  ORDER BY n.nspname, c.relname;
  "

  if ! rows="$(run_psql_tsv "$db" "$sql" 2>/dev/null)"; then
    echo "[WARN] failed to query DB=${db}. skip..." >&2
    continue
  fi

  if [[ -z "${rows}" ]]; then
    continue
  fi

  printf '%s\n' "${rows}" >> "${tmp_rows}"
done

if [[ ! -s "${tmp_rows}" ]]; then
  echo "No table rows found for given filters."
  exit 0
fi

echo "[1] Summary by DB"
awk -F'\t' '
{ c[$1]++ }
END {
  printf "%-32s %10s\n", "database", "tables";
  printf "%-32s %10s\n", "--------------------------------", "----------";
  for (db in c) printf "%-32s %10d\n", db, c[db];
}
' "${tmp_rows}" | sort

echo
echo "[2] DB-Schema-Table Detail"
awk -F'\t' '
BEGIN{
  printf "%-24s %-24s %-40s %-18s %12s %14s\n", "source_db", "source_schema", "source_table", "relation_type", "est_rows", "size_bytes";
  printf "%-24s %-24s %-40s %-18s %12s %14s\n", "------------------------", "------------------------", "----------------------------------------", "------------------", "------------", "--------------";
}
{
  printf "%-24s %-24s %-40s %-18s %12s %14s\n", $1, $2, $3, $4, $5, $6;
}
' "${tmp_rows}" | sort

if [[ -n "${MAPPING_CSV}" ]]; then
  mkdir -p "$(dirname "${MAPPING_CSV}")"
  {
    echo "source_db,source_schema,source_table"
    awk -F'\t' '{print $1 "," $2 "," $3}' "${tmp_rows}" | sort -u
  } > "${MAPPING_CSV}"
  echo
  echo "[3] mapping csv written: ${MAPPING_CSV}"
fi

if [[ -n "${FULL_CSV}" ]]; then
  mkdir -p "$(dirname "${FULL_CSV}")"
  {
    echo "source_db,source_schema,source_table,relation_type,est_rows,total_size_bytes"
    awk -F'\t' '{print $1 "," $2 "," $3 "," $4 "," $5 "," $6}' "${tmp_rows}" | sort -u
  } > "${FULL_CSV}"
  echo "[4] full csv written: ${FULL_CSV}"
fi
