import LampAgent

extension LampClient {
    /// In-process HomeKit backend. The closure is `HomeKitController.apply`.
    static func homeKit(
        _ apply: @escaping @Sendable (LampState) async throws -> Void
    ) -> LampClient {
        LampClient(apply: apply)
    }
}
