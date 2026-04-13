# scripts 사용 가이드

## 대상 스크립트
- `pg_db_schema_overview.sh`
- `pg_migration_validate.sh`

## 목적
이 스크립트는 PostgreSQL 접속 후 아래를 한 번에 확인하기 위한 운영 점검 도구입니다.
- 인스턴스 내 DB 현황
- DB별 스키마 구성 및 용량 요약
- DB별 테이블 현황(사이즈 기준 우선 확인)

초기 진단, 마이그레이션 전 인벤토리 파악, 용량 점검에 적합합니다.

추가로 `pg_migration_validate.sh`는 서로 다른 VM 간 이관 검증(소스/타깃 테이블 row count 비교) 전용입니다.

## 사전 준비
1. `psql` 실행 가능해야 합니다.
2. 조회 권한이 있는 계정으로 접속 정보 설정이 필요합니다.

예시:
```bash
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD='your-password'
```

필요 시 SSL 관련 변수(`PGSSLMODE`)도 같이 설정하세요.

## 사용법
```bash
./pg_db_schema_overview.sh [--bootstrap-db DB] [--db-pattern REGEX] [--tables-limit N] [--all-tables] [--exact-rows] [--exact-rows-timeout-ms N] [-fk]
```

옵션:
- `--bootstrap-db DB`: DB 목록 조회 기준 DB (기본: `postgres`)
- `--db-pattern REGEX`: 조회할 DB 이름 정규식 (기본: `.*`)
- `--tables-limit N`: DB별 테이블 상세 출력 건수 제한 (기본: `100`)
- `--all-tables`: DB별 테이블 상세 전체 출력(대규모 환경에서는 신중히 사용)
- `--exact-rows`: `[3-1]` 섹션에서 실제 `COUNT(*)` 기반 row 수 출력
- `--exact-rows-timeout-ms N`: exact row count용 `statement_timeout` (기본: `5000`)
- `-fk`, `--fk`: FK 관계 상세(`[4] FK Relationship Detail`) 출력
- `-h, --help`: 도움말

## 출력 섹션 설명
스크립트는 DB마다 아래 순서로 출력합니다.

1. `[1] Database Overview`
- DB 이름, 소유자, DB 크기, 활성 연결 수, 트랜잭션/롤백/데드락 요약
- 전체 인스턴스에서 어떤 DB가 큰지/활발한지 빠르게 파악
- 컬럼 해석:
- `database_name`: 데이터베이스 이름
- `owner`: DB 오너 계정
- `db_size`: DB 전체 크기(사람이 읽기 쉬운 단위)
- `active_connections`: 현재 연결 수(`pg_stat_database.numbackends`)
- `xact_commit`, `xact_rollback`: stats reset 이후 누적 트랜잭션 성공/롤백 수
- `deadlocks`: stats reset 이후 누적 데드락 횟수
- `temp_files`: stats reset 이후 임시 파일 생성 누적 수
- `stats_reset`: 해당 통계가 마지막으로 초기화된 시각
- 해석 팁:
- `active_connections`가 `max_connections` 대비 높으면 연결 고갈 위험
- `xact_rollback` 비율이 비정상적으로 높으면 애플리케이션 오류/재시도 패턴 점검 필요
- `deadlocks`가 증가 추세면 락 순서/트랜잭션 범위 점검 필요

2. `[2] Schema Summary`
- 스키마별 테이블 수, 파티션 테이블 수, 뷰 수, 총 relation 용량
- 특정 스키마가 비정상적으로 큰지 확인 가능
- 컬럼 해석:
- `schema_name`: 스키마 이름
- `tables`: 일반 테이블 수(`relkind='r'`)
- `partitioned_tables`: 파티션 부모 테이블 수(`relkind='p'`)
- `views`: 뷰 수(`relkind='v'`)
- `total_relation_size`: 스키마 내 relation(테이블/파티션/머티리얼라이즈드 뷰) 총합 용량
- 해석 팁:
- 특정 스키마의 `total_relation_size` 급증은 데이터 폭증/보관정책 이슈 신호일 수 있음
- `tables` 대비 `partitioned_tables` 비율이 높으면 파티션 유지관리 정책 점검 필요

3. `[3] Table Detail (schema/table/estimated_rows/size)`
- 스키마/테이블/관계 유형/`est_rows`/총 사이즈
- 기본 정렬은 큰 테이블 우선
- 컬럼 해석:
- `schema_name`, `table_name`: 테이블 식별자
- `relation_type`: `table`, `partitioned_table`, `foreign_table`
- `est_rows`: PostgreSQL 통계 기반 추정 행 수(`pg_class.reltuples`)
- `total_size`: 테이블 + 인덱스 + TOAST 포함 총 크기
- 해석 팁:
- `est_rows`는 실시간 정확값이 아님(통계 갱신 시점에 영향)
- `total_size`가 큰 테이블을 우선 분석 대상으로 삼으면 튜닝 효과가 큼
- 큰 `total_size` 대비 작은 `est_rows`는 인덱스 과다/TOAST 비대화 신호일 수 있음

