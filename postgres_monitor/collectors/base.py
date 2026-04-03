from __future__ import annotations

from abc import ABC, abstractmethod

from postgres_monitor.core.models import CollectorResult, TargetConfig


class BaseCollector(ABC):
    name: str

    @abstractmethod
    def collect(self, conn, target: TargetConfig) -> list[CollectorResult]:
        raise NotImplementedError
