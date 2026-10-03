import Foundation

/// Structure owns the display frames; Speech and the source text own row times.
struct LyricMusicContext {
    let analysis: MusicAnalysis
    private static let epsilon = 1e-6

    func frames(for lines: [TimedLyricLine]) throws -> [LyricStructureFrame] {
        guard !analysis.sections.isEmpty, !analysis.segments.isEmpty, !analysis.phrases.isEmpty else {
            throw LyricAlignmentError.analysisUnavailable
        }
        let phrases = analysis.phrases.sorted { $0.start < $1.start }
        var result: [LyricStructureFrame] = []
        for phrase in phrases {
            try Task.checkCancellation()
            guard phrase.start.isFinite, phrase.end.isFinite, phrase.start >= 0,
                  phrase.duration > 0, phrase.end <= analysis.duration + Self.epsilon else {
                throw LyricAlignmentError.invalidFinalBoundaries
            }
            let sections = analysis.sections.indices.filter { contains(analysis.sections[$0], phrase) }
            let segments = analysis.segments.indices.filter { contains(analysis.segments[$0], phrase) }
            guard sections.count == 1, segments.count == 1 else {
                throw LyricAlignmentError.invalidFinalBoundaries
            }
            result.append(LyricStructureFrame(start: phrase.start, end: phrase.end,
                section: sections[0], segment: segments[0],
                lineOrdinals: lines.filter { overlap($0.start, $0.end, phrase.start, phrase.end) > 0 }.map(\.ordinal),
                support: support(in: phrase)))
        }
        guard Self.isConsistent(result, lines: lines) else {
            throw LyricAlignmentError.invalidFinalBoundaries
        }
        return result
    }

    /// Used when loading saved frames before the matching analysis is available.
    static func isConsistent(_ frames: [LyricStructureFrame], lines: [TimedLyricLine]) -> Bool {
        guard !frames.isEmpty else { return false }
        var previousEnd = 0.0
        for frame in frames {
            guard frame.start.isFinite, frame.end.isFinite, frame.start >= 0,
                  frame.end > frame.start, frame.start + epsilon >= previousEnd,
                  frame.section >= 0, frame.segment >= 0,
                  frame.lineOrdinals == Array(Set(frame.lineOrdinals)).sorted(),
                  frame.lineOrdinals.allSatisfy({ lines.indices.contains($0) }),
                  frame.support.activity.values.allSatisfy({ $0.isFinite }),
                  frame.support.pace.allSatisfy({ $0.isFinite }) else { return false }
            let expected = lines.filter { overlap($0.start, $0.end, frame.start, frame.end) > 0 }.map(\.ordinal)
            guard frame.lineOrdinals == expected else { return false }
            previousEnd = frame.end
        }
        // A row can cross several frames. Never discard a short overlap or fill a gap.
        return lines.allSatisfy { line in
            let covered = frames.reduce(0.0) {
                $0 + overlap(line.start, line.end, $1.start, $1.end)
            }
            return abs(covered - (line.end - line.start)) <= epsilon
        }
    }

    /// A long first Speech interval can include the pause before the first word.
    /// Trim only its colour interval at an observed vocal rise supported by loudness.
    /// Display frames and row times retain their original boundaries.
    func leadingColourStart(in range: LyricCharacterTiming) -> Double {
        let samples = analysis.vocal.filter {
            range.start <= $0.time && $0.time < range.end && $0.value.isFinite
        }
        guard let minimum = samples.indices.min(by: { samples[$0].value < samples[$1].value }),
              minimum > 0, minimum + 1 < samples.count,
              samples[minimum].value < samples[0].value,
              let rise = ((minimum + 1)..<samples.count).max(by: {
                  samples[$0].value - samples[$0 - 1].value < samples[$1].value - samples[$1 - 1].value
              }), samples[rise].value > samples[rise - 1].value else { return range.start }
        let onset = samples[rise].time
        let loudness = analysis.momentary.filter {
            range.start <= $0.time && $0.time <= range.end && $0.value.isFinite
        }
        guard let before = loudness.last(where: { $0.time <= onset }),
              loudness.contains(where: { $0.time > onset && $0.value > before.value }) else {
            return range.start
        }
        return onset
    }

    private func support(in range: TimeSpan) -> LyricFrameSupport {
        let instruments: [(String, [TimeSpan], [TimeValue])] = [
            ("vocal", analysis.instrumentRanges.vocal, analysis.vocal),
            ("drums", analysis.instrumentRanges.drums, analysis.drums),
            ("bass", analysis.instrumentRanges.bass, analysis.bass),
            ("other", analysis.instrumentRanges.other, analysis.other)]
        var presence: [String: Bool] = [:]
        var activity: [String: Float] = [:]
        for (name, ranges, values) in instruments {
            presence[name] = ranges.contains { overlap($0.start, $0.end, range.start, range.end) > 0 }
            activity[name] = mean(values, in: range)
        }
        return LyricFrameSupport(instrumentPresence: presence, activity: activity,
            beats: analysis.beats.filter { range.start <= $0 && $0 < range.end }.count,
            bars: analysis.bars.filter { range.start <= $0 && $0 < range.end }.count,
            bpm: analysis.bpm,
            pace: analysis.pace.filter { overlap($0.range.start, $0.range.end, range.start, range.end) > 0 }.map(\.value),
            keys: analysis.keys.filter { overlap($0.range.start, $0.range.end, range.start, range.end) > 0 }.map(\.label),
            momentary: mean(analysis.momentary, in: range), shortTerm: mean(analysis.shortTerm, in: range),
            integrated: analysis.integrated, peak: analysis.peak)
    }

    private func mean(_ values: [TimeValue], in range: TimeSpan) -> Float? {
        let selected = values.filter { range.start <= $0.time && $0.time < range.end && $0.value.isFinite }
        guard !selected.isEmpty else { return nil }
        return Float(selected.reduce(0.0) { $0 + Double($1.value) } / Double(selected.count))
    }

    private func contains(_ parent: TimeSpan, _ child: TimeSpan) -> Bool {
        parent.start <= child.start + Self.epsilon && parent.end >= child.end - Self.epsilon
    }

    private static func overlap(_ a: Double, _ b: Double, _ x: Double, _ y: Double) -> Double {
        max(0, min(b, y) - max(a, x))
    }

    private func overlap(_ a: Double, _ b: Double, _ x: Double, _ y: Double) -> Double {
        Self.overlap(a, b, x, y)
    }
}
