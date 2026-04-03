from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from postgres_monitor.core.models import TargetConfig


@dataclass
class DiagnosticSection:
    name: str
    rows: list[dict[str, Any]]
    error: str | None = None


@dataclass
class PITRTargetReport:
    target: TargetConfig
    collected_at: datetime
    sections: list[DiagnosticSection] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    ready: bool = False


@dataclass
class PITRPlan:
    target_name: str
    target_time: str
    timezone: str
    ready: bool
    reasons: list[str]
    checks: list[str]
    recovery_conf_preview: list[str]
    steps: list[str]
