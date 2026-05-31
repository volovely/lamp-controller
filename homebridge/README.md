# Homebridge — Xiaomi Mijia Desk Lamp bridging guide

> **Alternative backend.** The default way the `lamp-agent` controls the lamp
> is the macOS Shortcuts backend (Apple Home), documented in
> [`../mac-agent/README.md`](../mac-agent/README.md#controlling-the-lamp). Use
> this Homebridge path only if you set `lamp_backend = "homebridge"` — e.g. for
> a lamp not already in Apple Home, bridged via a Xiaomi/Yeelight plugin.
> Note: it requires the lamp to be reachable by `homebridge-miot` (Mi Home
> token) — not applicable to a lamp that is HomeKit-only and off the Xiaomi cloud.

This document is the complete, self-contained setup reference for bridging a
Xiaomi Mijia Desk Lamp (1S / Pro family) into Apple Home via Homebridge on a
home Mac, and for calling Homebridge's local REST API from the `lamp-agent`
daemon. No prior Homebridge experience is assumed.

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Homebridge + config-ui-x](#2-install-homebridge--config-ui-x)
3. [Plugin choice: homebridge-miot](#3-plugin-choice-homebridge-miot)
4. [Obtain the lamp's MIoT token and local IP](#4-obtain-the-lamps-miot-token-and-local-ip)
5. [Configure the plugin](#5-configure-the-plugin)
6. [Find the accessory uniqueId and characteristic ranges](#6-find-the-accessory-uniqueid-and-characteristic-ranges)
7. [REST API contract](#7-rest-api-contract)
8. [Token management for the daemon](#8-token-management-for-the-daemon)
9. [Example curl walkthrough](#9-example-curl-walkthrough)
10. [Sanitized reference config](#10-sanitized-reference-config)

---

## 1. Prerequisites

| Requirement | Version / detail |
|---|---|
| macOS | 13 Ventura or later |
| Homebrew | any recent version (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`) |
| Node.js | 20 LTS (install via `brew install node@20 && brew link node@20`) |
| Mi Home app | iOS or Android, same account the lamp is registered to |
| Lamp on Wi-Fi | lamp and Mac on the same LAN, lamp assigned a static DHCP lease in the router |

---

## 2. Install Homebridge + config-ui-x

```bash
# Install Homebridge and the UI globally
sudo npm install -g --unsafe-perm homebridge homebridge-config-ui-x

# Create the default config directory
hb-service install --user "$(whoami)"
```

`hb-service install` registers a launchd agent that starts Homebridge on login.
After it starts, the web UI is available at **http://127.0.0.1:8581**.

If you prefer to keep the UI bound strictly to localhost (recommended — the
daemon only needs to reach it locally), set `host` in `~/.homebridge/config.json`:

```json
{
  "bridge": { ... },
  "platforms": [
    {
      "platform": "config",
      "name": "Config",
      "port": 8581,
      "host": "127.0.0.1"
    }
  ]
}
```

Default admin credentials on a fresh install are `admin` / `admin`; change them
at first login via the UI (Settings → User Accounts).

To verify Homebridge is running (no token required at this stage):

```bash
curl -fsS http://127.0.0.1:8581/ -o /dev/null && echo "Homebridge UI up"
# Any non-connection-refused response confirms the process is listening.
# If the command hangs or errors, run: hb-service restart
```

Once you have a bearer token (Section 8), you can also validate it with:

```
GET /api/auth/check
Authorization: Bearer <token>
→ {"status":"OK"} when valid, 401 when expired
```

(That endpoint is documented fully in Section 7.2.)

---

## 3. Plugin choice: homebridge-miot

### Why homebridge-miot, not a Yeelight plugin

Two plugin families can bridge Xiaomi/Yeelight lamps:

| Plugin | Protocol | What the lamp needs |
|---|---|---|
| **homebridge-miot** (recommended) | Xiaomi MIoT over LAN + optional MiCloud | MIoT device token + local IP |
| homebridge-yeelight / homebridge-xiaomi-yeelight | Yeelight LAN Control protocol | "LAN Control" toggle in Yeelight app |

The Mijia Desk Lamp 1S and Pro are **MIoT devices** (model `yeelink.light.lamp1`
and related). They do not expose the Yeelight LAN Control interface that Yeelight
plugins require; attempting to use a Yeelight plugin will result in "device not
found" errors. homebridge-miot speaks the MIoT protocol natively over the local
network using the device token, making it the correct choice.

homebridge-miot is actively maintained (latest: v1.8.7, March 2026) and
lists `yeelink.light.lamp1` as a supported device.

### Install the plugin

```bash
sudo npm install -g homebridge-miot
```

Or install it through the Homebridge UI: Plugins tab → search "homebridge-miot" →
Install.

---

## 4. Obtain the lamp's MIoT token and local IP

The lamp's **token** (a 32-character hex string) authenticates LAN commands.
You need it once during setup; it does not rotate.

### Method A — homebridge-config-ui-x MiCloud discovery (easiest)

1. Open http://127.0.0.1:8581 → Plugins → homebridge-miot → Settings.
2. Click **Discover All Devices via MiCloud** and enter your Mi/Xiaomi account
   credentials.
3. The plugin lists all devices on your account. Find the desk lamp entry; copy
   its **token** and **IP address**.

### Method B — LAN discovery with `miio` (does NOT yield the token)

`miio` is a separate npm package (not bundled with homebridge-miot) that can
discover MIoT devices on the local network. Install it with:

```bash
sudo npm install -g miio
```

Run LAN discovery:

```bash
miio discover
# Prints devices found on the LAN, including their IP and device ID.
# Example output:
#   Device ID:  12345678
#   Model:      yeelink.light.lamp1
#   Address:    192.168.1.42
#   Token:      ???????????????????????????????
```

**Important limitation:** `miio discover` can find the lamp's IP and device ID,
but it prints `???` for the token unless the device happened to broadcast it
during the discovery window (which newer Xiaomi firmware does not do). LAN
discovery alone is **not a reliable way to obtain the token**.

Use Method B only to confirm the lamp's IP address and device ID on the LAN.
To retrieve the token, use Method A (MiCloud discovery inside the Homebridge UI)
or Method C (Python extractor).

### Method C — Xiaomi Cloud Token Extractor

Download the Python script from
https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor and run it.
It decrypts the token database from your Mi Home account.

### Assign a static IP

Once you have the IP, reserve it in your router's DHCP table (bind the lamp's
MAC address to its current IP). The `homebridge-miot` plugin communicates
directly with this IP; if the address changes, bridging breaks.

---

## 5. Configure the plugin

Add the `miot` platform block to `~/.homebridge/config.json`. The full file
shape is shown in [`config.json.example`](config.json.example); the
lamp-specific section is:

```json
{
  "platform": "miot",
  "name": "MiOT",
  "devices": [
    {
      "name": "Desk Lamp",
      "ip": "192.168.1.42",
      "token": "REPLACE_WITH_32_CHAR_HEX_TOKEN",
      "model": "yeelink.light.lamp1",
      "deviceId": "REPLACE_WITH_DEVICE_ID"
    }
  ]
}
```

`model` is optional but recommended — supplying it lets the plugin create the
HomeKit accessory immediately without waiting for an initial device probe.
`deviceId` is the numeric Xiaomi device ID returned by the MiCloud discovery
commands; it is also optional but helps if you have multiple devices of the
same model.

After saving `config.json`, restart Homebridge:

```bash
hb-service restart
```

Within 30 seconds the lamp appears as a **Lightbulb** accessory in the Home
app (and via the REST API).

### What HomeKit characteristics the lamp exposes

The Mijia Desk Lamp 1S is a tunable-white lamp (no RGB). Through
homebridge-miot it surfaces as a `Lightbulb` service with three characteristics:

| Characteristic | HAP type | Value type | Range |
|---|---|---|---|
| `On` | bool | `true` / `false` | — |
| `Brightness` | int | percentage | 0–100 |
| `ColorTemperature` | int | mired (reciprocal megakelvin) | 140–500 (HAP default) |

The lamp's physical color temperature range is approximately **2600–5000 K**,
which maps to **200–385 mired** — comfortably within the HAP default
140–500 mired window. The `lamp-agent` daemon clamps user-supplied Kelvin values
to the accessory's advertised `minValue`/`maxValue` before writing; see
[Section 7](#7-rest-api-contract) for how to read those advertised values.

**Kelvin to mired conversion:** `mired = round(1_000_000 / kelvin)`.
Examples: 2700 K → 370 mired, 4000 K → 250 mired, 5000 K → 200 mired.

---

## 6. Find the accessory uniqueId and characteristic ranges

The `PUT /api/accessories/{uniqueId}` endpoint requires the accessory's
`uniqueId` — a 64-character hex string computed by Homebridge from the bridge
serial number and service IID. It does not change unless you unpair and
re-pair the bridge.

Get it from the accessories list (substitute your actual bearer token):

```bash
TOKEN="<bearer token from Section 8>"

curl -s http://127.0.0.1:8581/api/accessories \
  -H "Authorization: Bearer $TOKEN" | \
  python3 -m json.tool | grep -A2 '"uniqueId"'
```

The JSON array contains one object per accessory. The desk lamp object looks
like this (fields trimmed to what the daemon needs):

```json
{
  "uniqueId": "a1b2c3d4...64hexchars...e5f6",
  "serviceName": "Desk Lamp",
  "serviceCharacteristics": [
    {
      "iid": 10,
      "type": "On",
      "description": "On",
      "format": "bool",
      "value": false,
      "canRead": true,
      "canWrite": true
    },
    {
      "iid": 11,
      "type": "Brightness",
      "description": "Brightness",
      "format": "int",
      "value": 50,
      "minValue": 0,
      "maxValue": 100,
      "minStep": 1,
      "canRead": true,
      "canWrite": true
    },
    {
      "iid": 12,
      "type": "ColorTemperature",
      "description": "Color Temperature",
      "format": "int",
      "value": 250,
      "minValue": 140,
      "maxValue": 500,
      "minStep": 1,
      "canRead": true,
      "canWrite": true
    }
  ]
}
```

Record the `uniqueId` and write it into `config.toml` as `accessory_id`.
The `minValue`/`maxValue` of `ColorTemperature` confirm the mired clamp range
your daemon should use.

---

## 7. REST API contract

Base URL: `http://127.0.0.1:8581`

All endpoints except `POST /api/auth/login` require an `Authorization: Bearer <token>` header.

### 7.1 Authenticate

```
POST /api/auth/login
Content-Type: application/json

{ "username": "admin", "password": "YOUR_UI_PASSWORD" }
```

Response `200 OK`:

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 28800
}
```

`expires_in` is in seconds (default 8 hours, configurable via `sessionTimeout`
in the `config` platform block). The daemon re-authenticates before the token
expires; see [Section 8](#8-token-management-for-the-daemon).

### 7.2 Validate a token

```
GET /api/auth/check
Authorization: Bearer <token>
```

Response `200 OK` → `{ "status": "OK" }`.
Response `401 Unauthorized` → token expired or invalid; re-authenticate.

### 7.3 List accessories

```
GET /api/accessories
Authorization: Bearer <token>
```

Response: JSON array of accessory objects as shown in Section 6.

### 7.4 Control a characteristic (the core daemon operation)

```
PUT /api/accessories/{uniqueId}
Authorization: Bearer <token>
Content-Type: application/json

{ "characteristicType": "<name>", "value": <value> }
```

The three operations the daemon uses:

| Operation | `characteristicType` | `value` type | `value` example |
|---|---|---|---|
| Power on | `"On"` | bool | `true` |
| Power off | `"On"` | bool | `false` |
| Brightness | `"Brightness"` | int | `30` (percent 0–100) |
| Color temperature | `"ColorTemperature"` | int | `370` (mired; 2700 K) |

Response `200 OK` on success. Response `401` if token expired.

**Important:** `ColorTemperature` takes a **mired** value, not Kelvin. Convert
before sending: `mired = round(1_000_000 / kelvin)`. Clamp to the accessory's
advertised `minValue`–`maxValue` (from `GET /api/accessories`); for this lamp
the effective mired range is 200–385, HAP-clamped to 140–500.

---

## 8. Token management for the daemon

The config-ui-x JWT token has a finite lifetime (`sessionTimeout`, default
28800 s = 8 hours). There is no static API key mechanism; the daemon must
re-authenticate by re-posting credentials.

**Recommended approach for `lamp-agent`:**

1. At startup, `POST /api/auth/login` → store the token and its expiry
   timestamp (`now + expires_in`).
2. Before each `PUT`, call `GET /api/auth/check`. If the response is `401`,
   re-authenticate before retrying.
3. Proactively refresh when fewer than 5 minutes remain in the token lifetime
   (i.e. `GET /api/auth/check` is cheap; call it before each batch of writes).

Storing the token: write it to a mode-`0600` file (e.g.
`~/.local/state/lamp-agent/hb_token.json`) alongside its expiry epoch. Never
hard-code it.

To extend the session lifetime, add `sessionTimeout` to the `config` platform
block in `~/.homebridge/config.json`:

```json
{
  "platform": "config",
  "name": "Config",
  "port": 8581,
  "host": "127.0.0.1",
  "sessionTimeout": 86400
}
```

`86400` = 24 hours. Setting it longer than necessary is a security trade-off
since the token grants full Homebridge admin access; 8–24 hours is reasonable
for a local-only daemon.

---

## 9. Example curl walkthrough

The following commands reproduce exactly what `lamp-agent` does to turn the
lamp on at 30% brightness, warm white (2700 K = 370 mired).

```bash
BASE="http://127.0.0.1:8581"
UID="a1b2c3d4...your64charhex...e5f6"   # from Section 6

# Step 1: authenticate
TOKEN=$(curl -s -X POST "$BASE/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"YOUR_UI_PASSWORD"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Step 2: power on
curl -s -X PUT "$BASE/api/accessories/$UID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"characteristicType":"On","value":true}'

# Step 3: set brightness to 30%
curl -s -X PUT "$BASE/api/accessories/$UID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"characteristicType":"Brightness","value":30}'

# Step 4: set color temperature to 2700 K (370 mired)
curl -s -X PUT "$BASE/api/accessories/$UID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"characteristicType":"ColorTemperature","value":370}'
```

Each `PUT` returns `200 OK` on success, `401` if the token expired.

---

## 10. Sanitized reference config

See [`config.json.example`](config.json.example) for the full `~/.homebridge/config.json`
structure with all sensitive values replaced by placeholders.
