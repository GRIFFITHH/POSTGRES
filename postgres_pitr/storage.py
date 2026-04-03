from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from postgres_monitor.core.models import TargetConfig


@dataclass
class StorageValidation:
    checks: list[str]
    reasons: list[str]


def _latest_item_mtime(path: Path) -> datetime | None:
    if not path.exists():
        return None

    latest_ts = 0.0
    for item in path.rglob("*"):
        if item.is_file():
            stat = item.stat()
            if stat.st_mtime > latest_ts:
                latest_ts = stat.st_mtime

    if latest_ts == 0.0:
        return None
    return datetime.fromtimestamp(latest_ts).astimezone()


def _latest_item_mtime_before(path: Path, cutoff: datetime) -> datetime | None:
    if not path.exists():
        return None

    selected_ts = 0.0
    for item in path.rglob("*"):
        if not item.is_file():
            continue
        stat = item.stat()
        mt = datetime.fromtimestamp(stat.st_mtime).astimezone()
        if mt <= cutoff and stat.st_mtime > selected_ts:
            selected_ts = stat.st_mtime

    if selected_ts == 0.0:
        return None
    return datetime.fromtimestamp(selected_ts).astimezone()


def validate_storage(target: TargetConfig, target_time: datetime) -> StorageValidation:
    checks: list[str] = []
    reasons: list[str] = []

    backup_cfg = target.extras.get("backup", {})
    if not backup_cfg:
        checks.append("backup config missing: skipped filesystem coverage checks")
        return StorageValidation(checks=checks, reasons=reasons)

    basebackup_path_text = backup_cfg.get("basebackup_path", "")
    wal_archive_path_text = backup_cfg.get("wal_archive_path", "")

    if not basebackup_path_text:
        reasons.append("backup.basebackup_path is not configured")
        return StorageValidation(checks=checks, reasons=reasons)
    if not wal_archive_path_text:
        reasons.append("backup.wal_archive_path is not configured")
        return StorageValidation(checks=checks, reasons=reasons)

    basebackup_path = Path(str(basebackup_path_text))
    wal_archive_path = Path(str(wal_archive_path_text))

    if not basebackup_path.exists():
        reasons.append(f"basebackup_path not found: {basebackup_path}")
        return StorageValidation(checks=checks, reasons=reasons)
    checks.append(f"basebackup_path exists: {basebackup_path}")

    if not wal_archive_path.exists():
        reasons.append(f"wal_archive_path not found: {wal_archive_path}")
        return StorageValidation(checks=checks, reasons=reasons)
    checks.append(f"wal_archive_path exists: {wal_archive_path}")

    latest_basebackup_before_target = _latest_item_mtime_before(basebackup_path, target_time)
    if not latest_basebackup_before_target:
        reasons.append(
            "no base backup artifact timestamp <= target_time in basebackup_path"
        )
    else:
        checks.append(
            "latest base backup artifact before target_time: "
            f"{latest_basebackup_before_target.isoformat()}"
        )

    latest_wal_artifact = _latest_item_mtime(wal_archive_path)
    if not latest_wal_artifact:
        reasons.append("no WAL archive artifacts found in wal_archive_path")
    else:
        checks.append(f"latest WAL archive artifact: {latest_wal_artifact.isoformat()}")
        if latest_wal_artifact < target_time:
            reasons.append(
                "latest WAL archive artifact is older than target_time "
                f"({latest_wal_artifact.isoformat()} < {target_time.isoformat()})"
            )

    retention_days = backup_cfg.get("retention_days")
    if retention_days is not None:
        try:
            retention = int(retention_days)
            checks.append(f"configured retention_days: {retention}")
        except (TypeError, ValueError):
            reasons.append("backup.retention_days must be integer")

    return StorageValidation(checks=checks, reasons=reasons)
