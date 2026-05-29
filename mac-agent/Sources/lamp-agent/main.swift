import Dependencies
import Foundation
import LampAgent

// Resolve config path: $LAMP_AGENT_CONFIG or ~/.config/lamp-agent/config.toml
let configPath = ProcessInfo.processInfo.environment["LAMP_AGENT_CONFIG"]
    ?? (NSString(string: "~/.config/lamp-agent/config.toml").expandingTildeInPath)

let config: Config
do {
    config = try Config.load(from: URL(fileURLWithPath: configPath))
} catch {
    FileHandle.standardError.write(Data("lamp-agent: failed to load config at \(configPath): \(error)\n".utf8))
    exit(1)
}

let runOnce = CommandLine.arguments.contains("--once")

let lampClient: LampClient
switch config.lampBackend {
case .shortcuts:
    lampClient = .shortcuts(prefix: config.shortcutPrefix, runner: .live)
case .homebridge:
    // Unreachable: Config.parse() already validates these for the homebridge backend; this unwraps the optionals.
    guard let url = config.homebridgeURL,
          let token = config.homebridgeToken,
          let accessoryId = config.accessoryId
    else {
        FileHandle.standardError.write(
            Data("lamp-agent: homebridge backend requires homebridge_url, homebridge_token, accessory_id\n".utf8)
        )
        exit(1)
    }
    lampClient = .homebridge(baseURL: url, token: token, accessoryId: accessoryId)
}

await withDependencies {
    $0.lampClient = lampClient
} operation: {
    let loop = Runtime.makePollLoop(config: config)
    do {
        if runOnce {
            let outcome = try await loop.runOnce()
            print("lamp-agent: applied=\(outcome.applied) stale=\(outcome.skippedStale) failed=\(outcome.failed)")
        } else {
            print("lamp-agent: starting poll loop (interval \(config.pollIntervalSeconds)s)")
            try await loop.run(intervalSeconds: config.pollIntervalSeconds)
        }
    } catch {
        FileHandle.standardError.write(Data("lamp-agent: fatal: \(error)\n".utf8))
        exit(1)
    }
}
