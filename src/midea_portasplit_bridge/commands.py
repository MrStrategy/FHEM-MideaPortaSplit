from __future__ import annotations

from enum import Enum
from typing import Any

from msmart.device import AirConditioner as AC


class CommandError(ValueError):
    pass


BOOL_TRUE = {"1", "true", "yes", "y", "on", "ein"}
BOOL_FALSE = {"0", "false", "no", "n", "off", "aus"}


def parse_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        if value in (0, 1):
            return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in BOOL_TRUE:
            return True
        if normalized in BOOL_FALSE:
            return False
    raise CommandError(f"Not a boolean value: {value!r}")


def parse_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise CommandError(f"Not a number: {value!r}") from exc


def parse_int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise CommandError(f"Not an integer: {value!r}") from exc


def parse_enum(value: Any, enum_type: type[Enum]) -> Enum | int:
    if isinstance(value, enum_type):
        return value

    if isinstance(value, int):
        try:
            return enum_type(value)
        except ValueError:
            return value

    if isinstance(value, float) and value.is_integer():
        return parse_enum(int(value), enum_type)

    if isinstance(value, str):
        normalized = value.strip().upper().replace("-", "_").replace(" ", "_")
        aliases = {
            "FAN": "FAN_ONLY",
            "FANONLY": "FAN_ONLY",
            "VERT": "VERTICAL",
            "HORZ": "HORIZONTAL",
            "HORIZ": "HORIZONTAL",
            "ON": "VERTICAL",
        }
        normalized = aliases.get(normalized, normalized)
        if normalized in enum_type.__members__:
            return enum_type[normalized]
        try:
            return enum_type(int(normalized))
        except (ValueError, KeyError):
            pass

    allowed = ", ".join(member.lower() for member in enum_type.__members__)
    raise CommandError(f"Invalid {enum_type.__name__}: {value!r}. Allowed: {allowed}")


COMMANDS: dict[str, tuple[str, Any]] = {
    "power": ("power_state", parse_bool),
    "power_state": ("power_state", parse_bool),
    "target_temperature": ("target_temperature", parse_float),
    "target_humidity": ("target_humidity", parse_int),
    "mode": ("operational_mode", lambda value: parse_enum(value, AC.OperationalMode)),
    "operational_mode": ("operational_mode", lambda value: parse_enum(value, AC.OperationalMode)),
    "fan_speed": ("fan_speed", lambda value: parse_enum(value, AC.FanSpeed)),
    "swing_mode": ("swing_mode", lambda value: parse_enum(value, AC.SwingMode)),
    "horizontal_swing_angle": (
        "horizontal_swing_angle",
        lambda value: parse_enum(value, AC.SwingAngle),
    ),
    "vertical_swing_angle": (
        "vertical_swing_angle",
        lambda value: parse_enum(value, AC.SwingAngle),
    ),
    "cascade_mode": ("cascade_mode", lambda value: parse_enum(value, AC.CascadeMode)),
    "rate_select": ("rate_select", lambda value: parse_enum(value, AC.RateSelect)),
    "aux_mode": ("aux_mode", lambda value: parse_enum(value, AC.AuxHeatMode)),
    "eco": ("eco", parse_bool),
    "turbo": ("turbo", parse_bool),
    "freeze_protection": ("freeze_protection", parse_bool),
    "sleep": ("sleep", parse_bool),
    "display_on": ("display_on", parse_bool),
    "display": ("display_on", parse_bool),
    "beep": ("beep", parse_bool),
    "fahrenheit": ("fahrenheit", parse_bool),
    "follow_me": ("follow_me", parse_bool),
    "purifier": ("purifier", parse_bool),
    "out_silent": ("out_silent", parse_bool),
}


def normalize_command(command: dict[str, Any]) -> dict[str, Any]:
    normalized: dict[str, Any] = {}
    for key, value in command.items():
        command_key = key.strip().lower().replace("-", "_")
        if command_key not in COMMANDS:
            allowed = ", ".join(sorted(COMMANDS))
            raise CommandError(f"Unsupported command field {key!r}. Allowed: {allowed}")

        property_name, parser = COMMANDS[command_key]
        normalized[property_name] = parser(value)

    if not normalized:
        raise CommandError("Command is empty")

    return normalized


async def apply_command(device: AC, command: dict[str, Any]) -> None:
    normalized = normalize_command(command)

    display_target = normalized.pop("display_on", None)

    for property_name, value in normalized.items():
        setattr(device, property_name, value)

    if normalized:
        await device.apply()

    if display_target is not None and display_target != device.display_on:
        await device.toggle_display()

