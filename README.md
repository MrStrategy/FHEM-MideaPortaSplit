# FHEM Midea PortaSplit

Small Docker-friendly bridge for a Midea PortaSplit air conditioner.

It talks to the PortaSplit locally via `msmart-ng` and exposes the device to FHEM via:

- MQTT topics for `MQTT2_DEVICE`
- a small HTTP API for `HTTPMOD` or debugging

No Python packages are installed into the FHEM container.

## Known Working Device

Tested locally with a PortaSplit reachable at `10.20.0.49`:

```text
type: AIR_CONDITIONER
port: 6444
supported: true
```

Example readings seen via `msmart-ng`:

```text
power: true
mode: COOL
target_temperature: 22.0
indoor_temperature: 21.5
outdoor_temperature: 30.0
fan_speed: AUTO
swing_mode: VERTICAL
real_time_power_usage: 152.9
total_energy_usage: 15.04
out_silent: false
```

## Quick Start

```sh
cp .env.example .env
docker compose -f docker-compose.example.yml up --build
```

The sample compose file uses `network_mode: host`, because the PortaSplit usually lives in an IoT VLAN and local routing/broadcast is easiest from the host network.

## Configuration

Required:

```text
MIDEA_HOST=10.20.0.49
```

Useful options:

```text
POLL_INTERVAL=30
QUERY_ENERGY=true
HTTP_ENABLE=true
HTTP_PORT=8765
MQTT_ENABLE=true
MQTT_HOST=127.0.0.1
MQTT_TOPIC_PREFIX=fhem/midea/portasplit
```

Optional direct auth:

```text
MIDEA_ID=
MIDEA_TOKEN=
MIDEA_KEY=
```

Leave these empty unless you know what you are doing. Tokens and keys are credentials.

## MQTT Topics

State:

```text
fhem/midea/portasplit/availability  online|offline
fhem/midea/portasplit/state         JSON object
fhem/midea/portasplit/reading/...   retained scalar readings
```

Commands:

```text
fhem/midea/portasplit/set           JSON object, e.g. {"power":"on","target_temperature":22}
fhem/midea/portasplit/set/power     on|off
fhem/midea/portasplit/set/mode      cool|heat|dry|fan_only|auto
```

Supported command fields:

```text
power
target_temperature
mode
fan_speed
swing_mode
horizontal_swing_angle
vertical_swing_angle
cascade_mode
target_humidity
eco
turbo
freeze_protection
sleep
display_on
beep
fahrenheit
follow_me
purifier
out_silent
rate_select
aux_mode
```

## HTTP API

```sh
curl http://localhost:8765/health
curl http://localhost:8765/state
curl -X POST http://localhost:8765/set \
  -H 'Content-Type: application/json' \
  -d '{"target_temperature":22,"power":"on"}'
```

For simple FHEM `HTTPMOD` set commands:

```text
http://bridge-host:8765/set?power=on
http://bridge-host:8765/set?target_temperature=22
```

## FHEM

Examples are in:

```text
fhem/mqtt2-example.cfg
fhem/httpmod-example.cfg
```

MQTT2 is the preferred integration. HTTPMOD is useful when you do not want to run a broker.

## Development

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -e '.[dev]'
pytest
ruff check .
```

