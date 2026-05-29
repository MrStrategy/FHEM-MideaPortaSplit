from __future__ import annotations

import asyncio
import logging
import signal

from .config import Config
from .device import MideaPortaSplit
from .http_api import HTTPApi
from .mqtt_client import MqttBridge
from .state import StateStore, error_state

_LOGGER = logging.getLogger(__name__)


class BridgeApp:
    def __init__(self, config: Config) -> None:
        self._config = config
        self._device = MideaPortaSplit(config)
        self._state_store = StateStore()
        self._mqtt: MqttBridge | None = None
        self._http: HTTPApi | None = None

    async def handle_command(self, command: dict) -> dict:
        _LOGGER.info("Applying command: %s", command)
        state = await self._device.set(command)
        self._publish(state)
        return state

    def _publish(self, state: dict) -> None:
        self._state_store.set(state)
        if self._mqtt:
            self._mqtt.publish_state(state)

    async def poll_loop(self, stop_event: asyncio.Event) -> None:
        while not stop_event.is_set():
            try:
                state = await self._device.refresh()
                self._publish(state)
                _LOGGER.info(
                    "Polled PortaSplit: power=%s mode=%s target=%s indoor=%s power_w=%s",
                    state.get("power"),
                    state.get("mode"),
                    state.get("target_temperature"),
                    state.get("indoor_temperature"),
                    state.get("real_time_power_usage"),
                )
            except Exception as exc:
                _LOGGER.exception("Polling failed.")
                state = error_state(str(exc))
                self._publish(state)

            try:
                await asyncio.wait_for(stop_event.wait(), timeout=self._config.poll_interval)
            except TimeoutError:
                pass

    async def start(self) -> None:
        loop = asyncio.get_running_loop()

        if self._config.mqtt_enabled:
            self._mqtt = MqttBridge(self._config, loop, self.handle_command)
            self._mqtt.start()

        if self._config.http_enabled:
            self._http = HTTPApi(
                self._config.http_host,
                self._config.http_port,
                loop,
                self._state_store,
                self.handle_command,
            )
            self._http.start()

    async def stop(self) -> None:
        if self._http:
            self._http.stop()
        if self._mqtt:
            self._mqtt.stop()


async def main() -> None:
    config = Config.from_env()
    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if config.log_level != "DEBUG":
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("msmart").setLevel(logging.WARNING)

    app = BridgeApp(config)
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_event.set)

    await app.start()
    poll_task = asyncio.create_task(app.poll_loop(stop_event))

    try:
        await stop_event.wait()
    finally:
        poll_task.cancel()
        await asyncio.gather(poll_task, return_exceptions=True)
        await app.stop()


def run() -> None:
    asyncio.run(main())
