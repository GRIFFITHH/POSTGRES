from __future__ import annotations

import argparse
import sys

from postgres_monitor.collectors.health_collector import HealthCollector
from postgres_monitor.core.engine import MonitorEngine
from postgres_monitor.core.inventory import load_targets
from postgres_monitor.outputs.console import render_console
from postgres_monitor.outputs.json_file import write_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pg_monit", description="Postgres monitoring runner"
    )
    parser.add_argument(
        "--inventory",
        default="postgres_monitor/config/inventory.yaml",
        help="Path to inventory yaml",
    )
    parser.add_argument(
        "--query-file",
        default="query_store/pg_monit/health_checks.yaml",
        help="Path to centralized query file",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Return non-zero when any WARN is detected",
    )
    parser.add_argument(
        "--target",
        action="append",
        default=[],
        help="Run only specific target names (repeatable)",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Optional json output path",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    targets = load_targets(args.inventory)
    if args.target:
        selected = set(args.target)
        targets = [item for item in targets if item.name in selected]

    if not targets:
        print("No targets to run")
        return 1

    collectors = [HealthCollector(query_file=args.query_file)]

    engine = MonitorEngine()
    results = engine.run(targets=targets, collectors=collectors)

    render_console(results)

    if args.output_json:
        write_json(results, args.output_json)
        print(f"\nJSON result saved: {args.output_json}")

    has_errors = not all(item.success for item in results)
    has_warn = False
    for target_result in results:
        for collector_result in target_result.results:
            for row in collector_result.rows:
                status = str(row.get("status", "")).upper()
                if status in {"WARN", "FAIL"}:
                    has_warn = True
                    break
            if has_warn:
                break
        if has_warn:
            break

    if has_errors:
        return 2
    if args.strict and has_warn:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
