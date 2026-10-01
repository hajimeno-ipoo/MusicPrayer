import Foundation

/// The audio switches immediately. Only the outgoing visual snapshot is retained.
struct TrackVisualTransition {
    static let halfDuration: Double = 0.4
    private let outgoing: VisualFrame?
    private let started: Double
    private let wasPlaying: Bool

    init(outgoing: VisualFrame?, started: Double, wasPlaying: Bool) {
        self.outgoing = outgoing
        self.started = started
        self.wasPlaying = wasPlaying
    }

    var duration: Double { outgoing == nil ? Self.halfDuration : Self.halfDuration * 2 }

    func isFinished(at now: Double) -> Bool { now - started >= duration }

    func frame(incoming: VisualFrame, at now: Double) -> VisualFrame {
        let elapsed = max(0, now - started)
        if var old = outgoing, elapsed < Self.halfDuration {
            if wasPlaying { old.time += Float(elapsed) }
            old.presence *= Self.envelope(1 - elapsed / Self.halfDuration)
            return old
        }
        let delay = outgoing == nil ? 0 : Self.halfDuration
        var next = incoming
        next.presence *= Self.envelope((elapsed - delay) / Self.halfDuration)
        return next
    }

    /// Smooth endpoints avoid a flash at the zero-presence hand-off.
    static func envelope(_ progress: Double) -> Float {
        let x = min(1, max(0, progress))
        return Float(x * x * (3 - 2 * x))
    }
}
