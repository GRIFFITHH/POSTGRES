from __future__ import annotations

import argparse
import sys

from postgres_monitor.connectors.registry import ConnectorRegistry
from postgres_monitor.core.inventory import load_targets
from postgres_monitor.core.secrets import resolve_secret

from postgres_pitr.collector import collect_diagnostics
from postgres_pitr.output import print_report, write_json
from postgres_pitr.planner import build_plan


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="pg_pitr", description="Postgres PITR diagnostics and plan generator"
    )
    parser.add_argument(
        "--inventory",
        default="postgres_pitr/config/inventory.yaml",
        help="Path to inventory yaml",
    )
    parser.add_argument(
        "--query-file",
        default="query_store/pg_pitr/diagnostics.yaml",
        help="Path to centralized query file",
    )
    parser.add_argument(
        "--target",
        required=True,
        help="Target name in inventory",
    )
    parser.add_argument(
        "--target-time",
        required=True,
        help="Desired recovery time (ISO-8601), e.g. 2026-03-30T01:15:00+09:00",
    )
    parser.add_argument(
        "--timezone",
        default="Asia/Seoul",
        help="Timezone used when target-time has no offset",
    )
    parser.add_argument(
        "--restore-command",
        default="cp /archive/%f %p",
        help="restore_command template to embed into recovery preview",
    )
    parser.add_argument(
        "--output-json",
        default="",
        help="Optional output path for full report JSON",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    targets = load_targets(args.inventory)
    target = next((t for t in targets if t.name == args.target), None)
    if not target:
        print(f"Target not found: {args.target}")
        return 1

    password = resolve_secret(target.secret_ref)
    connector = ConnectorRegistry().get(target.connector)

    with connector.connect(target=target, password=password) as conn:
        report = collect_diagnostics(conn, target, args.query_file)

    plan = build_plan(
        report=report,
        target_time_text=args.target_time,
        tz_name=args.timezone,
        restore_command=args.restore_command,
    )
    print_report(report, plan)

    if args.output_json:
        write_json(report, plan, args.output_json)
        print(f"\nJSON result saved: {args.output_json}")

    return 0 if plan.ready else 2


if __name__ == "__main__":
    sys.exit(main())
