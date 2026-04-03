from __future__ import annotations

from contextlib import contextmanager

from postgres_monitor.connectors.base import BaseConnector
from postgres_monitor.core.models import TargetConfig


class SSHBastionTunnelConnector(BaseConnector):
    @contextmanager
    def connect(self, target: TargetConfig, password: str):
        try:
            import psycopg
            from sshtunnel import SSHTunnelForwarder
        except ImportError as exc:
            raise RuntimeError(
                "psycopg and sshtunnel are required. Install requirements.txt"
            ) from exc

        bastion_host = target.extras.get("bastion_host")
        bastion_user = target.extras.get("bastion_user")
        bastion_port = int(target.extras.get("bastion_port", 22))
        ssh_key_path = target.extras.get("ssh_key_path")

        if not bastion_host or not bastion_user:
            raise RuntimeError(
                "ssh_bastion_tunnel requires bastion_host and bastion_user in inventory"
            )

        server = SSHTunnelForwarder(
            (bastion_host, bastion_port),
            ssh_username=bastion_user,
            ssh_pkey=ssh_key_path,
            remote_bind_address=(target.db_host, target.db_port),
            local_bind_address=("127.0.0.1", 0),
        )
        server.start()

        conn = psycopg.connect(
            host="127.0.0.1",
            port=server.local_bind_port,
            dbname=target.db_name,
            user=target.db_user,
            password=password,
            connect_timeout=int(target.extras.get("connect_timeout", 5)),
        )

        try:
            yield conn
        finally:
            conn.close()
            server.stop()
