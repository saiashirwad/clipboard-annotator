import Foundation

/// Shares one asynchronous preparation operation across all concurrent callers.
/// A failed operation is cleared so a later call can retry. The shared task
/// intentionally survives one caller's cancellation so later capture and
/// Settings callers can use the completed preparation.
actor SharedAsyncPreparation<Value: Sendable> {
    private var preparedValue: Value?
    private var inFlight: (id: UUID, task: Task<Value, Error>)?

    func isPrepared() -> Bool {
        preparedValue != nil
    }

    func value(
        prepare: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let preparedValue { return preparedValue }
        if let task = inFlight?.task { return try await task.value }

        let id = UUID()
        let task = Task { try await prepare() }
        inFlight = (id, task)

        do {
            let value = try await task.value
            if inFlight?.id == id {
                preparedValue = value
                inFlight = nil
            }
            return value
        } catch {
            if inFlight?.id == id { inFlight = nil }
            throw error
        }
    }
}
