import Foundation

extension CommandSource {
    public enum WorkerError: Error, Equatable {
        case requestFailed(status: Int)
        case unreachable
        case hostMismatch
    }

    /// Worker-backed source. `pending` GETs /commands; `ack` POSTs /ack.
    /// Both send `Authorization: Bearer <sharedSecret>` and verify the response
    /// host matches `baseURL` (anti-redirect/spoof guard).
    public static func worker(
        baseURL: URL,
        sharedSecret: String,
        session: URLSession = .shared
    ) -> CommandSource {
        let expectedHost = baseURL.host

        @Sendable func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let result = await Result { try await session.data(for: request) }
            let (data, response): (Data, URLResponse)
            switch result {
            case .success(let pair): (data, response) = pair
            case .failure: throw WorkerError.unreachable
            }
            guard let http = response as? HTTPURLResponse else {
                throw WorkerError.requestFailed(status: -1)
            }
            if let expectedHost, http.url?.host != expectedHost {
                throw WorkerError.hostMismatch
            }
            guard (200...299).contains(http.statusCode) else {
                throw WorkerError.requestFailed(status: http.statusCode)
            }
            return (data, http)
        }

        struct CommandsResponse: Decodable { let commands: [Failable<Command>] }

        return CommandSource(
            pending: {
                var request = URLRequest(url: baseURL.appendingPathComponent("commands"))
                request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
                let (data, _) = try await send(request)
                let decoded = try Command.jsonDecoder.decode(CommandsResponse.self, from: data)
                return decoded.commands.compactMap(\.value)
            },
            ack: { ids in
                var request = URLRequest(url: baseURL.appendingPathComponent("ack"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["ids": ids])
                _ = try await send(request)
            }
        )
    }
}

/// Decodes to `nil` instead of throwing when an element is malformed.
/// (Mirrors the helper in FileCommandSource; kept file-private here.)
private struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(Wrapped.self)
    }
}
