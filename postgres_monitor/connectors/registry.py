from postgres_monitor.connectors.base import BaseConnector
from postgres_monitor.connectors.direct_tcp import DirectTCPConnector
from postgres_monitor.connectors.ssh_bastion_tunnel import SSHBastionTunnelConnector


class ConnectorRegistry:
    def __init__(self) -> None:
        self._connectors: dict[str, BaseConnector] = {
            "direct_tcp": DirectTCPConnector(),
            "ssh_bastion_tunnel": SSHBastionTunnelConnector(),
        }

    def get(self, connector_name: str) -> BaseConnector:
        connector = self._connectors.get(connector_name)
        if not connector:
            supported = ", ".join(sorted(self._connectors.keys()))
            raise RuntimeError(
                f"Unknown connector '{connector_name}'. Supported: {supported}"
            )
        return connector
