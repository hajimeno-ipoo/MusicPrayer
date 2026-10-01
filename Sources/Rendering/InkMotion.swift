import Foundation
import simd

enum InkMotionKind: Int, CaseIterable {
    case suction, eruption, collision, breathing, sinking, split
}

struct InkMotionState {
    // suction, eruption, collision, breathing
    var weightsA: SIMD4<Float> = .zero
    // sinking, split / rejoin, activity, peak
    var weightsB: SIMD4<Float> = .zero

    static func focused(_ kind: InkMotionKind, activity: Float, peak: Float) -> Self {
        var state = Self()
        if kind.rawValue < 4 { state.weightsA[kind.rawValue] = 1 }
        else { state.weightsB[kind.rawValue - 4] = 1 }
        state.weightsB.z = activity
        state.weightsB.w = peak
        return state
    }
}

enum InkSpectrum {
    /// A copied 64-value payload; incomplete or invalid audio never reaches the GPU.
    static func values(_ source: [Float]) -> [Float] {
        (0..<64).map { index in
            guard index < source.count else { return 0 }
            return level(source[index])
        }
    }

    static func level(_ value: Float) -> Float {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// Phrase boundaries select a musical gesture. The music clock blends forces, including
/// while rendering at 120 Hz; duplicate paused frames do not advance the choreography.
struct InkMotionController {
    private var previousTime: Float?
    private var previousTrackID: UUID?
    private var previousPhrase: Float = 0
    private var previousSection: Float = 0
    private var previousTransition: Float = 0
    private var wasAnalyzed = false
    private(set) var selected: InkMotionKind = .suction
    private var state = InkMotionState()
    private var target = InkMotionState()

    mutating func update(frame: VisualFrame) -> InkMotionState {
        guard frame.time.isFinite else { return state }
        let delta = previousTime.map { frame.time - $0 } ?? 0
        let analyzed = frame.hasAnalysis > 0.5
        let reset = previousTime == nil || delta < -0.00001 || delta >= 0.2
            || previousTrackID != frame.trackID
        // A new phrase restarts its progress; section changes also select a fresh gesture.
        let boundary = frame.phraseProgress + 0.05 < previousPhrase
            || frame.sectionProgress + 0.05 < previousSection
            || frame.sectionTransition > previousTransition + 0.15
        let scores = Self.scores(frame)
        if reset || (analyzed && (!wasAnalyzed || boundary)) {
            var choices = scores
            // Repeated phrases retain their strongest musical influences but give a second
            // gesture room to appear, instead of holding one upward plume throughout a song.
            if !reset && boundary { choices[selected.rawValue] *= 0.55 }
            selected = InkMotionKind(rawValue: choices.indices.max { choices[$0] < choices[$1] }!)!
            target = .focused(selected, activity: 0, peak: 0)
            if reset { state = target }
        } else if !analyzed {
            // Without phrase timing, the available live bands directly mix the six forces.
            let total = max(0.001, scores.reduce(0, +))
            target.weightsA = SIMD4(scores[0], scores[1], scores[2], scores[3]) / total
            target.weightsB.x = scores[4] / total
            target.weightsB.y = scores[5] / total
        }
        if delta > 0.00001 && !reset {
            let blend = 1 - exp(-delta / 0.65)
            state.weightsA += (target.weightsA - state.weightsA) * blend
            state.weightsB.x += (target.weightsB.x - state.weightsB.x) * blend
            state.weightsB.y += (target.weightsB.y - state.weightsB.y) * blend
        }
        let level = InkSpectrum.level
        state.weightsB.z = level(max(frame.rms, frame.density * level(frame.hasAnalysis) * 0.6)
            + frame.pace * level(frame.hasAnalysis) * 0.25)
        state.weightsB.w = level(frame.peak)
        previousTime = frame.time
        previousTrackID = frame.trackID
        previousPhrase = level(frame.phraseProgress)
        previousSection = level(frame.sectionProgress)
        previousTransition = level(frame.sectionTransition)
        wasAnalyzed = analyzed
        return state
    }

    private static func scores(_ f: VisualFrame) -> [Float] {
        let l = InkSpectrum.level
        let a = l(f.hasAnalysis)
        return [
            0.1 + l(f.mid) * 0.9 + l(f.other) * a * 0.5,
            0.1 + l(f.vocal) * a * 1.2 + l(f.peak) * 0.35,
            0.1 + l(f.drums) * a * 1.2 + l(f.beat) * a * 0.35,
            0.1 + max(l(f.bass), l(f.bassInstrument) * a) * 1.25,
            0.1 + (1 - l(f.rms)) * 0.65 * (1 - l(f.density) * a * 0.5),
            0.1 + l(f.treble) * 1.25
        ]
    }
}
