import Foundation

/// Only GPU discovery is serialized. Once a tap is ready, the analyses run independently.
@MainActor
final class AppleMusicWorkerStartupGate {
    private var active: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if active == nil {
                    active = id
                    continuation.resume()
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        if Task.isCancelled { release(id); throw CancellationError() }
        return id
    }

    func release(_ id: UUID) {
        guard active == id else { return }
        if waiting.isEmpty { active = nil }
        else {
            let next = waiting.removeFirst()
            active = next.0
            next.1.resume()
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: index).1.resume(throwing: CancellationError())
        } else {
            release(id)
        }
    }
}
