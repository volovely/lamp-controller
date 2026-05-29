// HomebridgeClient.skeleton.swift
//
// DOCUMENTATION ARTIFACT — NOT COMPILED, NOT PART OF ANY SPM TARGET.
//
// This file describes the exact REST contract that Task 7 (lamp-mac) must
// implement in mac-agent/Sources/LampAgent/HomebridgeClient.swift.
//
// Reference: homebridge/README.md (sections 7 and 8).
// Base URL:  http://127.0.0.1:8581   (homebridge-config-ui-x, localhost-only)
// Auth:      Bearer JWT, obtained via POST /api/auth/login, lifetime = sessionTimeout
//            (default 28800 s = 8 h; set to 86400 s in config.json.example).
//
// Value-type contract:
//   On                → Bool    (true = on, false = off)
//   Brightness        → Int     (percent, 0–100 inclusive)
//   ColorTemperature  → Int     (mired, clamped to 140–500; lamp effective: 200–385)
//
// Mired conversion:
//   mired = Int((1_000_000.0 / Double(kelvin)).rounded())
//   Clamp to the accessory's advertised minValue/maxValue from GET /api/accessories.
//   For yeelink.light.lamp1 the HAP range is minValue=140, maxValue=500.
//   The lamp's physical range (~2600–5000 K) maps to ~200–385 mired.
//
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Kelvin → Mired conversion

/// Convert a Kelvin color temperature to HomeKit mired (reciprocal megakelvin)
/// and clamp to the HAP Lightbulb ColorTemperature range.
///
/// Formula:  mired = round(1_000_000 / kelvin)
/// HAP range: 140 (≈7143 K, coolest) … 500 (2000 K, warmest)
/// Lamp physical range: ~2600 K (385 mired) … ~5000 K (200 mired)
///
/// Examples:
///   miredFromKelvin(2700)  → 370
///   miredFromKelvin(4000)  → 250
///   miredFromKelvin(5000)  → 200
///   miredFromKelvin(1000)  → 500  (clamped)
///   miredFromKelvin(10000) → 140  (clamped)
func miredFromKelvin(_ kelvin: Int) -> Int {
    fatalError("implemented by lamp-mac in mac-agent/Sources/LampAgent/HomebridgeClient.swift")
}

// MARK: - HomebridgeClient protocol skeleton

/// Drives a single lamp accessory through the homebridge-config-ui-x REST API.
///
/// All three methods issue:
///   PUT http://127.0.0.1:8581/api/accessories/{accessoryId}
///   Authorization: Bearer <token>
///   Content-Type: application/json
///   Body: { "characteristicType": "<name>", "value": <typed value> }
///
/// The `accessoryId` is the 64-character hex `uniqueId` field returned by
///   GET /api/accessories
/// and stored in config.toml as `accessory_id`.
struct HomebridgeClient {

    // -------------------------------------------------------------------------
    // MARK: setPower(on:)
    //
    // Endpoint: PUT /api/accessories/{accessoryId}
    // Body:     { "characteristicType": "On", "value": <Bool> }
    //
    // value = true  → lamp on
    // value = false → lamp off (other fields ignored by the executor)
    //
    // Example body (on):
    //   {"characteristicType":"On","value":true}
    // Example body (off):
    //   {"characteristicType":"On","value":false}
    // -------------------------------------------------------------------------
    var setPower: (_ on: Bool) async throws -> Void = { _ in
        fatalError("implemented by lamp-mac")
    }

    // -------------------------------------------------------------------------
    // MARK: setBrightness(percent:)
    //
    // Endpoint: PUT /api/accessories/{accessoryId}
    // Body:     { "characteristicType": "Brightness", "value": <Int> }
    //
    // value = percent in 0–100 (inclusive). Clamp before sending.
    // Only sent for action=on (when brightness is present) and action=set.
    //
    // Example body (30%):
    //   {"characteristicType":"Brightness","value":30}
    // -------------------------------------------------------------------------
    var setBrightness: (_ percent: Int) async throws -> Void = { _ in
        fatalError("implemented by lamp-mac")
    }

    // -------------------------------------------------------------------------
    // MARK: setColorTemperature(kelvin:)
    //
    // Endpoint: PUT /api/accessories/{accessoryId}
    // Body:     { "characteristicType": "ColorTemperature", "value": <Int> }
    //
    // Input is Kelvin (from command schema field color_temp_k, range 2700–6500).
    // The client MUST convert to mired before sending:
    //   value = miredFromKelvin(kelvin)     // see formula above
    //
    // Clamp to the accessory's advertised minValue/maxValue (140–500 for this lamp).
    // Only sent for action=on (when color_temp_k is present) and action=set.
    //
    // Example: kelvin=2700 → {"characteristicType":"ColorTemperature","value":370}
    // Example: kelvin=4000 → {"characteristicType":"ColorTemperature","value":250}
    // Example: kelvin=5000 → {"characteristicType":"ColorTemperature","value":200}
    // -------------------------------------------------------------------------
    var setColorTemperature: (_ kelvin: Int) async throws -> Void = { _ in
        fatalError("implemented by lamp-mac")
    }
}

// MARK: - Authentication flow (reference, not a callable method)

// The live HomebridgeClient must handle auth internally:
//
//   1. At init / startup:
//        POST http://127.0.0.1:8581/api/auth/login
//        Body: {"username":"admin","password":"<from config.toml>"}
//        Response: {"access_token":"<JWT>","token_type":"Bearer","expires_in":86400}
//        ↑ NOTE: expires_in=86400 (24 h) only because config.json.example sets
//          sessionTimeout=86400. The Homebridge stock default is 28800 (8 h).
//          Do NOT hardcode 86400 — always derive the expiry from the response value.
//
//   2. Store token + expiry (= Date.now + expires_in seconds).
//
//   3. Before each PUT:
//        GET http://127.0.0.1:8581/api/auth/check
//        Authorization: Bearer <token>
//        200 → proceed; 401 → re-authenticate first.
//
//   4. On 401 from a PUT, re-authenticate once and retry.
//
// The token is a standard JWT; expires_in is in seconds (stock default 28800 = 8 h,
// overridden to 86400 = 24 h in config.json.example). There is no static API key mechanism.

// MARK: - Command → characteristic mapping (reference)

// CommandExecutor applies commands in this order:
//
// action=on:
//   1. setPower(on: true)
//   2. setBrightness(percent: command.brightness)    if present
//   3. setColorTemperature(kelvin: command.colorTempK)  if present
//
// action=off:
//   1. setPower(on: false)
//   (brightness and colorTempK are ignored)
//
// action=set:
//   1. setBrightness(percent: command.brightness)    if present
//   2. setColorTemperature(kelvin: command.colorTempK)  if present
//   (power state is not changed)
