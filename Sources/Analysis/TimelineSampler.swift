import Foundation

enum TimelineSampler {
    static func sample(_ analysis: MusicAnalysis?, at time: Double) -> MusicalMoment {
        guard let analysis, time.isFinite, time >= 0, time < analysis.duration else { return MusicalMoment() }
        var moment = MusicalMoment()
        moment.bpm = analysis.bpm
        moment.integrated = analysis.integrated
        let beat = rhythm(analysis.beats, at: time, decay: 0.12)
        let bar = rhythm(analysis.bars, at: time, decay: 0.22)
        moment.beat = beat.impulse; moment.beatPhase = beat.phase
        moment.bar = bar.impulse; moment.barPhase = bar.phase
        if let index = containing(analysis.sections, at: time, range: { $0 }) {
            let section = analysis.sections[index]
            moment.section = index + 1
            moment.sectionProgress = progress(section, at: time)
            moment.sectionTransition = Float(max(0, 1 - (time - section.start) / 1.5))
        }
        if let index = containing(analysis.segments, at: time, range: { $0 }) {
            moment.segmentProgress = progress(analysis.segments[index], at: time)
        }
        if let index = containing(analysis.phrases, at: time, range: { $0 }) {
            moment.phraseProgress = progress(analysis.phrases[index], at: time)
        }
        if let index = containing(analysis.pace, at: time, range: { $0.range }) {
            moment.pace = analysis.pace[index].value
        }
        if let index = containing(analysis.keys, at: time, range: { $0.range }) {
            let key = analysis.keys[index]
            moment.key = key.label
            moment.hue = key.hue
            moment.modeBias = key.minor ? -1 : 1
        }
        moment.vocal = value(analysis.vocal, at: time)
        moment.drums = value(analysis.drums, at: time)
        moment.bass = value(analysis.bass, at: time)
        moment.other = value(analysis.other, at: time)
        moment.momentary = value(analysis.momentary, at: time)
        moment.shortTerm = value(analysis.shortTerm, at: time)
        // Peak is one measured event, not a level to hold for the rest of the song.
        if let peak = analysis.peak, time >= peak.time, time - peak.time < 0.12 {
            moment.peak = Float(exp(-(time - peak.time) / 0.04))
        }
        return moment
    }

    private static func rhythm(_ times: [Double], at time: Double, decay: Double) -> (impulse: Float, phase: Float) {
        let upper = upperBound(times, at: time, timeOf: { $0 })
        guard upper > 0 else { return (0, 0) }
        let previous = times[upper - 1]
        let elapsed = time - previous
        // An isolated/final beat still has an impulse, but no invented next-beat interval.
        let impulse = elapsed < decay * 4 ? Float(exp(-elapsed / decay)) : 0
        guard upper < times.count, times[upper] > previous else { return (impulse, 0) }
        return (impulse, Float(min(1, max(0, elapsed / (times[upper] - previous)))))
    }

    private static func value(_ values: [TimeValue], at time: Double) -> Float? {
        let upper = upperBound(values, at: time, timeOf: { $0.time })
        guard upper > 0 else { return nil }
        let previous = values[upper - 1]
        // Do not fabricate information outside the observed time series.
        guard upper < values.count else { return time == previous.time ? previous.value : nil }
        let next = values[upper]
        guard next.time > previous.time else { return previous.value }
        let fraction = Float((time - previous.time) / (next.time - previous.time))
        return previous.value + (next.value - previous.value) * fraction
    }

    private static func containing<T>(_ values: [T], at time: Double, range: (T) -> TimeSpan) -> Int? {
        let upper = upperBound(values, at: time, timeOf: { range($0).start })
        guard upper > 0 else { return nil }
        let index = upper - 1
        let span = range(values[index])
        return time < span.end ? index : nil
    }

    private static func progress(_ range: TimeSpan, at time: Double) -> Float {
        Float(min(1, max(0, (time - range.start) / range.duration)))
    }

    private static func upperBound<T>(_ values: [T], at time: Double, timeOf: (T) -> Double) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = low + (high - low) / 2
            if timeOf(values[middle]) <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
