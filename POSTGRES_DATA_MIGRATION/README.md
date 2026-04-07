# POSTGRES Data Migration (Command Generator)

목표:
- AS-IS -> TO-BE 데이터 이관용 명령어만 생성
- 오브젝트 변경 없이(`TRUNCATE/DELETE/ALTER/DROP` 생성 금지)
- 모든 접속 정보(IP/PORT/USER)는 **단일 파일**에서 관리

## 1) 단일 설정 파일

파일:
- `config/migration.env`

여기에 모든 공통 정보를 입력합니다.

```bash
ASIS_HOST=172.30.72.162
ASIS_PORT=5432
ASIS_USER=postgres

TOBE_HOST=10.10.11.11
TOBE_PORT=5432
TOBE_USER=postgres

BOOTSTRAP_DB=postgres
DEFAULT_DB_PATTERN=.*
DEFAULT_SCHEMA_PATTERN=.*
```

비밀번호는 `~/.pgpass` 권장:
```bash
chmod 600 ~/.pgpass
```

## 2) 실행 흐름

1. AS-IS 스캔 CSV 생성
2. TO-BE 스캔 CSV 생성
3. 두 CSV 병합 -> `table_mapping.csv`
4. 연결/권한 점검(비파괴)
5. 최종 이관 명령어 생성
6. 생성된 `02_commands_<db>.sh` 실행(실제 적재)

## 3) 스크립트 역할

- `scripts/pg_db_schema_table_mapping.sh`
  - DB/Schema/Table 목록 추출
  - `source_db,source_schema,source_table` CSV 출력 가능
- `run_merge_mapping.sh`
  - AS-IS/TO-BE 스캔 결과를 병합해 `table_mapping.csv` 생성
- `check_migration_path.sh`
  - 비파괴 사전점검(포트/로그인/source SELECT/target INSERT)
- `run_generate.sh`
  - 최종 `\COPY` 명령 스크립트 생성

보조:
- `run_build_mapping.sh`: 단일 스캔 결과에서 매핑 골격 생성(빠른 시작용)

## 4) 실전 명령 예시

## 4.1 AS-IS 스캔
```bash
bash scripts/pg_db_schema_table_mapping.sh \
  --role asis \
  --dbs cpw_g \
  --mapping-csv ./out/asis_scan.csv
```

## 4.2 TO-BE 스캔
```bash
bash scripts/pg_db_schema_table_mapping.sh \
  --role tobe \
  --dbs cpw_h \
  --mapping-csv ./out/tobe_scan.csv
```

## 4.3 병합해서 최종 매핑 생성
```bash
bash run_merge_mapping.sh \
  ./out/asis_scan.csv \
  ./out/tobe_scan.csv \
  ./out/table_mapping.csv \
  table
```

`join_key`:
- `table` (기본): 테이블명으로 매칭
- `schema_table`: 스키마+테이블로 매칭

## 4.4 사전 점검(비파괴)
```bash
bash check_migration_path.sh ./out/table_mapping.csv
```

## 4.5 명령어 생성(비파괴)
```bash
bash run_generate.sh ./out/table_mapping.csv ./out/migration
```

또는 FK 파일 포함:
```bash
bash run_generate.sh ./out/table_mapping.csv ./out/fk_edges.csv ./out/migration
```

## 4.6 실제 데이터 적재 실행
```bash
bash ./out/migration/02_commands_<target_db>.sh
```

## 5) CSV 형식

## 스캔 CSV
```csv
source_db,source_schema,source_table
cpw_g,cccpw,orders
```

## 최종 매핑 CSV
```csv
source_db,source_schema,source_table,target_db,target_schema,target_table,where_clause
cpw_g,cccpw,orders,cpw_h,cccpw,orders,
```

## 6) 생성 결과물

`out_dir` 아래 생성:
- `00_generation_summary.md`
- `01_fk_order_<target_db>.txt`
- `02_commands_<target_db>.sh`

## 7) 안전 원칙

- 생성 단계는 비파괴(파일 생성만)
- 소스는 읽기: `\COPY (...) TO STDOUT`
- 타깃은 적재: `\COPY ... FROM STDIN`
- 중간 CSV 파일 없이 스트리밍 파이프 사용
