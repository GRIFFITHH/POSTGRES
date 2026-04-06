# PostgreSQL Data Migration Command Generator

AS-IS -> TO-BE 데이터 이관을 위해, **실행 명령어만 생성**하는 도구입니다.

목적:
- 오브젝트(DB/Schema/Table/Constraint/Index)는 이미 생성된 상태에서
- 테이블 매핑(AS-IS 이름 -> TO-BE 이름)에 따라
- `psql \COPY` 기반 데이터 이관 명령어를 자동 생성
- FK 의존 순서를 반영한 실행 순서 파일 생성

## 1. 안전 원칙

이 프로젝트는 아래 원칙을 전제로 설계되었습니다.

- `TRUNCATE`, `DELETE`, `ALTER`, `DROP` 명령을 생성하지 않음
- Source(AS-IS): `\COPY (...) TO STDOUT`만 사용 (읽기)
- Target(TO-BE): `\COPY ... FROM STDIN`만 사용 (적재)
- 생성기는 DB 변경 작업을 수행하지 않고 파일만 생성

주의:
- 생성된 명령어를 실제 실행하면 Target에는 데이터가 적재됩니다.
- 즉, "생성 단계"는 비파괴지만 "실행 단계"는 적재 작업입니다.

## 2. 디렉터리 구성

- `scripts/generate_migration_commands.py`: 메인 생성기
- `run_generate.sh`: 실사용 입력 파일로 생성 실행
- `run_demo.sh`: 데모 입력으로 생성 실행
- `templates/table_mapping.template.csv`: 매핑 템플릿
- `templates/fk_edges_query.sql`: TO-BE에서 FK 엣지 추출용 읽기 전용 SQL
- `examples/table_mapping.demo.csv`: 데모 매핑
- `examples/fk_edges.demo.csv`: 데모 FK 엣지
- `generated_demo/`: 데모 실행 결과

## 3. 사전 준비

## 필수 도구
- `python3`
- `bash`
- `psql` (명령어 실행 시 필요)

## 인증 정보 관리 권장
비밀번호는 CSV에 넣지 말고 `~/.pgpass` 사용을 권장합니다.

예시:
```text
10.10.1.11:5432:legacy_sales:asis_ro:ASIS_PASSWORD
10.20.2.21:5432:sales_new:tobe_loader:TOBE_PASSWORD
```

권한:
```bash
chmod 600 ~/.pgpass
```

## 4. 입력 파일 정의

## 4.1 매핑 CSV (`table_mapping`)
템플릿 위치:
- `templates/table_mapping.template.csv`

필수 헤더:
```csv
source_host,source_port,source_user,source_db,source_schema,source_table,target_host,target_port,target_user,target_db,target_schema,target_table,where_clause
```

컬럼 설명:
- `source_*`: AS-IS 접속 및 소스 테이블 정보
- `target_*`: TO-BE 접속 및 타깃 테이블 정보
- `where_clause`: 부분 이관 필요 시 조건(없으면 공란)

예시:
```csv
10.10.1.11,5432,asis_ro,legacy_sales,public,customers,10.20.2.21,5432,tobe_loader,sales_new,sales_mig,customer_master,
10.10.1.12,5432,asis_ro,legacy_hr,hr,employees,10.20.2.22,5432,tobe_loader,hr_new,hr_mig,employee_master,active = true
```

## 4.2 FK 엣지 CSV (`fk_edges`, 선택)
FK 순서를 맞추려면 준비 권장.

헤더:
```csv
target_db,child_schema,child_table,parent_schema,parent_table
```

TO-BE DB에서 추출 SQL:
- `templates/fk_edges_query.sql`

예시 실행(단일 DB):
```bash
{
  echo "target_db,child_schema,child_table,parent_schema,parent_table"
  psql "host=<TOBE_HOST> port=5432 dbname=<TOBE_DB> user=<TOBE_USER>" \
    -v ON_ERROR_STOP=1 -At -F, -f templates/fk_edges_query.sql
} > fk_edges_<TOBE_DB>.csv
```

운영에서는 DB별 CSV를 만든 뒤 하나로 합치는 방식이 실용적입니다.

## 5. 명령 생성 방법

## 기본
```bash
bash run_generate.sh <mapping.csv> [fk_edges.csv] [out_dir]
```

예시:
```bash
bash run_generate.sh ./my/table_mapping.csv ./my/fk_edges.csv ./generated_real
```

FK 없이 생성:
```bash
bash run_generate.sh ./my/table_mapping.csv
```

## 직접 python 실행
```bash
python3 scripts/generate_migration_commands.py \
  --mapping ./my/table_mapping.csv \
  --fk-edges ./my/fk_edges.csv \
  --out-dir ./generated_real
```

## 6. 생성 산출물

`out_dir` 기준으로 아래 파일이 생성됩니다.

- `00_generation_summary.md`
  - 입력 파일 경로, DB별 테이블 수, 사이클 여부 요약
- `01_fk_order_<target_db>.txt`
  - FK 기반 권장 실행 순서(부모 -> 자식)
- `02_commands_<target_db>.sh`
  - 실제 `psql \COPY` 파이프 명령 목록

## 명령 형식 예시
```bash
psql "host=10.10.1.11 port=5432 dbname=legacy_sales user=asis_ro" -v ON_ERROR_STOP=1 -c '\COPY (SELECT * FROM "public"."customers") TO STDOUT WITH (FORMAT csv)' | psql "host=10.20.2.21 port=5432 dbname=sales_new user=tobe_loader" -v ON_ERROR_STOP=1 -c '\COPY "sales_mig"."customer_master" FROM STDIN WITH (FORMAT csv)'
```

## 7. 운영 절차 권장

1. TO-BE 오브젝트 상태 재확인 (이미 생성되어 있어야 함)
2. `table_mapping.csv` 작성
3. TO-BE에서 FK 엣지 추출 후 `fk_edges.csv` 준비
4. 명령 생성 (`run_generate.sh`)
5. 생성된 `01_fk_order_*.txt` 순서 검토
6. 생성된 `02_commands_*.sh`를 검증 환경에서 리허설 실행
7. 결과 검증 후 운영 반영

## 8. 제약 및 유의사항

- 컬럼 이름/순서/타입 호환성은 사전에 맞아야 합니다.
- `SELECT *` 기반이므로 소스/타깃 컬럼 순서가 다르면 실패할 수 있습니다.
- FK 순서 파일은 제공된 `fk_edges.csv` 정확도에 의존합니다.
- FK 사이클이 있으면 `00_generation_summary.md` 및 `01_fk_order_*.txt`에 경고 표시됩니다.
- 생성기는 검증 SQL 리포트를 아직 생성하지 않습니다(현재 범위: 명령 생성 전용).

## 9. 데모 실행

```bash
bash run_demo.sh
```

결과 위치:
- `generated_demo/`

## 10. 빠른 경로 안내

- 매핑 템플릿: `templates/table_mapping.template.csv`
- FK 추출 SQL: `templates/fk_edges_query.sql`
- 생성기 실행: `run_generate.sh`