3-1. `[3-1] Exact Row Count` (`--exact-rows` 옵션 사용 시)
- 실제 `COUNT(*)` 기반 row 수
- 기본적으로 local `table/partitioned_table` 대상 (`foreign_table` 제외)
- `--exact-rows-timeout-ms` 기준으로 timeout 제어
- 해석 팁:
- 이관 전/후 row 수 비교의 기준값으로 사용
- `TIMEOUT/ERROR`는 큰 테이블/잠금/권한 이슈 가능성이 있으므로 별도 재시도 필요

4. `[4] FK Relationship Detail` (`-fk` 옵션 사용 시)
- FK 제약명
- source(참조하는) 테이블/컬럼
- target(참조되는) 테이블/컬럼
- `ON UPDATE`, `ON DELETE`
- deferrable/validated 상태
- 컬럼 해석:
- `constraint_name`: FK 제약 이름
- `source_schema`, `source_table`, `source_columns`: 참조를 거는 쪽(자식)
- `target_schema`, `target_table`, `target_columns`: 참조되는 쪽(부모)
- `on_update`, `on_delete`: 참조 무결성 변경/삭제 시 동작 정책
- `is_deferrable`: 트랜잭션 종료 시점 검증 가능 여부
- `initially_deferred`: 기본적으로 지연 검증인지 여부
- `is_validated`: 기존 데이터까지 유효성 검증 완료 여부
- 해석 팁:
- 마이그레이션/대량 적재 전 `is_validated=false` FK 존재 여부 확인 권장
- `ON DELETE CASCADE` 관계가 많으면 삭제 작업 영향 범위 사전 점검 필요

## `est_rows` 해석
- `est_rows`는 정확한 실시간 건수가 아니라 **추정치**입니다.
- PostgreSQL 통계(`pg_class.reltuples`) 기반 값이라 `ANALYZE` 시점에 따라 오차가 있습니다.
- 정확한 건수가 꼭 필요하면 개별 테이블에 `SELECT COUNT(*)`를 실행해야 합니다(비용 큼).

## 사용 예시 (EX)
1. 전체 DB/스키마/테이블 현황 조회
```bash
./pg_db_schema_overview.sh
```

2. 특정 DB 패턴만 조회
```bash
./pg_db_schema_overview.sh --db-pattern '^(app|core).*'
```

3. 테이블 상세를 DB별 상위 100건만 조회
```bash
./pg_db_schema_overview.sh --tables-limit 100
```

4. 기준 DB를 `template1`로 바꿔서 조회
```bash
./pg_db_schema_overview.sh --bootstrap-db template1
```

5. 전체 테이블 출력(주의: 큰 환경에서 느릴 수 있음)
```bash
./pg_db_schema_overview.sh --all-tables
```

6. 특정 패턴 + 결과 파일 저장
```bash
./pg_db_schema_overview.sh --db-pattern '^prod_.*' > prod_db_overview.txt
```

7. 특정 호스트를 일회성으로 지정해서 실행
```bash
PGHOST=10.10.10.20 PGPORT=5432 PGUSER=monitor PGPASSWORD='***' \
./pg_db_schema_overview.sh --db-pattern '^prod_'
```

8. FK 관계 상세까지 같이 조회
```bash
./pg_db_schema_overview.sh -fk
```

9. 이관 검증용: 실제 row 수까지 조회
```bash
./pg_db_schema_overview.sh --db-pattern '^prod_' --tables-limit 200 --exact-rows --exact-rows-timeout-ms 10000
```

## 자주 발생하는 이슈
1. `psql command not found`
- PostgreSQL client 도구 설치 필요

2. `password authentication failed`
- 계정/비밀번호 확인
- `PGUSER`, `PGPASSWORD` 값 확인

3. `permission denied for ...`
- 조회 계정 권한 부족
- `pg_database`, `pg_stat_database`, `pg_stat_activity` 조회 가능한 권한 필요

4. 결과가 너무 많음
- `--db-pattern`으로 대상 축소
- `--tables-limit`으로 테이블 출력 수 제한
- 전체 출력이 필요하면 `--all-tables` 사용
- FK 관계도 필요할 때만 `-fk` 사용

## 운영 안정성 참고
현재 스크립트는 운영 안전성을 위해 다음을 반영했습니다.
- `--db-pattern`은 SQL 리터럴 이스케이프 후 사용(직접 삽입 리스크 완화)
- 기본 테이블 상세 출력은 DB당 100건으로 제한
- 특정 DB 조회 실패 시 전체 중단하지 않고 다음 DB로 진행
- DB 목록 기준 DB를 옵션(`--bootstrap-db`)으로 분리
- `sh`로 실행해도 내부에서 `bash`로 재실행되도록 처리

