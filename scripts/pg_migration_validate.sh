#!/usr/bin/env bash

# Re-exec with bash when invoked via sh.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  pg_migration_validate.sh \
    --source-host HOST --source-port PORT --source-user USER --source-db DB --source-pass-env ENV \
    [--target-host HOST --target-port PORT --target-user USER --target-db DB --target-pass-env ENV] \
    [--mapping-file PATH] [--schema-pattern REGEX] [--tables-limit N] [--row-timeout-ms N]

Description:
  - Migration validation focused on table row-count comparison.
  - Prints source/target row counts per table and MATCH/DIFF status.
  - If target options are omitted, runs in source-only mode (source table row counts only).

Options:
  --source-host HOST         Source PostgreSQL host
  --source-port PORT         Source PostgreSQL port (default: 5432)
  --source-user USER         Source PostgreSQL user (default: postgres)
  --source-db DB             Source database
  --source-pass-env ENV      Environment variable name for source password

  --target-host HOST         Target PostgreSQL host (optional, compare mode)
  --target-port PORT         Target PostgreSQL port (optional, compare mode)
  --target-user USER         Target PostgreSQL user (optional, compare mode)
  --target-db DB             Target database (optional, compare mode)
  --target-pass-env ENV      Environment variable name for target password (optional, compare mode)

  --mapping-file PATH        TSV/CSV mapping file:
                             source_schema,source_table,target_schema,target_table
                             (header allowed, source-only mode can use first 2 columns only)
  --schema-pattern REGEX     Table schema regex filter when mapping-file is absent (default: .* )
  --tables-limit N           Limit number of compared table pairs (default: 0 = all)
  --row-timeout-ms N         statement_timeout for COUNT(*) (default: 10000)
  -h, --help                 Show help

Examples:
  pg_migration_validate.sh \
    --source-host 10.0.0.10 --source-port 5432 --source-user old_user --source-db old_db --source-pass-env SRC_PW \
    --target-host 10.0.1.20 --target-port 5432 --target-user new_user --target-db new_db --target-pass-env TGT_PW

  pg_migration_validate.sh ... --mapping-file ./table_mapping.csv --row-timeout-ms 30000

  pg_migration_validate.sh \
    --source-host 10.0.0.10 --source-port 5432 --source-user old_user --source-db old_db --source-pass-env SRC_PW \
    --schema-pattern '^public$'
EOF
}

SOURCE_HOST=''
SOURCE_PORT='5432'
SOURCE_USER='postgres'
SOURCE_DB=''
SOURCE_PASS_ENV=''

TARGET_HOST=''
TARGET_PORT='5432'
TARGET_USER=''
TARGET_DB=''
TARGET_PASS_ENV=''

MAPPING_FILE=''
SCHEMA_PATTERN='.*'
TABLES_LIMIT='0'
ROW_TIMEOUT_MS='10000'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-host) SOURCE_HOST="${2:-}"; shift 2 ;;
    --source-port) SOURCE_PORT="${2:-}"; shift 2 ;;
    --source-user) SOURCE_USER="${2:-}"; shift 2 ;;
    --source-db) SOURCE_DB="${2:-}"; shift 2 ;;
    --source-pass-env) SOURCE_PASS_ENV="${2:-}"; shift 2 ;;

    --target-host) TARGET_HOST="${2:-}"; shift 2 ;;
    --target-port) TARGET_PORT="${2:-}"; shift 2 ;;
    --target-user) TARGET_USER="${2:-}"; shift 2 ;;
    --target-db) TARGET_DB="${2:-}"; shift 2 ;;
    --target-pass-env) TARGET_PASS_ENV="${2:-}"; shift 2 ;;

    --mapping-file) MAPPING_FILE="${2:-}"; shift 2 ;;
    --schema-pattern) SCHEMA_PATTERN="${2:-}"; shift 2 ;;
    --tables-limit) TABLES_LIMIT="${2:-}"; shift 2 ;;
    --row-timeout-ms) ROW_TIMEOUT_MS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
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

if ! [[ "$ROW_TIMEOUT_MS" =~ ^[0-9]+$ ]]; then
  echo "--row-timeout-ms must be a non-negative integer" >&2
  exit 1
fi

required=(SOURCE_HOST SOURCE_PORT SOURCE_USER SOURCE_DB SOURCE_PASS_ENV TARGET_HOST TARGET_PORT TARGET_USER TARGET_DB TARGET_PASS_ENV)
required=(SOURCE_HOST SOURCE_PORT SOURCE_DB SOURCE_PASS_ENV)
for name in "${required[@]}"; do
  if [[ -z "${!name}" ]]; then
    echo "Missing required option for ${name}" >&2
    usage
    exit 1
  fi
done

TARGET_MODE='source_only'
target_fields=(TARGET_HOST TARGET_PORT TARGET_USER TARGET_DB TARGET_PASS_ENV)
target_filled_count=0
for name in "${target_fields[@]}"; do
  if [[ -n "${!name}" ]]; then
    target_filled_count=$((target_filled_count + 1))
  fi
