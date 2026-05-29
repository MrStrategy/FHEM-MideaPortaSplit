from __future__ import annotations

import os
from dataclasses import dataclass


def _empty_to_none(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    return value or None


def _bool_env(name: str, default: bool) -> bool:
    value = _empty_to_none(os.getenv(name))
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "y", "on"}


def _int_env(name: str, default: int) -> int:
    value = _empty_to_none(os.getenv(name))
    return default if value is None else int(value)


def _float_env(name: str, default: float) -> float:
    value = _empty_to_none(os.getenv(name))
    return default if value is None else float(value)


@dataclass(frozen=True)
class Config:
    midea_host: str
    midea_port: int = 6444
    midea_id: int | None = None
    midea_token: str | None = None
    midea_key: str | None = None
    midea_region: str = "DE"
    midea_account: str | None = None
    midea_password: str | None = None
    poll_interval: float = 30.0
    query_energy: bool = True
    query_capabilities: bool = False
    http_enabled: bool = True
    http_host: str = "0.0.0.0"
    http_port: int = 8765
    mqtt_enabled: bool = False
    mqtt_host: str = "127.0.0.1"
    mqtt_port: int = 1883
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    mqtt_topic_prefix: str = "fhem/midea/portasplit"
    mqtt_client_id: str = "fhem-midea-portasplit"
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> Config:
        host = _empty_to_none(os.getenv("MIDEA_HOST"))
        if host is None:
            raise ValueError("MIDEA_HOST is required")

        midea_id_raw = _empty_to_none(os.getenv("MIDEA_ID"))

        return cls(
            midea_host=host,
            midea_port=_int_env("MIDEA_PORT", 6444),
            midea_id=int(midea_id_raw) if midea_id_raw else None,
            midea_token=_empty_to_none(os.getenv("MIDEA_TOKEN")),
            midea_key=_empty_to_none(os.getenv("MIDEA_KEY")),
            midea_region=os.getenv("MIDEA_REGION", "DE").strip() or "DE",
            midea_account=_empty_to_none(os.getenv("MIDEA_ACCOUNT")),
            midea_password=_empty_to_none(os.getenv("MIDEA_PASSWORD")),
            poll_interval=_float_env("POLL_INTERVAL", 30.0),
            query_energy=_bool_env("QUERY_ENERGY", True),
            query_capabilities=_bool_env("QUERY_CAPABILITIES", False),
            http_enabled=_bool_env("HTTP_ENABLE", True),
            http_host=os.getenv("HTTP_HOST", "0.0.0.0").strip() or "0.0.0.0",
            http_port=_int_env("HTTP_PORT", 8765),
            mqtt_enabled=_bool_env("MQTT_ENABLE", bool(_empty_to_none(os.getenv("MQTT_HOST")))),
            mqtt_host=os.getenv("MQTT_HOST", "127.0.0.1").strip() or "127.0.0.1",
            mqtt_port=_int_env("MQTT_PORT", 1883),
            mqtt_username=_empty_to_none(os.getenv("MQTT_USERNAME")),
            mqtt_password=_empty_to_none(os.getenv("MQTT_PASSWORD")),
            mqtt_topic_prefix=(
                os.getenv("MQTT_TOPIC_PREFIX", "fhem/midea/portasplit").strip("/")
                or "fhem/midea/portasplit"
            ),
            mqtt_client_id=os.getenv("MQTT_CLIENT_ID", "fhem-midea-portasplit").strip()
            or "fhem-midea-portasplit",
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        )

    @property
    def has_direct_auth(self) -> bool:
        return bool(self.midea_id and self.midea_token and self.midea_key)

