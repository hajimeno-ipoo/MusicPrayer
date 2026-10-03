import AVFoundation
import CryptoKit
import Foundation
import MusicUnderstanding
import OSLog

actor MusicAnalyzer {
    static let cacheVersion = 3
    private static let log = Logger(subsystem: "com.hazimeno.MusicPrayer", category: "AnalysisCache")

    func analyze(url: URL, force: Bool = false) async throws -> MusicAnalysis {
        try Task.checkCancellation()
        let fingerprint = try Self.fingerprint(url)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.hazimeno.MusicPrayer/Analysis", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("\(fingerprint).json")
        if !force, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(MusicAnalysis.self, from: data),
           cached.version == Self.cacheVersion, cached.fingerprint == fingerprint,
           cached.duration.isFinite, cached.duration > 0, Self.hasResults(cached) {
            try Task.checkCancellation()
            return cached
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MusicUnderstandingError.invalidAsset }
        let session = try await MusicUnderstandingSession(asset: asset)
        let result = try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                return try await session.analyze(for: [.key, .rhythm, .structure, .pace, .instrumentActivity, .loudness])
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await session.cancel() }
        }
        try Task.checkCancellation()
        let analysis = Self.convert(result, duration: duration, fingerprint: fingerprint)
        guard Self.hasResults(analysis) else { throw AnalysisFailure.noResults }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(analysis).write(to: cacheURL, options: .atomic)
        } catch {
            // A cache is an optimization; keep actual successful analysis available this run.
            Self.log.error("Analysis cache write failed: \(error.localizedDescription, privacy: .public)")
        }
        return analysis
    }

    private enum AnalysisFailure: LocalizedError {
        case noResults
        var errorDescription: String? { "この曲の解析結果を取得できませんでした。再試行できます。" }
    }

    private static func hasResults(_ analysis: MusicAnalysis) -> Bool {
        analysis.bpm != nil || !analysis.beats.isEmpty || !analysis.bars.isEmpty ||
        !analysis.sections.isEmpty || !analysis.segments.isEmpty || !analysis.phrases.isEmpty ||
        !analysis.pace.isEmpty || !analysis.keys.isEmpty || !analysis.vocal.isEmpty ||
        !analysis.drums.isEmpty || !analysis.bass.isEmpty || !analysis.other.isEmpty ||
        !analysis.instrumentRanges.vocal.isEmpty || !analysis.instrumentRanges.drums.isEmpty ||
        !analysis.instrumentRanges.bass.isEmpty || !analysis.instrumentRanges.other.isEmpty ||
        !analysis.momentary.isEmpty || !analysis.shortTerm.isEmpty || analysis.integrated != nil || analysis.peak != nil
    }

    /// Hash the source bytes so a replaced file cannot reuse stale results.
    static func fingerprint(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func convert(_ result: MusicUnderstandingSession.SessionResult,
                                duration: Double, fingerprint: String) -> MusicAnalysis {
        var analysis = MusicAnalysis(version: cacheVersion, fingerprint: fingerprint, duration: duration)
        if let rhythm = result.rhythm {
            analysis.beats = rhythm.beats.map(\.seconds).filter { $0.isFinite && $0 >= 0 }.sorted()
            analysis.bars = rhythm.bars.map(\.seconds).filter { $0.isFinite && $0 >= 0 }.sorted()
            analysis.bpm = rhythm.beatsPerMinute.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        if let structure = result.structure {
            analysis.sections = structure.sections.compactMap(span).sorted { $0.start < $1.start }
            analysis.segments = structure.segments.compactMap(span).sorted { $0.start < $1.start }
            analysis.phrases = structure.phrases.compactMap(span).sorted { $0.start < $1.start }
        }
        if let pace = result.pace {
            analysis.pace = pace.ranges.compactMap {
                guard let range = span($0.range), $0.value.isFinite else { return nil }
                return PaceSpan(range: range, value: Float($0.value))
            }.sorted { $0.range.start < $1.range.start }
        }
        if let instruments = result.instrumentActivity {
            analysis.vocal = values(instruments.activity[.vocal] ?? [])
            analysis.drums = values(instruments.activity[.drum] ?? [])
            analysis.bass = values(instruments.activity[.bass] ?? [])
            analysis.other = values(instruments.activity[.other] ?? [])
            analysis.instrumentRanges = InstrumentRanges(
                vocal: (instruments.ranges[.vocal] ?? []).compactMap(span),
                drums: (instruments.ranges[.drum] ?? []).compactMap(span),
                bass: (instruments.ranges[.bass] ?? []).compactMap(span),
                other: (instruments.ranges[.other] ?? []).compactMap(span))
        }
        if let loudness = result.loudness {
            analysis.momentary = values(loudness.momentary)
            analysis.shortTerm = values(loudness.shortTerm)
            analysis.integrated = loudness.integrated.value.isFinite ? loudness.integrated.value : nil
            analysis.peak = values([loudness.peak]).first
        }
        if let keys = result.key {
            analysis.keys = keys.ranges.compactMap {
                guard let range = span($0.range) else { return nil }
                let (label, semitone) = tonic($0.value.tonic)
                let minor = $0.value.mode == .minor
                return KeySpan(range: range, label: "\(label) \(minor ? "minor" : "major")",
                               hue: (Float(semitone) - 5.5) * 0.006, minor: minor)
            }.sorted { $0.range.start < $1.range.start }
        }
        return analysis
    }

    private static func span(_ range: CMTimeRange) -> TimeSpan? {
        let start = range.start.seconds, duration = range.duration.seconds
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0 else { return nil }
        return TimeSpan(start: start, duration: duration)
    }

    private static func values(_ values: [MusicUnderstandingSession.TimedValue<Float>]) -> [TimeValue] {
        values.compactMap {
            guard $0.time.seconds.isFinite, $0.time.seconds >= 0, $0.value.isFinite else { return nil }
            return TimeValue(time: $0.time.seconds, value: $0.value)
        }.sorted { $0.time < $1.time }
    }

    /// Explicit enharmonic mapping; neither labels nor colors depend on debug descriptions.
    private static func tonic(_ tonic: KeyResult.Tonic) -> (String, Int) {
        switch tonic {
        case .c: return ("C", 0)
        case .cSharp: return ("C♯", 1)
        case .dFlat: return ("D♭", 1)
        case .d: return ("D", 2)
        case .dSharp: return ("D♯", 3)
        case .eFlat: return ("E♭", 3)
        case .e: return ("E", 4)
        case .f: return ("F", 5)
        case .fSharp: return ("F♯", 6)
        case .gFlat: return ("G♭", 6)
        case .g: return ("G", 7)
        case .gSharp: return ("G♯", 8)
        case .aFlat: return ("A♭", 8)
        case .a: return ("A", 9)
        case .aSharp: return ("A♯", 10)
        case .bFlat: return ("B♭", 10)
        case .b: return ("B", 11)
        }
    }
}
