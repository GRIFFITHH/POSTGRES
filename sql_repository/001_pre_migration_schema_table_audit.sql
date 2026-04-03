/*
No: 001
Title: Pre-migration schema/table audit
Purpose:
  - PostgreSQL 접속 후 현재 클러스터/DB의 마이그레이션 사전 점검 정보를 수집
Scope:
  - DB 목록, 스키마/테이블/컬럼, PK/FK, 인덱스, 시퀀스, 트리거, 확장, 파티션, 리스크 포인트
How to run:
  - psql로 대상 DB에 접속 후 순차 실행
  - 일부 쿼리는 "현재 접속 DB" 기준
Notes:
  - 현재 파일은 저장소 용도이며 애플리케이션 코드와 연결되어 있지 않음
*/

-- 1) Cluster-level: 데이터베이스 목록/상태 (접속 DB와 무관)
SELECT
    datname AS database_name,
    pg_get_userbyid(datdba) AS owner,
    pg_encoding_to_char(encoding) AS encoding,
    datcollate,
    datctype,
    datistemplate,
    datallowconn,
    datconnlimit,
    pg_size_pretty(pg_database_size(datname)) AS database_size
FROM pg_database
WHERE datistemplate = false
ORDER BY datname;

-- 2) 현재 접속 DB: 스키마 목록
SELECT
    n.nspname AS schema_name,
    pg_get_userbyid(n.nspowner) AS owner
FROM pg_namespace n
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY n.nspname;

-- 3) 현재 접속 DB: 테이블/파티션/추정행수/사이즈
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relkind,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned_table'
        WHEN 'f' THEN 'foreign_table'
        ELSE c.relkind::text
    END AS relation_type,
    c.reltuples::bigint AS est_rows,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    pg_size_pretty(pg_relation_size(c.oid)) AS table_size,
    pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid)) AS index_toast_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'f')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY pg_total_relation_size(c.oid) DESC;

-- 4) 현재 접속 DB: 컬럼 상세(타입/NULL/default/identity/generated)
SELECT
    c.table_schema,
    c.table_name,
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.udt_name,
    c.character_maximum_length,
    c.numeric_precision,
    c.numeric_scale,
    c.is_nullable,
    c.column_default,
    c.is_identity,
    c.identity_generation,
    c.is_generated,
    c.generation_expression
FROM information_schema.columns c
WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY c.table_schema, c.table_name, c.ordinal_position;

-- 5) 현재 접속 DB: PK/FK/UNIQUE/CHECK 제약조건 현황
SELECT
    tc.table_schema,
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type,
    string_agg(kcu.column_name, ', ' ORDER BY kcu.ordinal_position) AS columns
FROM information_schema.table_constraints tc
LEFT JOIN information_schema.key_column_usage kcu
       ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
      AND tc.table_name = kcu.table_name
WHERE tc.table_schema NOT IN ('pg_catalog', 'information_schema')
GROUP BY tc.table_schema, tc.table_name, tc.constraint_name, tc.constraint_type
ORDER BY tc.table_schema, tc.table_name, tc.constraint_type, tc.constraint_name;

-- 6) 현재 접속 DB: FK 상세(참조 대상/삭제규칙/업데이트규칙)
SELECT
    tc.table_schema,
    tc.table_name,
    tc.constraint_name,
    ccu.table_schema AS foreign_table_schema,
    ccu.table_name AS foreign_table_name,
    rc.update_rule,
    rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.referential_constraints rc
  ON tc.constraint_name = rc.constraint_name
 AND tc.constraint_schema = rc.constraint_schema
JOIN information_schema.constraint_column_usage ccu
  ON rc.unique_constraint_name = ccu.constraint_name
 AND rc.unique_constraint_schema = ccu.constraint_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY tc.table_schema, tc.table_name, tc.constraint_name;

-- 7) 현재 접속 DB: 인덱스 목록/정의/유효성
SELECT
    ns.nspname AS schema_name,
    tbl.relname AS table_name,
    idx.relname AS index_name,
    i.indisprimary,
    i.indisunique,
    i.indisvalid,
    i.indisready,
    pg_get_indexdef(i.indexrelid) AS index_def
FROM pg_index i
JOIN pg_class idx ON idx.oid = i.indexrelid
JOIN pg_class tbl ON tbl.oid = i.indrelid
JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
WHERE ns.nspname NOT IN ('pg_catalog', 'information_schema')
  AND ns.nspname NOT LIKE 'pg_toast%'
ORDER BY ns.nspname, tbl.relname, idx.relname;

-- 8) 현재 접속 DB: PK 없는 일반 테이블(마이그레이션 리스크)
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_constraint con
       ON con.conrelid = c.oid
      AND con.contype = 'p'
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND con.oid IS NULL
ORDER BY n.nspname, c.relname;

-- 9) 현재 접속 DB: 검증되지 않은 제약조건(마이그레이션 전 처리 필요 가능)
SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    con.conname AS constraint_name,
    con.contype,
    con.convalidated
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND con.convalidated = false
ORDER BY n.nspname, c.relname, con.conname;

-- 10) 현재 접속 DB: 시퀀스 상태
SELECT
    sequence_schema,
    sequence_name,
    data_type,
    start_value,
    minimum_value,
    maximum_value,
    increment,
    cycle_option
FROM information_schema.sequences
WHERE sequence_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY sequence_schema, sequence_name;

-- 11) 현재 접속 DB: 트리거 목록
SELECT
    event_object_schema AS schema_name,
    event_object_table AS table_name,
    trigger_name,
    action_timing,
    event_manipulation,
    action_statement
FROM information_schema.triggers
WHERE event_object_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY event_object_schema, event_object_table, trigger_name;

-- 12) 현재 접속 DB: 확장 목록(버전 의존성 확인)
SELECT
    e.extname,
    e.extversion,
    n.nspname AS schema_name
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;

-- 13) 현재 접속 DB: 파티션 트리(있다면)
SELECT
    ns.nspname AS schema_name,
    parent.relname AS parent_table,
    child.relname AS partition_table
FROM pg_inherits i
JOIN pg_class parent ON parent.oid = i.inhparent
JOIN pg_class child ON child.oid = i.inhrelid
JOIN pg_namespace ns ON ns.oid = parent.relnamespace
WHERE ns.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY ns.nspname, parent.relname, child.relname;

-- 14) 현재 접속 DB: 장기 트랜잭션(운영 부하/락 리스크)
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    now() - xact_start AS xact_age,
    wait_event_type,
    wait_event,
    left(query, 200) AS query_sample
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND pid <> pg_backend_pid()
ORDER BY xact_start ASC
LIMIT 50;

-- 15) 현재 접속 DB: 락 대기 체인 요약
SELECT
    a.pid AS waiting_pid,
    a.usename AS waiting_user,
    a.wait_event_type,
    a.wait_event,
    left(a.query, 120) AS waiting_query,
    l.locktype,
    l.mode,
    l.relation::regclass AS relation_name
FROM pg_stat_activity a
JOIN pg_locks l ON l.pid = a.pid
WHERE NOT l.granted
ORDER BY a.pid;

-- 16) 현재 접속 DB: Vacuum/Analyze 관리 지표(미수행 테이블 탐지)
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC, n_live_tup DESC;