done

if [[ "$target_filled_count" -gt 0 ]]; then
  if [[ "$target_filled_count" -ne 5 ]]; then
    echo "Target options are partially provided. Provide all target options or none." >&2
    exit 1
  fi
  TARGET_MODE='compare'
fi

if [[ -z "${!SOURCE_PASS_ENV:-}" ]]; then
  echo "Source password env var is empty: ${SOURCE_PASS_ENV}" >&2
  exit 1
fi
if [[ "$TARGET_MODE" == "compare" && -z "${!TARGET_PASS_ENV:-}" ]]; then
  echo "Target password env var is empty: ${TARGET_PASS_ENV}" >&2
  exit 1
fi

quote_ident() {
  local raw="$1"
  local escaped="${raw//\"/\"\"}"
  printf '"%s"' "$escaped"
}

run_source_tsv() {
  local sql="$1"
  PGPASSWORD="${!SOURCE_PASS_ENV}" PGHOST="$SOURCE_HOST" PGPORT="$SOURCE_PORT" PGUSER="$SOURCE_USER" PGDATABASE="$SOURCE_DB" \
    psql -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' -c "$sql"
}

run_target_tsv() {
  local sql="$1"
  PGPASSWORD="${!TARGET_PASS_ENV}" PGHOST="$TARGET_HOST" PGPORT="$TARGET_PORT" PGUSER="$TARGET_USER" PGDATABASE="$TARGET_DB" \
    psql -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' -c "$sql"
}

source_count() {
  local fq_name="$1"
  PGPASSWORD="${!SOURCE_PASS_ENV}" PGHOST="$SOURCE_HOST" PGPORT="$SOURCE_PORT" PGUSER="$SOURCE_USER" PGDATABASE="$SOURCE_DB" \
    PGOPTIONS="-c statement_timeout=${ROW_TIMEOUT_MS}" \
    psql -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' -c "SELECT count(*)::bigint FROM ${fq_name};"
}

