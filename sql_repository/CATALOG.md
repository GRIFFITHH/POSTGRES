# SQL Repository Catalog

이 디렉터리는 실행 코드와 분리된 수동/운영 SQL 저장소입니다.

관리 규칙:
- 파일명: `NNN_short_title.sql`
- `NNN`은 3자리 번호(001, 002, ...)
- 각 SQL 상단에 목적/실행 대상/주의사항 주석 필수
- 현재는 저장소 용도이며 코드에서 자동 참조하지 않음

| No | File | Purpose |
|---|---|---|
| 001 | `001_pre_migration_schema_table_audit.sql` | 마이그레이션 전 DB/스키마/테이블/제약조건/인덱스/리스크 점검 |
