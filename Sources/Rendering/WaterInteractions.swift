import Foundation

struct WaterPulse: Sendable, Equatable {
    var position: SIMD2<Float>
    var strength: Float
    var radius: Float
}

/// The UI adds impulses; the render thread consumes them once before the next water step.
final class WaterInteractions: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var pulses: [WaterPulse] = []
    private var waterHorizon: Float = 0.66

    init(capacity: Int = 32) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var horizon: Float {
        get {
            lock.lock(); defer { lock.unlock() }
            return waterHorizon
        }
        set {
            guard newValue.isFinite else { return }
            lock.lock(); defer { lock.unlock() }
            waterHorizon = min(0.95, max(0.05, newValue))
        }
    }

    /// Screen UV starts at the top left; the GPU water texture starts at the horizon.
    @discardableResult
    func enqueue(screenUV: SIMD2<Float>, strength: Float = 0.8, radius: Float = 0.025) -> Bool {
        guard screenUV.x.isFinite, screenUV.y.isFinite, strength.isFinite, radius.isFinite,
              (0...1).contains(screenUV.x), (0...1).contains(screenUV.y), strength > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard screenUV.y >= waterHorizon else { return false }
        let position = SIMD2<Float>(screenUV.x, (screenUV.y - waterHorizon) / (1 - waterHorizon))
        let pulse = WaterPulse(position: position, strength: min(1, strength), radius: min(0.1, max(0.005, radius)))
        // Preserve the most recent finger/mouse path if drawing temporarily falls behind input.
        if pulses.count == capacity { pulses.removeFirst() }
        pulses.append(pulse)
        return true
    }

    func drain() -> [WaterPulse] {
        lock.lock(); defer { lock.unlock() }
        let result = pulses
        pulses.removeAll(keepingCapacity: true)
        return result
    }
}
