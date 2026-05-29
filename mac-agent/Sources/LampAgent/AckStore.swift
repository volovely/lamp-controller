import Foundation

/// Crash-safe ledger of applied command UUIDs, backed by a JSON array file.
public struct AckStore: Sendable {
    public var load: @Sendable () throws -> Set<String>
    public var record: @Sendable (_ ids: [String]) throws -> Void

    public init(
        load: @escaping @Sendable () throws -> Set<String>,
        record: @escaping @Sendable (_ ids: [String]) throws -> Void
    ) {
        self.load = load
        self.record = record
    }
}

extension AckStore {
    /// File-backed store. A missing or corrupt file reads as an empty set.
    public static func file(at url: URL) -> AckStore {
        let queue = DispatchQueue(label: "lamp-agent.ackstore")

        @Sendable func read() -> Set<String> {
            guard let data = try? Data(contentsOf: url),
                  let array = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(array)
        }

        return AckStore(
            load: { queue.sync { read() } },
            record: { ids in
                try queue.sync {
                    var current = read()
                    current.formUnion(ids)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let data = try JSONEncoder().encode(current.sorted())
                    try data.write(to: url, options: .atomic)
                }
            }
        )
    }
}
