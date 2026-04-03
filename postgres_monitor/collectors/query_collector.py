from __future__ import annotations

from postgres_monitor.collectors.base import BaseCollector
from postgres_monitor.core.models import CollectorResult, QuerySpec, TargetConfig


class QueryCollector(BaseCollector):
    name = "query_collector"

    def __init__(self, queries: list[QuerySpec]) -> None:
        self.queries = queries

    def collect(self, conn, target: TargetConfig) -> list[CollectorResult]:
        results: list[CollectorResult] = []
        for query in self.queries:
            with conn.cursor() as cur:
                cur.execute(query.sql)
                rows = cur.fetchall() if cur.description else []
                columns = [desc.name for desc in (cur.description or [])]
                normalized_rows = [dict(zip(columns, row)) for row in rows]

            results.append(
                CollectorResult(
                    collector=self.name,
                    metric_key=query.key,
                    rows=normalized_rows,
                )
            )
        return results
