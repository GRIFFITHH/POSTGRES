from __future__ import annotations

from postgres_monitor.core.models import TargetRunResult


def render_console(results: list[TargetRunResult]) -> None:
    print("\n=== Postgres Monitor Results ===")
    for item in results:
        status = "OK" if item.success else "FAILED"
        print(f"\n[{status}] target={item.target_name}")
        if item.error:
            print(f"  error: {item.error}")
            continue

        for collector_result in item.results:
            if not collector_result.rows:
                print(f"  - {collector_result.metric_key}: NO_DATA")
                continue

            row = collector_result.rows[0]
            metric_status = str(row.get("status", "INFO"))
            summary = str(row.get("summary", ""))
            print(f"  - {collector_result.metric_key}: {metric_status} - {summary}")
