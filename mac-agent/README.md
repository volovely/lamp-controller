# mac-agent

Swift CLI daemon that runs on the home Mac. Pulls commands from the
Cloudflare Worker and applies them to the lamp via Homebridge's local REST API.

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Run (smoke test only at Stage 0)

```bash
swift run lamp-agent
```

Prints a greeting and exits. Real daemon behavior is added in Stage 1.

## Toolchain

Requires Swift 6.0+ with `swift-testing`. On macOS, point at Xcode rather
than the bare command-line tools so the macOS `Testing.framework` is found:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# or, per-shell:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Install (Stage 1+)

Installation as a launchd LaunchAgent is documented in
[`scripts/install.sh`](scripts/install.sh) and the ops runbook.
