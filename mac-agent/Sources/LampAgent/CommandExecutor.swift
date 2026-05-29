import Dependencies

/// Maps a validated `Command` to ordered `HomebridgeClient` calls.
public struct CommandExecutor: Sendable {
    public var execute: @Sendable (_ command: Command) async throws -> Void

    public init(execute: @escaping @Sendable (_ command: Command) async throws -> Void) {
        self.execute = execute
    }
}

extension CommandExecutor {
    public static func live() -> CommandExecutor {
        CommandExecutor { command in
            @Dependency(\.homebridgeClient) var homebridge

            switch command.action {
            case .on:
                try await homebridge.setPower(true)
                if let brightness = command.brightness {
                    try await homebridge.setBrightness(brightness)
                }
                if let kelvin = command.colorTempK {
                    try await homebridge.setColorTemperature(kelvin)
                }
            case .off:
                try await homebridge.setPower(false)
            case .set:
                if let brightness = command.brightness {
                    try await homebridge.setBrightness(brightness)
                }
                if let kelvin = command.colorTempK {
                    try await homebridge.setColorTemperature(kelvin)
                }
            }
        }
    }
}
