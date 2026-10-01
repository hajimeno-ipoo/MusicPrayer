import Foundation

enum SectionScenes {
    /// Scene composition comes from the measured section, never its ordinal number.
    /// Missing measurements use a neutral visual value and never enter the analysis model.
    static func make(_ analysis: MusicAnalysis) -> [SectionScene] {
        analysis.sections.map { section in
            let pace = rangeMean(analysis.pace, within: section).map { unit($0 / 180) } ?? 0.5
            let vocal = timeMean(analysis.vocal, within: section).map(unit) ?? 0.5
            let drums = timeMean(analysis.drums, within: section).map(unit) ?? 0.5
            let bass = timeMean(analysis.bass, within: section).map(unit) ?? 0.5
            let other = timeMean(analysis.other, within: section).map(unit) ?? 0.5
            let reference = analysis.integrated.map(Double.init) ?? -18
            let glow = timeMean(analysis.momentary, within: section)
                .map { unit(($0 - reference + 12) / 24) } ?? 0.5
            let density = timeMean(analysis.shortTerm, within: section)
                .map { unit(($0 - reference + 12) / 24) } ?? 0.5
            return SectionScene(
                separation: unit(0.45 * Double(pace) + 0.30 * Double(other) + 0.25 * Double(density)),
                thickness: unit(0.50 * Double(vocal) + 0.30 * Double(bass) + 0.20 * Double(density)),
                depth: unit(0.45 * Double(pace) + 0.35 * Double(bass) + 0.20 * Double(other)),
                glow: unit(0.65 * Double(glow) + 0.20 * Double(vocal) + 0.15 * Double(drums)),
                water: unit(0.50 * Double(bass) + 0.30 * Double(drums) + 0.20 * Double(pace)))
        }
    }

    private static func unit(_ value: Double) -> Float { Float(min(1, max(0, value))) }

    private static func rangeMean(_ values: [PaceSpan], within section: TimeSpan) -> Double? {
        guard section.duration > 0 else { return nil }
        var integral = 0.0, covered = 0.0
        for value in values {
            let overlap = min(section.end, value.range.end) - max(section.start, value.range.start)
            guard overlap > 0, value.value.isFinite else { continue }
            integral += Double(value.value) * overlap
            covered += overlap
        }
        // Unmeasured gaps contribute neither a fabricated zero nor extra duration.
        return covered > 0 ? integral / covered : nil
    }

    private static func timeMean(_ values: [TimeValue], within section: TimeSpan) -> Double? {
        guard values.count > 1, section.duration > 0 else { return nil }
        var integral = 0.0, covered = 0.0
        for index in 1..<values.count {
            let left = values[index - 1], right = values[index]
            guard left.time.isFinite, right.time.isFinite, left.value.isFinite,
                  right.value.isFinite, right.time > left.time else { continue }
            let start = max(section.start, left.time), end = min(section.end, right.time)
            guard end > start else { continue }
            let duration = right.time - left.time
            let change = Double(right.value - left.value)
            let first = Double(left.value) + change * (start - left.time) / duration
            let last = Double(left.value) + change * (end - left.time) / duration
            integral += (first + last) * 0.5 * (end - start)
            covered += end - start
        }
        // Integrate only between actual samples, with no pre/post-series extrapolation.
        return covered > 0 ? integral / covered : nil
    }
}
