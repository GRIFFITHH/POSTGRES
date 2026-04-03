from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from postgres_monitor.core.models import TargetRunResult


def write_json(results: list[TargetRunResult], output_path: str) -> None:
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps([asdict(item) for item in results], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
