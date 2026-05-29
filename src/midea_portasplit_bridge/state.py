from __future__ import annotations

from datetime import UTC, datetime
from enum import Enum
from threading import Lock
from typing import Any

from msmart.device import AirConditioner as AC


def _serialize_value(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.name.lower()
    if isinstance(value, dict):
        return {key: _serialize_value(val) for key, val in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_serialize_value(item) for item in value]
    return value


def device_state(device: AC) -> dict[str, Any]:
    data = device.to_dict()
    data.pop("token", None)
    data.pop("key", None)

    data["timestamp"] = datetime.now(UTC).isoformat()
    data["availability"] = "online" if device.online else "offline"

    return _serialize_value(data)


def error_state(message: str) -> dict[str, Any]:
    return {
        "timestamp": datetime.now(UTC).isoformat(),
        "availability": "offline",
        "online": False,
        "supported": False,
        "error": message,
    }


class StateStore:
    def __init__(self) -> None:
        self._lock = Lock()
        self._state: dict[str, Any] = {
            "availability": "starting",
            "online": False,
            "supported": False,
        }

    def set(self, state: dict[str, Any]) -> None:
        with self._lock:
            self._state = dict(state)

    def get(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._state)

    def get_error(self) -> str | None:
        return self.get().get("error")