## 운영 시 주의사항
1. 피크 시간대에는 보수 옵션 사용
- 권장: `--tables-limit 50` 또는 더 작은 값
- `--all-tables`는 비피크 시간대에만 사용

2. `-fk`는 필요할 때만 사용
- FK 상세는 조인/집계가 추가되므로 출력량과 처리시간이 증가할 수 있음

2-1. `--exact-rows`는 검증 시점에만 사용
- `COUNT(*)`는 테이블 스캔 부하가 발생할 수 있으므로 피크 시간대 상시 실행 비권장
- 큰 테이블은 timeout을 늘리거나 대상 범위를 좁혀 단계적으로 수행 권장

3. 통계성 지표 해석 시 `stats_reset` 기준 확인
- `xact_commit`, `deadlocks`, `temp_files`는 재시작/수동 reset 이후 누적값

4. 대규모 인스턴스에서는 대상 DB를 먼저 좁히기
- `--db-pattern '^prod_(core|app)'` 같이 범위를 제한해 점진 점검 권장

5. 출력 파일 저장 시 보안 주의
- 결과에 DB/스키마/테이블 구조 정보가 포함되므로 접근권한 관리 필요

---

## `pg_migration_validate.sh` (이관 검증 전용)

### 기능
- 소스/타깃 DB 접속 후 테이블별 `COUNT(*)` 비교
- 결과를 `MATCH / DIFF / ERROR`로 표시
- 매핑 파일(`AS-IS -> TO-BE`) 사용 가능
- target 옵션을 생략하면 source-only 모드로 소스 row count만 출력

### 사용법
```bash
./pg_migration_validate.sh \
  --source-host HOST [--source-port 5432] [--source-user postgres] --source-db DB --source-pass-env SRC_PW_ENV \
  [--target-host HOST --target-port 5432 --target-user USER --target-db DB --target-pass-env TGT_PW_ENV] \
  [--mapping-file PATH] [--schema-pattern REGEX] [--tables-limit N] [--row-timeout-ms N]
```

### 옵션 해석
- `--mapping-file`: `source_schema,source_table,target_schema,target_table` 형식(CSV/TSV, 헤더 허용)
- `--schema-pattern`: mapping 파일이 없을 때 동일 스키마/테이블명 교집합 자동 비교 시 필터
- `--tables-limit`: 비교 테이블 수 제한
- `--row-timeout-ms`: `COUNT(*)` timeout (기본 10000ms)
- `--source-port` 기본값: `5432`
- `--source-user` 기본값: `postgres`
- target 옵션을 일부만 넣으면 에러, 전부 넣으면 compare 모드, 전부 생략하면 source-only 모드

### 매핑 파일 예시
```csv
source_schema,source_table,target_schema,target_table
old_sales,order_header,new_sales,order_header
old_sales,order_item,new_sales,order_item
```

### 실행 예시
1. 동일 이름 테이블 자동 매칭 비교
```bash
export SRC_PW='source-password'
export TGT_PW='target-password'

./pg_migration_validate.sh \
  --source-host 10.1.1.10 --source-port 5432 --source-user old_user --source-db old_db --source-pass-env SRC_PW \
  --target-host 10.2.2.20 --target-port 5432 --target-user new_user --target-db new_db --target-pass-env TGT_PW \
  --schema-pattern '^public$' --tables-limit 200
```

2. AS-IS/TO-BE 매핑 파일 기반 비교
```bash
./pg_migration_validate.sh \
  --source-host 10.1.1.10 --source-port 5432 --source-user old_user --source-db old_db --source-pass-env SRC_PW \
  --target-host 10.2.2.20 --target-port 5432 --target-user new_user --target-db new_db --target-pass-env TGT_PW \
  --mapping-file ./table_mapping.csv \
  --row-timeout-ms 30000
```

3. source-only 모드(타깃 미입력)
```bash
./pg_migration_validate.sh \
  --source-host 10.1.1.10 --source-port 5432 --source-user old_user --source-db old_db --source-pass-env SRC_PW \
  --schema-pattern '^public$' --tables-limit 200
```

### 결과 해석
- `MATCH`: source row 수 = target row 수
- `DIFF`: row 수 다름 (이관 누락/중복 가능성 점검 필요)
- `ERROR`: timeout/권한/락 등으로 count 실패

### 운영 주의
- `COUNT(*)`는 테이블 스캔 부하가 큼. 피크 시간대 실행 비권장
- 대용량 테이블은 timeout 확대 또는 `--tables-limit`로 분할 실행 권장
