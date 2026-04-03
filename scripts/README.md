# scripts 사용 가이드

## 대상 스크립트
- `pg_db_schema_overview.sh`

## 목적
이 스크립트는 PostgreSQL 접속 후 아래를 한 번에 확인하기 위한 운영 점검 도구입니다.
- 인스턴스 내 DB 현황
- DB별 스키마 구성 및 용량 요약
- DB별 테이블 현황(사이즈 기준 우선 확인)

초기 진단, 마이그레이션 전 인벤토리 파악, 용량 점검에 적합합니다.

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
./pg_db_schema_overview.sh [--bootstrap-db DB] [--db-pattern REGEX] [--tables-limit N] [--all-tables] [-fk]
```

옵션:
- `--bootstrap-db DB`: DB 목록 조회 기준 DB (기본: `postgres`)
- `--db-pattern REGEX`: 조회할 DB 이름 정규식 (기본: `.*`)
- `--tables-limit N`: DB별 테이블 상세 출력 건수 제한 (기본: `100`)
- `--all-tables`: DB별 테이블 상세 전체 출력(대규모 환경에서는 신중히 사용)
- `-fk`, `--fk`: FK 관계 상세(`[4] FK Relationship Detail`) 출력
- `-h, --help`: 도움말

## 출력 섹션 설명
스크립트는 DB마다 아래 순서로 출력합니다.

1. `[1] Database Overview`
- DB 이름, 소유자, DB 크기, 활성 연결 수, 트랜잭션/롤백/데드락 요약
- 전체 인스턴스에서 어떤 DB가 큰지/활발한지 빠르게 파악

2. `[2] Schema Summary`
- 스키마별 테이블 수, 파티션 테이블 수, 뷰 수, 총 relation 용량
- 특정 스키마가 비정상적으로 큰지 확인 가능

3. `[3] Table Detail (schema/table/estimated_rows/size)`
- 스키마/테이블/관계 유형/`est_rows`/총 사이즈
- 기본 정렬은 큰 테이블 우선

4. `[4] FK Relationship Detail` (`-fk` 옵션 사용 시)
- FK 제약명
- source(참조하는) 테이블/컬럼
- target(참조되는) 테이블/컬럼
- `ON UPDATE`, `ON DELETE`
- deferrable/validated 상태

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
- `--db-pattern`은 `psql` 변수 바인딩으로 처리(직접 문자열 삽입 회피)
- 기본 테이블 상세 출력은 DB당 100건으로 제한
- 특정 DB 조회 실패 시 전체 중단하지 않고 다음 DB로 진행
- DB 목록 기준 DB를 옵션(`--bootstrap-db`)으로 분리
