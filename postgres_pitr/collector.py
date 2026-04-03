from __future__ import annotations

from datetime import datetime, timezone

from postgres_monitor.core.query_store import load_query_map
from postgres_pitr.models import DiagnosticSection, PITRTargetReport


def _fetch_rows(conn, sql: str) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(sql)
        rows = cur.fetchall() if cur.description else []
        columns = [d.name for d in (cur.description or [])]
    return [dict(zip(columns, row)) for row in rows]


def collect_diagnostics(conn, target, query_file: str) -> PITRTargetReport:
    queries = load_query_map(query_file)
    report = PITRTargetReport(target=target, collected_at=datetime.now(timezone.utc))
    for name, sql in queries.items():
        try:
            rows = _fetch_rows(conn, sql)
            report.sections.append(DiagnosticSection(name=name, rows=rows))
        except Exception as exc:  # noqa: BLE001
            report.sections.append(DiagnosticSection(name=name, rows=[], error=str(exc)))
    return report
