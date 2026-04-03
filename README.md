# Postgres Monitoring Tool Skeleton

환경이 다른 인프라(OpenStack/AWS/사설망)에서 공통 방식으로 Postgres 지표를 수집하기 위한 뼈대 코드입니다.

## 구조

- `postgres_monitor/core`: 실행 엔진, 모델, inventory 로더, secret resolver
- `postgres_monitor/connectors`: 접속 모듈 (`direct_tcp`, `ssh_bastion_tunnel`)
- `postgres_monitor/collectors`: 상태 점검 모듈 (`HealthCollector`)
- `postgres_monitor/outputs`: 콘솔/JSON 출력
- `postgres_monitor/config`: 샘플 inventory
- `query_store`: 쿼리 집중관리 경로 (`pg_monit`, `pg_pitr`)

## 빠른 시작

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

export PG_SAMPLE_PASSWORD='your-password'
./pg_monit \
  --inventory postgres_monitor/config/inventory.yaml \
  --query-file query_store/pg_monit/health_checks.yaml
```

원하면 PATH에 등록해서 어디서든 `pg_monit`로 실행할 수 있습니다.

```bash
ln -s /Users/momoto/PYTHON_AUTOMATION/POSTGRES/pg_monit /usr/local/bin/pg_monit
```

## inventory 규칙

필수 키:

- `name`
- `connector`: `direct_tcp` 또는 `ssh_bastion_tunnel`
- `db_host`, `db_port`, `db_name`, `db_user`
- `secret_ref`: 현재는 `env:ENV_VAR` 형식 지원

선택 키:

- `monitor`: 임계치 설정 (`max_connection_usage`, `min_cache_hit_ratio` 등)

`ssh_bastion_tunnel` 추가 키:

- `bastion_host`
- `bastion_user`
- `bastion_port` (선택, 기본 22)
- `ssh_key_path` (선택)

## 다음 확장 포인트

- 커넥터 추가: VM 내부 실행형(`in_vm_exec`) 등
- 알림 모듈(Slack/Webhook)
- 결과를 Slack/웹훅 자동 전송
- Prometheus exporter 모드

## pg_pitr (WAL/PITR 진단)

`pg_pitr`는 실제 복구를 실행하지 않고, PITR 가능성 진단과 복구 설정 미리보기를 제공합니다.

```bash
export PG_PITR_SAMPLE_PASSWORD='your-password'
./pg_pitr \
  --inventory postgres_pitr/config/inventory.yaml \
  --query-file query_store/pg_pitr/diagnostics.yaml \
  --target pitr-sample-direct \
  --target-time 2026-03-30T01:15:00+09:00 \
  --timezone Asia/Seoul \
  --restore-command "cp /archive/%f %p"
```

확인 항목:
- LSN / WAL 상태
- `archive_mode`, `archive_command` 설정
- `pg_stat_archiver` 실패 여부
- replication slot 기본 상태
- `backup.basebackup_path`, `backup.wal_archive_path` 경로 기반 커버리지 확인
- PITR runbook step + `postgresql.auto.conf` 미리보기

`pg_pitr` inventory에 아래처럼 백업 경로를 넣어두면 목표 시각 기준 PITR 가능성을 함께 판정합니다.

```yaml
targets:
  - name: pitr-sample-direct
    ...
    backup:
      basebackup_path: /backup/postgres/base
      wal_archive_path: /backup/postgres/wal
      retention_days: 7
```

주의:
- 경로 검증은 현재 `pg_pitr`를 실행한 머신에서 접근 가능한 경로 기준입니다.

쿼리 집중관리:
- `query_store/pg_monit/health_checks.yaml`
- `query_store/pg_pitr/diagnostics.yaml`
- 운영 환경별로 파일을 분리해서 `--query-file`로 교체해 사용할 수 있습니다.
