from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from postgres_pitr.models import PITRPlan, PITRTargetReport


def print_report(report: PITRTargetReport, plan: PITRPlan) -> None:
    print(f"\n=== pg_pitr report: {report.target.name} ===")
    print(f"collected_at: {report.collected_at.isoformat()}")
    print(f"ready_for_pitr: {plan.ready}")

    section_errors = [s for s in report.sections if s.error]
    if section_errors:
        print("\n[Diagnostic Query Errors]")
        for sec in section_errors:
            print(f"- {sec.name}: {sec.error}")

    if plan.reasons:
        print("\n[Blocking / Warning]")
        for reason in plan.reasons:
            print(f"- {reason}")

    if plan.checks:
        print("\n[Validation Checks]")
        for check in plan.checks:
            print(f"- {check}")

    print("\n[Recovery Config Preview]")
    for line in plan.recovery_conf_preview:
        print(line)

    print("\n[Runbook Steps]")
    for idx, step in enumerate(plan.steps, start=1):
        print(f"{idx}. {step}")


def write_json(report: PITRTargetReport, plan: PITRPlan, output_path: str) -> None:
    payload = {
        "report": asdict(report),
        "plan": asdict(plan),
    }
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
