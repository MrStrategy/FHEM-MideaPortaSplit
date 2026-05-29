import pytest
from msmart.device import AirConditioner as AC

from midea_portasplit_bridge.commands import CommandError, normalize_command, parse_bool


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("on", True),
        ("off", False),
        ("ein", True),
        ("aus", False),
        (1, True),
        (0, False),
        (True, True),
        (False, False),
    ],
)
def test_parse_bool(value, expected):
    assert parse_bool(value) is expected


def test_normalize_basic_command():
    command = normalize_command(
        {
            "power": "on",
            "mode": "cool",
            "fan_speed": "auto",
            "target_temperature": "22.5",
            "out_silent": "off",
        }
    )

    assert command["power_state"] is True
    assert command["operational_mode"] == AC.OperationalMode.COOL
    assert command["fan_speed"] == AC.FanSpeed.AUTO
    assert command["target_temperature"] == 22.5
    assert command["out_silent"] is False


def test_normalize_aliases():
    command = normalize_command({"display": "off", "mode": "fan", "swing_mode": "both"})

    assert command["display_on"] is False
    assert command["operational_mode"] == AC.OperationalMode.FAN_ONLY
    assert command["swing_mode"] == AC.SwingMode.BOTH


def test_unknown_command_fails():
    with pytest.raises(CommandError):
        normalize_command({"banana": "yes"})

