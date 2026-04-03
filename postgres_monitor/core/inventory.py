from __future__ import annotations

from pathlib import Path

from .models import QuerySpec, TargetConfig


class InventoryLoadError(RuntimeError):
    pass


def load_targets(inventory_path: str) -> list[TargetConfig]:
    try:
        import yaml
    except ImportError as exc:
        raise InventoryLoadError(
            "PyYAML is required. Install dependencies from requirements.txt"
        ) from exc

    path = Path(inventory_path)
    if not path.exists():
        raise InventoryLoadError(f"Inventory file not found: {inventory_path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    targets_raw = data.get("targets", [])

    targets: list[TargetConfig] = []
    for item in targets_raw:
        known = {
            "name",
            "connector",
            "db_host",
            "db_port",
            "db_name",
            "db_user",
            "secret_ref",
        }
        extras = {k: v for k, v in item.items() if k not in known}
        targets.append(
            TargetConfig(
                name=item["name"],
                connector=item["connector"],
                db_host=item["db_host"],
                db_port=int(item.get("db_port", 5432)),
                db_name=item["db_name"],
                db_user=item["db_user"],
                secret_ref=item["secret_ref"],
                extras=extras,
            )
        )
    return targets


def load_queries(queries_path: str) -> list[QuerySpec]:
    try:
        import yaml
    except ImportError as exc:
        raise InventoryLoadError(
            "PyYAML is required. Install dependencies from requirements.txt"
        ) from exc

    path = Path(queries_path)
    if not path.exists():
        raise InventoryLoadError(f"Query file not found: {queries_path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    queries_raw = data.get("queries", [])
    queries: list[QuerySpec] = []

    for item in queries_raw:
        queries.append(
            QuerySpec(
                key=item["key"],
                sql=item["sql"],
                timeout_seconds=int(item.get("timeout_seconds", 30)),
            )
        )

    return queries
