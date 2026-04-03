from __future__ import annotations

from abc import ABC, abstractmethod
from contextlib import AbstractContextManager

from postgres_monitor.core.models import TargetConfig


class BaseConnector(ABC):
    @abstractmethod
    def connect(
        self,
        target: TargetConfig,
        password: str,
    ) -> AbstractContextManager:
        raise NotImplementedError
