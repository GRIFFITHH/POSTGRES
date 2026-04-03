from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


@dataclass
class TargetConfig:
    name: str
    connector: str
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    secret_ref: str
    extras: dict[str, Any] = field(default_factory=dict)


@dataclass
class QuerySpec:
    key: str
    sql: str
    timeout_seconds: int = 30


@dataclass
class CollectorResult:
    collector: str
    metric_key: str
    rows: list[dict[str, Any]]
    collected_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


@dataclass
class TargetRunResult:
    target_name: str
    success: bool
    results: list[CollectorResult]
    error: str | None = None
    started_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    finished_at: str | None = None
