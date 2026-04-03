from __future__ import annotations

from contextlib import contextmanager

from postgres_monitor.connectors.base import BaseConnector
from postgres_monitor.core.models import TargetConfig


class DirectTCPConnector(BaseConnector):
    @contextmanager
    def connect(self, target: TargetConfig, password: str):
        try:
            import psycopg
        except ImportError as exc:
            raise RuntimeError(
                "psycopg is required. Install dependencies from requirements.txt"
            ) from exc

        conn = psycopg.connect(
            host=target.db_host,
            port=target.db_port,
            dbname=target.db_name,
            user=target.db_user,
            password=password,
            connect_timeout=int(target.extras.get("connect_timeout", 5)),
        )
        try:
            yield conn
        finally:
            conn.close()
