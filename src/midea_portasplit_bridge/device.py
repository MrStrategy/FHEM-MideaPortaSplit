from __future__ import annotations

import asyncio
import logging

from msmart.base_device import Device
from msmart.const import DeviceType
from msmart.device import AirConditioner as AC
from msmart.discover import Discover

from .commands import apply_command
from .config import Config
from .state import device_state

_LOGGER = logging.getLogger(__name__)


class MideaPortaSplit:
    def __init__(self, config: Config) -> None:
        self._config = config
        self._device: AC | None = None
        self._lock = asyncio.Lock()
        self._capabilities_loaded = False

    async def _connect(self) -> AC:
        if self._config.has_direct_auth:
            _LOGGER.info(
                "Connecting to Midea AC %s:%s with direct credentials.",
                self._config.midea_host,
                self._config.midea_port,
            )
            device = Device.construct(
                type=DeviceType.AIR_CONDITIONER,
                ip=self._config.midea_host,
                port=self._config.midea_port,
                device_id=self._config.midea_id,
            )
            await device.authenticate(self._config.midea_token, self._config.midea_key)
        else:
            _LOGGER.info("Discovering Midea AC at %s.", self._config.midea_host)
            device = await Discover.discover_single(
                self._config.midea_host,
                region=self._config.midea_region,
                account=self._config.midea_account,
                password=self._config.midea_password,
                auto_connect=True,
            )

        if not isinstance(device, AC):
            raise RuntimeError("Discovered device is not a supported Midea air conditioner")

        device.enable_energy_usage_requests = self._config.query_energy

        if self._config.query_capabilities:
            await device.get_capabilities()
            self._capabilities_loaded = True

        self._device = device
        return device

    async def _get_device(self) -> AC:
        if self._device is None:
            return await self._connect()
        return self._device

    async def refresh(self) -> dict:
        async with self._lock:
            try:
                device = await self._get_device()
                await device.refresh()
                return device_state(device)
            except Exception:
                self._device = None
                self._capabilities_loaded = False
                raise

    async def set(self, command: dict) -> dict:
        async with self._lock:
            try:
                device = await self._get_device()
                await device.refresh()
                if self._config.query_capabilities and not self._capabilities_loaded:
                    await device.get_capabilities()
                    self._capabilities_loaded = True
                await apply_command(device, command)
                await device.refresh()
                return device_state(device)
            except Exception:
                self._device = None
                self._capabilities_loaded = False
                raise
