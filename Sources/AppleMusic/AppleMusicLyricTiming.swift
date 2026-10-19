import AVFoundation
import Foundation

/// Only derived lyric timings are persisted; streamed audio stays in memory.
struct AppleMusicLyricTiming: Codable, Sendable {
    static let currentVersion = 3

    var version = currentVersion
    var alignmentVersion = LyricVersions.alignment
    var songID: String
    var duration: Double
    var sourceText: String
    var timeline: LyricTimeline?
    var errorMessage: String?
    var derivedLines: [TimedLyricLine]?
    var analysisDigest: String?

    /// Reuse the same captured PCM and aligner as the music/local lyric paths.
    /// A failed recognition is retained as a failure, never estimated row progress.
    static func generate(lyrics: AppleMusicLyrics?, song: AppleMusicSong,
                         analysis: MusicAnalysis, audioBuffer: AVAudioPCMBuffer,
                         startTime: Double,
                         transcriber: any LyricTranscribing = AppleLyricTranscriber()) async throws -> Self {
        try Task.checkCancellation()
        var result = Self(songID: song.id, duration: song.duration, sourceText: lyrics?.text ?? "")
        guard let lyrics, !lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        do {
            guard lyrics.songID == song.id, analysis.fingerprint == "appleMusic:" + song.id else {
                throw LyricAlignmentError.inconsistentSavedData
            }
            guard lyrics.lines.isEmpty || !lyrics.lines.allSatisfy(\.hasValidCharacterTimings) else { return result }
            let music = alignmentAnalysis(analysis, songID: song.id)
            let transcription = try await transcriber.transcribe(audioBuffer: audioBuffer, startTime: startTime,
                sourceText: lyrics.text, analysis: music, status: { _ in })
            try Task.checkCancellation()
            let seed = result
            let alignment = Task.detached(priority: .utility) { () throws -> Self in
                var aligned = seed
                if lyrics.lines.isEmpty {
                    aligned.timeline = try LyricAligner.align(sourceText: lyrics.text, analysis: music, transcription: transcription)
                } else {
                    aligned.derivedLines = try recognizedLines(lyrics.lines, analysis: music, transcription: transcription)
                    aligned.analysisDigest = try LyricAligner.analysisDigest(music)
                }
                return aligned
            }
            result = try await withTaskCancellationHandler {
                try await alignment.value
            } onCancel: { alignment.cancel() }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            result.errorMessage = error.localizedDescription
        }
        return result
    }

    /// Official row intervals keep repeats at the correct singing occurrence.
    /// A row without a match keeps its official interval and remains uncoloured.
    static func recognizedLines(_ lines: [TimedLyricLine], analysis: MusicAnalysis,
                                transcription: [RecognizedLyricToken]) throws -> [TimedLyricLine] {
        try lines.map { source in
            try Task.checkCancellation()
            guard !source.hasValidCharacterTimings else { return source }
            let tokens = transcription.filter { $0.start >= source.start && $0.end <= source.end }
            do {
                let matched = try LyricAligner.align(sourceText: source.text, analysis: analysis, transcription: tokens)
                guard let line = matched.lines.first, matched.lines.count == 1 else { return source }
                var result = source
                result.characterTimings = line.characterTimings
                result.unrecognizedLeadingCharacters = line.unrecognizedLeadingCharacters
                result.confidence = line.confidence
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { return source }
        }
    }

    /// The existing aligner requires a SHA256 audio identity. Keep the music
    /// analysis's catalog identity unchanged outside lyric alignment.
    static func alignmentAnalysis(_ analysis: MusicAnalysis, songID: String) -> MusicAnalysis {
        var value = analysis
        value.fingerprint = LyricHash.text("appleMusic:" + songID)
        return value
    }

    func isCurrent(for song: AppleMusicSong) -> Bool {
        version == Self.currentVersion && alignmentVersion == LyricVersions.alignment &&
            songID == song.id && duration.isFinite && duration > 0 &&
            song.duration.isFinite && song.duration > 0 && abs(duration - song.duration) < 1
    }

    /// Never apply a recognized result to another catalog recording, lyric text,
    /// or analysis. Native word timestamps take priority over recognition.
    func applying(to lyrics: AppleMusicLyrics, song: AppleMusicSong,
                  analysis: MusicAnalysis) -> AppleMusicLyrics? {
        guard isCurrent(for: song), lyrics.songID == song.id,
              sourceText == lyrics.text, errorMessage == nil,
              analysis.fingerprint == "appleMusic:" + song.id,
              analysis.duration.isFinite, abs(analysis.duration - duration) < 1,
              lyrics.lines.isEmpty || !lyrics.lines.allSatisfy(\.hasValidCharacterTimings) else { return nil }
        let music = Self.alignmentAnalysis(analysis, songID: song.id)
        if let derivedLines {
            guard let expectedDigest = try? LyricAligner.analysisDigest(music), analysisDigest == expectedDigest,
                  derivedLines.count == lyrics.lines.count else { return nil }
            for (result, source) in zip(derivedLines, lyrics.lines) {
                guard result.id == source.id, result.ordinal == source.ordinal, result.text == source.text,
                      result.start == source.start, result.end == source.end, result.textWeight == source.textWeight else { return nil }
                guard result.characterTimings.isEmpty || result.hasValidCharacterTimings else { return nil }
                if source.hasValidCharacterTimings, result != source { return nil }
            }
            return AppleMusicLyrics(songID: lyrics.songID, text: lyrics.text, lines: derivedLines)
        }
        guard let timeline, timeline.sourceText == sourceText,
              (try? LyricAligner.validate(timeline,
                  analysis: music)) != nil else { return nil }
        return AppleMusicLyrics(songID: lyrics.songID, text: lyrics.text, lines: timeline.lines)
    }
}
