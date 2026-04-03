#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pg_db_schema_overview.sh [--bootstrap-db DB] [--db-pattern REGEX] [--tables-limit N] [--all-tables]

Description:
  - PostgreSQL 인스턴스의 DB 현황을 조회
  - 각 DB별 스키마 요약 및 테이블 현황 조회

Options:
  --bootstrap-db DB     DB 목록을 읽어올 기준 DB (기본: postgres)
  --db-pattern REGEX   조회할 DB 이름 정규식 (기본: .* )
  --tables-limit N     DB별 테이블 상세 출력 건수 제한 (기본: 100)
  --all-tables         DB별 테이블 상세 전체 출력 (주의: 대형 환경에서 느릴 수 있음)
  -h, --help           도움말

Connection:
  psql 기본 연결 설정을 사용합니다.
  필요 시 환경변수 사용: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGSSLMODE
EOF
}

BOOTSTRAP_DB='postgres'
DB_PATTERN='.*'
TABLES_LIMIT='100'
SHOW_ALL_TABLES='0'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-db)
      BOOTSTRAP_DB="${2:-}"
      shift 2
      ;;
    --db-pattern)
      DB_PATTERN="${2:-}"
      shift 2
      ;;
    --tables-limit)
      TABLES_LIMIT="${2:-}"
      shift 2
      ;;
    --all-tables)
      SHOW_ALL_TABLES='1'
      shift
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

if ! command -v psql >/dev/null 2>&1; then
  echo "psql command not found" >&2
  exit 1
fi

if ! [[ "$TABLES_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "--tables-limit must be a non-negative integer" >&2
  exit 1
fi

if [[ -z "$BOOTSTRAP_DB" ]]; then
  echo "--bootstrap-db must not be empty" >&2
  exit 1
fi

if [[ "$SHOW_ALL_TABLES" == "0" && "$TABLES_LIMIT" == "0" ]]; then
  echo "--tables-limit 0 is too broad by default. use --all-tables for full output" >&2
  exit 1
fi

run_psql() {
  local db="$1"
  local sql="$2"
  shift 2
  PGDATABASE="$db" psql -X -v ON_ERROR_STOP=1 -P pager=off "$@" -c "$sql"
}

run_psql_tsv() {
  local db="$1"
  local sql="$2"
  shift 2
  PGDATABASE="$db" psql -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' "$@" -c "$sql"
}

echo "== PostgreSQL DB/Schema/Table Overview =="
echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Bootstrap DB: ${BOOTSTRAP_DB}"
echo

echo "[1] Database Overview"
run_psql "$BOOTSTRAP_DB" "
SELECT
  d.datname AS database_name,
  pg_get_userbyid(d.datdba) AS owner,
  pg_size_pretty(pg_database_size(d.datname)) AS db_size,
  COALESCE(s.numbackends, 0) AS active_connections,
  COALESCE(s.xact_commit, 0) AS xact_commit,
  COALESCE(s.xact_rollback, 0) AS xact_rollback,
  COALESCE(s.deadlocks, 0) AS deadlocks,
  COALESCE(s.temp_files, 0) AS temp_files,
  s.stats_reset
FROM pg_database d
LEFT JOIN pg_stat_database s ON s.datid = d.oid
WHERE d.datallowconn = true
  AND d.datistemplate = false
  AND d.datname ~ :'db_pattern'
ORDER BY pg_database_size(d.datname) DESC;
" -v db_pattern="$DB_PATTERN"

db_list_sql="
SELECT d.datname
FROM pg_database d
WHERE d.datallowconn = true
  AND d.datistemplate = false
  AND d.datname ~ :'db_pattern'
ORDER BY d.datname;
"

mapfile -t DBS < <(run_psql_tsv "$BOOTSTRAP_DB" "$db_list_sql" -v db_pattern="$DB_PATTERN")

if [[ ${#DBS[@]} -eq 0 ]]; then
  echo "No databases matched pattern: ${DB_PATTERN}"
  exit 0
fi

for db in "${DBS[@]}"; do
  echo
  echo "============================================================"
  echo "[DB] ${db}"
  echo "============================================================"

  echo
  echo "[2] Schema Summary"
  if ! run_psql "$db" "
  SELECT
    n.nspname AS schema_name,
    COUNT(*) FILTER (WHERE c.relkind = 'r')::int AS tables,
    COUNT(*) FILTER (WHERE c.relkind = 'p')::int AS partitioned_tables,
    COUNT(*) FILTER (WHERE c.relkind = 'v')::int AS views,
    pg_size_pretty(COALESCE(SUM(
      CASE WHEN c.relkind IN ('r','p','m') THEN pg_total_relation_size(c.oid) ELSE 0 END
    ), 0)) AS total_relation_size
  FROM pg_namespace n
  LEFT JOIN pg_class c ON c.relnamespace = n.oid
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
  GROUP BY n.nspname
  ORDER BY n.nspname;
  "; then
    echo "[WARN] failed schema summary for DB=${db}. continue..." >&2
    continue
  fi

  echo
  echo "[3] Table Detail (schema/table/estimated_rows/size)"

  limit_clause=''
  if [[ "$SHOW_ALL_TABLES" != "1" ]]; then
    limit_clause="LIMIT ${TABLES_LIMIT}"
  fi

  if ! run_psql "$db" "
  SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    CASE c.relkind
      WHEN 'r' THEN 'table'
      WHEN 'p' THEN 'partitioned_table'
      WHEN 'f' THEN 'foreign_table'
      ELSE c.relkind::text
    END AS relation_type,
    c.reltuples::bigint AS est_rows,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'f')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
  ORDER BY pg_total_relation_size(c.oid) DESC, n.nspname, c.relname
  ${limit_clause};
  "; then
    echo "[WARN] failed table detail for DB=${db}. continue..." >&2
    continue
  fi
done
