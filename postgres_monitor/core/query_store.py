from __future__ import annotations

from pathlib import Path


class QueryStoreError(RuntimeError):
    pass


def load_query_map(query_file: str) -> dict[str, str]:
    path = Path(query_file)
    if not path.exists():
        raise QueryStoreError(f"Query file not found: {query_file}")

    try:
        import yaml
    except ImportError as exc:
        raise QueryStoreError(
            "PyYAML is required. Install dependencies from requirements.txt"
        ) from exc

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    queries = data.get("queries", {})
    if not isinstance(queries, dict) or not queries:
        raise QueryStoreError(f"No queries found in file: {query_file}")

    normalized: dict[str, str] = {}
    for key, sql in queries.items():
        if not isinstance(key, str) or not isinstance(sql, str):
            raise QueryStoreError(
                f"Invalid query entry in {query_file}. Expect string key/value."
            )
        normalized[key] = sql

    return normalized
