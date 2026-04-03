from __future__ import annotations

from datetime import datetime, timezone

from postgres_monitor.collectors.base import BaseCollector
from postgres_monitor.connectors.registry import ConnectorRegistry
from postgres_monitor.core.models import TargetConfig, TargetRunResult
from postgres_monitor.core.secrets import resolve_secret


class MonitorEngine:
    def __init__(self, connector_registry: ConnectorRegistry | None = None) -> None:
        self.connector_registry = connector_registry or ConnectorRegistry()

    def run(
        self,
        targets: list[TargetConfig],
        collectors: list[BaseCollector],
    ) -> list[TargetRunResult]:
        run_results: list[TargetRunResult] = []

        for target in targets:
            result = TargetRunResult(target_name=target.name, success=True, results=[])
            try:
                password = resolve_secret(target.secret_ref)
                connector = self.connector_registry.get(target.connector)

                with connector.connect(target=target, password=password) as conn:
                    for collector in collectors:
                        result.results.extend(collector.collect(conn=conn, target=target))

            except Exception as exc:  # noqa: BLE001
                result.success = False
                result.error = str(exc)
            finally:
                result.finished_at = datetime.now(timezone.utc).isoformat()
                run_results.append(result)

        return run_results
