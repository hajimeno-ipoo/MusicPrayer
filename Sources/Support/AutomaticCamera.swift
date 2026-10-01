import Foundation

enum CameraShot: Sendable, Equatable { case wide, water, ribbon }

struct CameraPose: Sendable, Equatable {
    var eye = SIMD3<Float>(0, 0, 6)
    var target = SIMD3<Float>(0, 0, 0)
    var horizon: Float = 0.66
    var shot: CameraShot = .wide
}

/// Music measurements select a view; the playback clock directs its continuous path.
/// No section numbers or guessed verse/chorus labels are used.
struct AutomaticCamera {
    private var pose = CameraPose()
    private var previousTime: Double?

    mutating func update(time: Double, moment: MusicalMoment, scene: SectionScene?, analyzed: Bool, dt: Float) -> CameraPose {
        let destination = Self.destination(moment: moment, scene: scene, analyzed: analyzed)
        defer { previousTime = time }
        // A paused clock also pauses the camera, including its settling movement.
        guard previousTime == nil || time != previousTime else { return pose }
        let amount = 1 - exp(-max(0, min(dt, 0.1)) / 1.6)
        pose.eye += (destination.eye - pose.eye) * amount
        pose.target += (destination.target - pose.target) * amount
        pose.horizon += (destination.horizon - pose.horizon) * amount
        pose.shot = destination.shot
        return pose
    }

    static func destination(moment: MusicalMoment, scene: SectionScene?, analyzed: Bool) -> CameraPose {
        guard analyzed else { return CameraPose() }
        let layout = scene ?? SectionScene()
        func unit(_ value: Float) -> Float { min(1, max(0, value)) }
        let vocal = unit(moment.vocal ?? 0)
        let progress = unit(moment.sectionProgress)
        let barAngle = unit(moment.barPhase) * 2 * Float.pi
        let sectionAngle = progress * 2 * Float.pi
        let survey = (1 - cos(sectionAngle)) * 0.5
        // Section means decide the main shot. The bar opens the view gently and
        // returns it without a discontinuity when the phase wraps from 1 to 0.
        let scores = SIMD3<Float>(
            0.18 + unit(layout.separation) + survey * 0.10 + (1 - cos(barAngle)) * 0.035,
            unit(layout.water) + (1 - unit(layout.thickness)) * 0.18,
            unit(layout.thickness) + vocal * 0.35)
        let weights = SIMD3<Float>(exp(scores.x * 5), exp(scores.y * 5), exp(scores.z * 5))
        let blend = weights / (weights.x + weights.y + weights.z)
        let shot: CameraShot = scores.x >= scores.y && scores.x >= scores.z ? .wide : (scores.y >= scores.z ? .water : .ribbon)
        let wideEye = SIMD3<Float>(0, 0.30, 6.80)
        let waterEye = SIMD3<Float>(0, -0.30, 5.85)
        let ribbonEye = SIMD3<Float>(0, 0.38, 5.75)
        var eye = wideEye * blend.x + waterEye * blend.y + ribbonEye * blend.z
        let sideways = (0.55 * blend.x + 0.32 * blend.y + 0.20 * blend.z) * (1 - vocal * 0.65)
        eye.x = sideways * (sin(sectionAngle) * 0.70 + sin(barAngle) * 0.30)
        eye.z = max(5.4, eye.z - vocal * 0.35 - (moment.bar * 0.04))
        let target = SIMD3<Float>(-eye.x * 0.12, 0.08 * blend.y + 0.18 * blend.z, 0)
        let horizon = 0.67 * blend.x + 0.58 * blend.y + 0.69 * blend.z
        return CameraPose(eye: eye, target: target, horizon: horizon, shot: shot)
    }
}
