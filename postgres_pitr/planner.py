from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from postgres_pitr.models import PITRPlan, PITRTargetReport
from postgres_pitr.storage import validate_storage


def _section(report: PITRTargetReport, name: str) -> dict | None:
    for sec in report.sections:
        if sec.name == name and sec.rows:
            return sec.rows[0]
    return None


def _setting_map(report: PITRTargetReport) -> dict[str, str]:
    out: dict[str, str] = {}
    for sec in report.sections:
        if sec.name != "archive_settings":
            continue
        for row in sec.rows:
            key = str(row.get("name", "")).strip()
            if key:
                out[key] = str(row.get("setting", "")).strip()
    return out


def build_plan(
    report: PITRTargetReport,
    target_time_text: str,
    tz_name: str,
    restore_command: str,
) -> PITRPlan:
    reasons: list[str] = []
    checks: list[str] = []
    steps: list[str] = []

    tz = ZoneInfo(tz_name)
    target_time = datetime.fromisoformat(target_time_text)
    if target_time.tzinfo is None:
        target_time = target_time.replace(tzinfo=tz)

    now_tz = datetime.now(tz)
    if target_time > now_tz:
        reasons.append("target_time must be in the past")

    settings = _setting_map(report)
    archive_mode = settings.get("archive_mode", "")
    archive_command = settings.get("archive_command", "")

    if archive_mode.lower() not in {"on", "always"}:
        reasons.append("archive_mode is not enabled")
    if not archive_command or archive_command in {"(disabled)", "false", "off"}:
        reasons.append("archive_command is empty or disabled")

    archiver = _section(report, "archiver_stats")
    if archiver:
        failed_count = int(archiver.get("failed_count") or 0)
        archived_count = int(archiver.get("archived_count") or 0)
        if archived_count <= 0:
            reasons.append("no archived WAL files found in pg_stat_archiver")
        if failed_count > 0:
            reasons.append("pg_stat_archiver shows failed WAL archiving")
    else:
        reasons.append("cannot read pg_stat_archiver")

    identity = _section(report, "server_identity") or {}
    server_version_num = int(identity.get("server_version_num") or 0)
    if server_version_num and server_version_num < 120000:
        reasons.append("PostgreSQL 12+ is required for this pg_pitr profile")

    current = _section(report, "wal_lsn") or {}

    storage_validation = validate_storage(target=report.target, target_time=target_time)
    checks.extend(storage_validation.checks)
    reasons.extend(storage_validation.reasons)

    steps.append("Take or validate a recent base backup before restore drill")
    steps.append("Prepare clean data directory on restore host")
    steps.append("Restore base backup into target PGDATA")
    steps.append("Write recovery settings with restore_command and recovery_target_time")
    steps.append("Start PostgreSQL and verify replay reaches target time")
    steps.append("Run validation queries and application smoke checks")

    preview = [
        "# postgresql.auto.conf preview",
        f"restore_command = '{restore_command}'",
        f"recovery_target_time = '{target_time.isoformat()}'",
        "recovery_target_action = 'pause'",
    ]

    if current.get("is_in_recovery") is True:
        reasons.append("target is in recovery mode (standby); use primary for archive truth")

    ready = len(reasons) == 0

    if not ready:
        report.warnings.extend(reasons)

    return PITRPlan(
        target_name=report.target.name,
        target_time=target_time.isoformat(),
        timezone=tz_name,
        ready=ready,
        reasons=reasons,
        checks=checks,
        recovery_conf_preview=preview,
        steps=steps,
    )
