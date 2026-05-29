from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

import paho.mqtt.client as mqtt

from .config import Config

_LOGGER = logging.getLogger(__name__)


def _is_scalar(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float, bool))


class MqttBridge:
    def __init__(self, config: Config, loop: asyncio.AbstractEventLoop, command_handler):
        self._config = config
        self._loop = loop
        self._command_handler = command_handler
        self._prefix = config.mqtt_topic_prefix.rstrip("/")
        self._client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=config.mqtt_client_id,
        )
        if config.mqtt_username:
            self._client.username_pw_set(config.mqtt_username, config.mqtt_password)

        self._client.will_set(f"{self._prefix}/availability", "offline", retain=True)
        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message

    def start(self) -> None:
        _LOGGER.info("Connecting MQTT to %s:%s.", self._config.mqtt_host, self._config.mqtt_port)
        self._client.connect_async(self._config.mqtt_host, self._config.mqtt_port)
        self._client.loop_start()

    def stop(self) -> None:
        self.publish_availability("offline")
        self._client.loop_stop()
        self._client.disconnect()

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        del userdata, flags, properties
        _LOGGER.info("MQTT connected: %s.", reason_code)
        client.subscribe(f"{self._prefix}/set")
        client.subscribe(f"{self._prefix}/set/#")
        self.publish_availability("online")

    def _on_message(self, client, userdata, message) -> None:
        del client, userdata
        topic = message.topic
        payload = message.payload.decode("utf-8").strip()

        try:
            if topic == f"{self._prefix}/set":
                command = json.loads(payload)
                if not isinstance(command, dict):
                    raise ValueError("MQTT set payload must be a JSON object")
            elif topic.startswith(f"{self._prefix}/set/"):
                field = topic.removeprefix(f"{self._prefix}/set/")
                command = {field: payload}
            else:
                return

            future = asyncio.run_coroutine_threadsafe(self._command_handler(command), self._loop)
            future.add_done_callback(self._log_command_result)
        except Exception:
            _LOGGER.exception("Invalid MQTT command on %s: %r", topic, payload)

    def _log_command_result(self, future) -> None:
        try:
            future.result()
        except Exception:
            _LOGGER.exception("MQTT command failed.")

    def publish_availability(self, availability: str) -> None:
        self._client.publish(f"{self._prefix}/availability", availability, retain=True)

    def publish_state(self, state: dict[str, Any]) -> None:
        availability = str(state.get("availability", "offline"))
        self.publish_availability(availability)

        self._client.publish(
            f"{self._prefix}/state",
            json.dumps(state, sort_keys=True),
            retain=True,
        )

        for key, value in state.items():
            if _is_scalar(value):
                payload = "" if value is None else str(value).lower()
                self._client.publish(f"{self._prefix}/reading/{key}", payload, retain=True)

