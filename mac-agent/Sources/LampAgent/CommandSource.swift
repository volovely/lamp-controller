import Dependencies
import DependenciesMacros

/// The queue the poll loop drains. File-backed in Stage 1; Worker-backed in Stage 2.
@DependencyClient
public struct CommandSource: Sendable {
    public var pending: @Sendable () async throws -> [Command] = { [] }
    public var ack: @Sendable (_ ids: [String]) async throws -> Void
}

extension CommandSource: TestDependencyKey {
    public static let testValue = CommandSource()
}

extension DependencyValues {
    public var commandSource: CommandSource {
        get { self[CommandSource.self] }
        set { self[CommandSource.self] = newValue }
    }
}
