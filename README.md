# FHEM Midea PortaSplit

Small Docker-friendly bridge for a Midea PortaSplit air conditioner.

It talks to the PortaSplit locally via `msmart-ng` and exposes the device to FHEM via:

- a native FHEM module (`MideaPortaSplit`)
- MQTT topics for `MQTT2_DEVICE`
- a small HTTP API for `HTTPMOD` or debugging

No Python packages are installed into the FHEM container. The FHEM module only talks
to the bridge HTTP API.

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

## Quick Start With Docker

```sh
cp .env.example .env
docker compose -f docker-compose.example.yml up --build
```

The sample compose file uses `network_mode: host`, because the PortaSplit usually lives in an IoT VLAN and local routing/broadcast is easiest from the host network.

## Raspberry Pi / FHEM Quick Start

Build and run the bridge on the Docker host:

```sh
git clone https://github.com/MrStrategy/FHEM-MideaPortaSplit.git
cd FHEM-MideaPortaSplit
docker build -t fhem-midea-portasplit:0.2.2 -t fhem-midea-portasplit:latest .
cp .env.example .env
cp deploy/rpi/docker-compose.yml docker-compose.yml
```

Edit `.env` and set your PortaSplit IP:

```text
MIDEA_HOST=10.20.0.49
HTTP_ENABLE=true
HTTP_PORT=8765
MQTT_ENABLE=false
```

Start the service:

```sh
docker compose up -d
curl http://127.0.0.1:8765/state
```

Then install the native FHEM module and define the device:

```sh
cp fhem/70_MideaPortaSplit.pm /path/to/fhem/FHEM/
```

```text
define midea.portasplit MideaPortaSplit http://10.0.0.80:8765
attr midea.portasplit room Klima
attr midea.portasplit devStateIcon .*:noIcon:noFhemwebLink
attr midea.portasplit webCmd target_temperature:mode:fan_speed
```

For an RPi at `10.0.0.80`, a ready-to-use example is in:

```text
deploy/rpi/fhem-module.cfg
```

HTTPMOD remains available as a fallback; see `deploy/rpi/fhem-httpmod.cfg`.

The native FHEM device offers readings like:

```text
state
power
mode
target_temperature
indoor_temperature
outdoor_temperature
real_time_power_usage
total_energy_usage
fan_speed
swing_mode
out_silent
availability
```

And set commands like:

```text
set midea.portasplit off
set midea.portasplit power off
set midea.portasplit target_temperature 22
set midea.portasplit mode cool
set midea.portasplit fan_speed auto
set midea.portasplit out_silent on
set midea.portasplit update
```

The default `state` display is compact:

```text
offline
off | 24.0°C indoor
cool | 26.0°C -> 22.0°C | eco silent | 194 W
```

The module defaults `devStateIcon` to text display and `webCmd` to
`target_temperature:mode:fan_speed`, so FHEMWEB does not render it as a generic
on/off lamp.

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

## Security Notes

The bridge intentionally suppresses verbose `msmart-ng` logs unless `LOG_LEVEL=DEBUG`,
because Midea V3 authentication may expose session keys or tokens in debug output.

Do not commit `.env` files with `MIDEA_TOKEN`, `MIDEA_KEY`, cloud account names, or passwords.

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

Preferred native module:

```text
fhem/70_MideaPortaSplit.pm
deploy/rpi/fhem-module.cfg
```

The module includes FHEM commandref help with define, set, get, attribute, and
reading descriptions.

Fallback examples are in:

```text
fhem/mqtt2-example.cfg
fhem/httpmod-example.cfg
```

The native module is the preferred FHEM integration. HTTPMOD is useful for quick
debugging, and MQTT2 is useful when you already run a broker.

## Development

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -e '.[dev]'
pytest
ruff check .
```