target_count() {
  local fq_name="$1"
  PGPASSWORD="${!TARGET_PASS_ENV}" PGHOST="$TARGET_HOST" PGPORT="$TARGET_PORT" PGUSER="$TARGET_USER" PGDATABASE="$TARGET_DB" \
    PGOPTIONS="-c statement_timeout=${ROW_TIMEOUT_MS}" \
    psql -X -v ON_ERROR_STOP=1 -P pager=off -At -F $'\t' -c "SELECT count(*)::bigint FROM ${fq_name};"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
pairs_file="$tmp_dir/pairs.tsv"

if [[ -n "$MAPPING_FILE" ]]; then
  if [[ ! -f "$MAPPING_FILE" ]]; then
    echo "mapping file not found: $MAPPING_FILE" >&2
    exit 1
  fi

  if [[ "$TARGET_MODE" == "compare" ]]; then
    awk -F'[,	]' '
      BEGIN { OFS="\t" }
      NF < 4 { next }
      {
        gsub(/^ +| +$/, "", $1)
        gsub(/^ +| +$/, "", $2)
        gsub(/^ +| +$/, "", $3)
        gsub(/^ +| +$/, "", $4)
        if ($1 == "" || $2 == "" || $3 == "" || $4 == "") next
        h1 = tolower($1); h2 = tolower($2); h3 = tolower($3); h4 = tolower($4)
        if (h1 == "source_schema" && h2 == "source_table" && h3 == "target_schema" && h4 == "target_table") next
        print $1, $2, $3, $4
      }
    ' "$MAPPING_FILE" > "$pairs_file"
  else
    awk -F'[,	]' '
      BEGIN { OFS="\t" }
      NF < 2 { next }
      {
        gsub(/^ +| +$/, "", $1)
        gsub(/^ +| +$/, "", $2)
        if ($1 == "" || $2 == "") next
        h1 = tolower($1); h2 = tolower($2)
        if (h1 == "source_schema" && h2 == "source_table") next
        if (h1 == "source_schema" && h2 == "source_table" && tolower($3) == "target_schema") next
        print $1, $2, "", ""
      }
    ' "$MAPPING_FILE" > "$pairs_file"
  fi
else
  schema_sql_pattern=${SCHEMA_PATTERN//\'/\'\'}

  run_source_tsv "
  SELECT
    n.nspname,
    c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r','p')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND n.nspname NOT LIKE 'pg_toast%'
    AND n.nspname ~ '${schema_sql_pattern}'
  ORDER BY n.nspname, c.relname;
  " | awk -F'\t' 'BEGIN{OFS="\t"} {print $1"."$2, $1, $2}' > "$tmp_dir/src_tables.tsv"

  if [[ "$TARGET_MODE" == "compare" ]]; then
    run_target_tsv "
    SELECT
      n.nspname,
      c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND n.nspname ~ '${schema_sql_pattern}'
    ORDER BY n.nspname, c.relname;
    " | awk -F'\t' 'BEGIN{OFS="\t"} {print $1"."$2, $1, $2}' > "$tmp_dir/tgt_tables.tsv"

    join -t $'\t' -j 1 "$tmp_dir/src_tables.tsv" "$tmp_dir/tgt_tables.tsv" \
      | awk -F'\t' 'BEGIN{OFS="\t"} {print $2, $3, $4, $5}' > "$pairs_file"
  else
    awk -F'\t' 'BEGIN{OFS="\t"} {print $2, $3, "", ""}' "$tmp_dir/src_tables.tsv" > "$pairs_file"
  fi
fi

if [[ ! -s "$pairs_file" ]]; then
  echo "No table pairs to compare" >&2
  exit 1
fi

if [[ "$TABLES_LIMIT" != "0" ]]; then
  head -n "$TABLES_LIMIT" "$pairs_file" > "$tmp_dir/pairs_limited.tsv"
  mv "$tmp_dir/pairs_limited.tsv" "$pairs_file"
fi

echo "== Migration Row Count Validation =="
echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "mode: ${TARGET_MODE}"
echo "Source: ${SOURCE_HOST}:${SOURCE_PORT}/${SOURCE_DB}"
if [[ "$TARGET_MODE" == "compare" ]]; then
  echo "Target: ${TARGET_HOST}:${TARGET_PORT}/${TARGET_DB}"
else
  echo "Target: (none)"
fi
echo "row_timeout_ms: ${ROW_TIMEOUT_MS}"
if [[ -n "$MAPPING_FILE" ]]; then
  echo "mapping_file: ${MAPPING_FILE}"
else
  echo "mapping_file: (none, same schema/table names intersection)"
fi
echo

if [[ "$TARGET_MODE" == "compare" ]]; then
  printf "%-30s %-38s %-30s %-38s %-16s %-16s %-10s\n" \
    "src_schema" "src_table" "tgt_schema" "tgt_table" "src_rows" "tgt_rows" "status"
  printf "%-30s %-38s %-30s %-38s %-16s %-16s %-10s\n" \
    "------------------------------" "--------------------------------------" "------------------------------" "--------------------------------------" "----------------" "----------------" "----------"
else
  printf "%-30s %-38s %-16s %-12s\n" \
    "src_schema" "src_table" "src_rows" "status"
  printf "%-30s %-38s %-16s %-12s\n" \
    "------------------------------" "--------------------------------------" "----------------" "------------"
fi

match_count=0
diff_count=0
error_count=0
total_count=0
source_only_ok_count=0

while IFS=$'\t' read -r src_schema src_table tgt_schema tgt_table; do
  total_count=$((total_count + 1))

  src_fq="$(quote_ident "$src_schema").$(quote_ident "$src_table")"

  src_rows=""

  if ! src_rows=$(source_count "$src_fq" 2>/dev/null); then
    src_rows="TIMEOUT/ERROR"
  else
    src_rows=$(echo "$src_rows" | tr -d '\r\n')
  fi

  if [[ "$TARGET_MODE" == "compare" ]]; then
    tgt_fq="$(quote_ident "$tgt_schema").$(quote_ident "$tgt_table")"
    tgt_rows=""

    if ! tgt_rows=$(target_count "$tgt_fq" 2>/dev/null); then
      tgt_rows="TIMEOUT/ERROR"
    else
      tgt_rows=$(echo "$tgt_rows" | tr -d '\r\n')
    fi

    status=""
    if [[ "$src_rows" == "TIMEOUT/ERROR" || "$tgt_rows" == "TIMEOUT/ERROR" ]]; then
      status="ERROR"
      error_count=$((error_count + 1))
    elif [[ "$src_rows" == "$tgt_rows" ]]; then
      status="MATCH"
      match_count=$((match_count + 1))
    else
      status="DIFF"
      diff_count=$((diff_count + 1))
    fi

    printf "%-30s %-38s %-30s %-38s %-16s %-16s %-10s\n" \
      "$src_schema" "$src_table" "$tgt_schema" "$tgt_table" "$src_rows" "$tgt_rows" "$status"
  else
    if [[ "$src_rows" == "TIMEOUT/ERROR" ]]; then
      status="ERROR"
      error_count=$((error_count + 1))
    else
      status="SOURCE_ONLY"
      source_only_ok_count=$((source_only_ok_count + 1))
    fi

    printf "%-30s %-38s %-16s %-12s\n" \
      "$src_schema" "$src_table" "$src_rows" "$status"
  fi
done < "$pairs_file"

echo
echo "Summary"
echo "- total: ${total_count}"
if [[ "$TARGET_MODE" == "compare" ]]; then
  echo "- match: ${match_count}"
  echo "- diff: ${diff_count}"
else
  echo "- source_only_ok: ${source_only_ok_count}"
fi
echo "- error: ${error_count}"

if [[ "$TARGET_MODE" == "compare" ]]; then
  if [[ "$diff_count" -gt 0 || "$error_count" -gt 0 ]]; then
    exit 2
  fi
else
  if [[ "$error_count" -gt 0 ]]; then
    exit 2
  fi
fi

exit 0
