import Dependencies

/// Maps a validated `Command` to a `LampState` and applies it via `LampClient`.
public struct CommandExecutor: Sendable {
    public var execute: @Sendable (_ command: Command) async throws -> Void

    public init(execute: @escaping @Sendable (_ command: Command) async throws -> Void) {
        self.execute = execute
    }
}

extension CommandExecutor {
    static let defaultBrightness = 100
    static let defaultColorTempK = 2700

    public static func live() -> CommandExecutor {
        CommandExecutor { command in
            @Dependency(\.lampClient) var lamp
            let power = command.action != .off
            let state = LampState(
                power: power,
                brightness: command.brightness ?? defaultBrightness,
                colorTempK: command.colorTempK ?? defaultColorTempK
            )
            try await lamp.apply(state)
        }
    }
}
