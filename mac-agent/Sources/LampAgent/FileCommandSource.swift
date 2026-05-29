import Foundation

extension CommandSource {
    /// Reads a JSON array of commands from `url`. A missing or unreadable file
    /// yields an empty list; individually malformed elements are skipped so one
    /// bad command does not block the rest. `ack` is a no-op — the file is an
    /// append-only log and `AckStore` provides dedup.
    public static func file(at url: URL) -> CommandSource {
        CommandSource(
            pending: {
                guard let data = try? Data(contentsOf: url),
                      let items = try? Command.jsonDecoder.decode([Failable<Command>].self, from: data)
                else { return [] }
                return items.compactMap(\.value)
            },
            ack: { _ in }
        )
    }
}

/// Decodes to `nil` instead of throwing when an element is malformed.
private struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(Wrapped.self)
    }
}
