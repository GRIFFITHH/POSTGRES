from __future__ import annotations

from postgres_monitor.collectors.base import BaseCollector
from postgres_monitor.core.models import CollectorResult, TargetConfig
from postgres_monitor.core.query_store import load_query_map


class HealthCollector(BaseCollector):
    name = "health_collector"

    def __init__(self, query_file: str) -> None:
        self.queries = load_query_map(query_file)

    def _cfg(self, target: TargetConfig, key: str, default):
        monitor = target.extras.get("monitor", {})
        return monitor.get(key, default)

    def _fetch_one(self, conn, sql: str, params: tuple | None = None) -> dict:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            row = cur.fetchone()
            if not row or not cur.description:
                return {}
            columns = [desc.name for desc in cur.description]
            return dict(zip(columns, row))

    def _fetch_all(self, conn, sql: str, params: tuple | None = None) -> list[dict]:
        with conn.cursor() as cur:
            cur.execute(sql, params or ())
            rows = cur.fetchall() if cur.description else []
            columns = [desc.name for desc in (cur.description or [])]
        return [dict(zip(columns, row)) for row in rows]

    def _status_row(self, status: str, summary: str, **payload) -> dict:
        return {"status": status, "summary": summary, **payload}

    def collect(self, conn, target: TargetConfig) -> list[CollectorResult]:
        results: list[CollectorResult] = []

        results.append(self._check_identity(conn))
        results.append(self._check_planner(conn, target))
        results.append(self._check_activity_pressure(conn, target))
        results.append(self._check_db_health(conn, target))
        results.append(self._check_replication(conn, target))

        return results

    def _check_identity(self, conn) -> CollectorResult:
        row = self._fetch_one(
            conn, self.queries["identity"]
        )
        return CollectorResult(
            collector=self.name,
            metric_key="identity",
            rows=[self._status_row("OK", "database identity", **row)],
        )

    def _check_planner(self, conn, target: TargetConfig) -> CollectorResult:
        threshold_ms = float(self._cfg(target, "planner_execution_ms_warn", 100.0))

        row = self._fetch_one(
            conn, self.queries["planner"]
        )

        plan_raw = row.get("QUERY PLAN")
        execution_ms = None
        planning_ms = None

        if isinstance(plan_raw, list) and plan_raw:
            root = plan_raw[0]
            if isinstance(root, dict):
                execution_ms = root.get("Execution Time")
                planning_ms = root.get("Planning Time")

        status = "OK"
        summary = "planner analyze looks healthy"
        if execution_ms is None:
            status = "WARN"
            summary = "planner execution time not parsed"
        elif float(execution_ms) > threshold_ms:
            status = "WARN"
            summary = f"planner execution time high: {execution_ms}ms"

        return CollectorResult(
            collector=self.name,
            metric_key="planner",
            rows=[
                self._status_row(
                    status,
                    summary,
                    planning_time_ms=planning_ms,
                    execution_time_ms=execution_ms,
                    warn_threshold_ms=threshold_ms,
                )
            ],
        )

    def _check_activity_pressure(self, conn, target: TargetConfig) -> CollectorResult:
        long_query_seconds = int(self._cfg(target, "long_query_seconds", 60))
        max_connection_usage = float(self._cfg(target, "max_connection_usage", 0.85))
        max_waiting_locks = int(self._cfg(target, "max_waiting_locks", 3))
        max_long_running_queries = int(self._cfg(target, "max_long_running_queries", 5))

        usage = self._fetch_one(
            conn, self.queries["connection_usage"]
        )
        pressure = self._fetch_one(
            conn, self.queries["activity_pressure"],
            (long_query_seconds,),
        )

        numbackends = int(usage.get("numbackends") or 0)
        max_connections = int(usage.get("max_connections") or 1)
        usage_ratio = numbackends / max_connections if max_connections > 0 else 1.0

        waiting_locks = int(pressure.get("waiting_locks") or 0)
        long_running_queries = int(pressure.get("long_running_queries") or 0)

        status = "OK"
        summary = "connection and activity pressure normal"

        if usage_ratio > max_connection_usage:
            status = "WARN"
            summary = f"connection usage high: {usage_ratio:.2%}"
        if waiting_locks > max_waiting_locks:
            status = "WARN"
            summary = f"lock waits high: {waiting_locks}"
        if long_running_queries > max_long_running_queries:
            status = "WARN"
            summary = f"long running queries high: {long_running_queries}"

        return CollectorResult(
            collector=self.name,
            metric_key="activity_pressure",
            rows=[
                self._status_row(
                    status,
                    summary,
                    numbackends=numbackends,
                    max_connections=max_connections,
                    connection_usage_ratio=usage_ratio,
                    active_sessions=int(pressure.get("active_sessions") or 0),
                    waiting_locks=waiting_locks,
                    long_running_queries=long_running_queries,
                    long_query_seconds=long_query_seconds,
                )
            ],
        )

    def _check_db_health(self, conn, target: TargetConfig) -> CollectorResult:
        min_cache_hit_ratio = float(self._cfg(target, "min_cache_hit_ratio", 0.95))
        max_rollback_ratio = float(self._cfg(target, "max_rollback_ratio", 0.05))
        max_deadlocks = int(self._cfg(target, "max_deadlocks", 0))

        row = self._fetch_one(
            conn, self.queries["db_health"]
        )

        blks_hit = int(row.get("blks_hit") or 0)
        blks_read = int(row.get("blks_read") or 0)
        xact_commit = int(row.get("xact_commit") or 0)
        xact_rollback = int(row.get("xact_rollback") or 0)
        deadlocks = int(row.get("deadlocks") or 0)

        total_blocks = blks_hit + blks_read
        cache_hit_ratio = blks_hit / total_blocks if total_blocks > 0 else 1.0

        total_tx = xact_commit + xact_rollback
        rollback_ratio = xact_rollback / total_tx if total_tx > 0 else 0.0

        status = "OK"
        summary = "db-level health metrics normal"

        if cache_hit_ratio < min_cache_hit_ratio:
            status = "WARN"
            summary = f"cache hit ratio low: {cache_hit_ratio:.2%}"
        if rollback_ratio > max_rollback_ratio:
            status = "WARN"
            summary = f"rollback ratio high: {rollback_ratio:.2%}"
        if deadlocks > max_deadlocks:
            status = "WARN"
            summary = f"deadlocks detected: {deadlocks}"

        return CollectorResult(
            collector=self.name,
            metric_key="db_health",
            rows=[
                self._status_row(
                    status,
                    summary,
                    cache_hit_ratio=cache_hit_ratio,
                    rollback_ratio=rollback_ratio,
                    deadlocks=deadlocks,
                    temp_files=int(row.get("temp_files") or 0),
                    stats_reset=str(row.get("stats_reset") or ""),
                    min_cache_hit_ratio=min_cache_hit_ratio,
                    max_rollback_ratio=max_rollback_ratio,
                    max_deadlocks=max_deadlocks,
                )
            ],
        )

    def _check_replication(self, conn, target: TargetConfig) -> CollectorResult:
        max_replay_lag_seconds = float(self._cfg(target, "max_replay_lag_seconds", 30.0))

        rows = self._fetch_all(
            conn, self.queries["replication"]
        )

        if not rows:
            return CollectorResult(
                collector=self.name,
                metric_key="replication",
                rows=[
                    self._status_row(
                        "INFO",
                        "no streaming replica rows (primary without replicas or non-primary node)",
                    )
                ],
            )

        max_lag = max(float(r.get("replay_lag_seconds") or 0.0) for r in rows)
        status = "OK"
        summary = "replication lag normal"
        if max_lag > max_replay_lag_seconds:
            status = "WARN"
            summary = f"replication lag high: {max_lag:.2f}s"

        return CollectorResult(
            collector=self.name,
            metric_key="replication",
            rows=[
                self._status_row(
                    status,
                    summary,
                    max_observed_replay_lag_seconds=max_lag,
                    warn_threshold_seconds=max_replay_lag_seconds,
                    replicas=rows,
                )
            ],
        )
