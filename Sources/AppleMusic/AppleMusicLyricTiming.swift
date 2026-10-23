import AVFoundation
import Foundation

/// Only derived lyric timings are persisted; streamed audio stays in memory.
struct AppleMusicLyricTiming: Codable, Sendable {
    static let currentVersion = 4

    var version = currentVersion
    var alignmentVersion = LyricVersions.alignment
    var songID: String
    var duration: Double
    var sourceText: String
    var timeline: LyricTimeline?
    var errorMessage: String?
    var derivedLines: [TimedLyricLine]?
    var analysisDigest: String?
    /// False is saved only after Apple Music explicitly reports no lyrics.
    var hasLyrics: Bool?
    var usesOfficialWordTimings: Bool?
    var readings: LyricReadings? = nil

    var completion: AppleMusicPreanalysis.Completion {
        if errorMessage != nil { return .failedLyrics }
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return hasLyrics == false ? .noLyrics : .missingLyrics
        }
        if let derivedLines {
            let recognized = derivedLines.filter(\.hasValidCharacterTimings).count
            guard recognized > 0 else { return .unmatchedLyrics }
            return recognized == derivedLines.count ? .complete
                : .partialLyrics(recognized: recognized, total: derivedLines.count)
        }
        if let timeline {
            return !timeline.lines.isEmpty && timeline.lines.allSatisfy(\.hasValidCharacterTimings)
                ? .complete : .unmatchedLyrics
        }
        // Only a verified native-word-timing result skips recognition.
        return usesOfficialWordTimings == true ? .complete : .missingLyrics
    }

    /// Reuse the same captured PCM and aligner as the music/local lyric paths.
    /// A failed recognition is retained as a failure, never estimated row progress.
    static func generate(lyrics: AppleMusicLyrics?, song: AppleMusicSong,
                         analysis: MusicAnalysis, audioBuffer: AVAudioPCMBuffer,
                         startTime: Double,
                         transcriber: any LyricTranscribing = AppleLyricTranscriber()) async throws -> Self {
        try Task.checkCancellation()
        var result = Self(songID: song.id, duration: song.duration, sourceText: lyrics?.text ?? "",
                          hasLyrics: lyrics != nil)
        guard let lyrics else { return result }
        guard !lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result.errorMessage = "歌詞データの本文が空でした。"
            return result
        }
        do {
            guard lyrics.songID == song.id, analysis.fingerprint == "appleMusic:" + song.id else {
                throw LyricAlignmentError.inconsistentSavedData
            }
            guard lyrics.lines.isEmpty || !lyrics.lines.allSatisfy(\.hasValidCharacterTimings) else {
                result.usesOfficialWordTimings = true
                return result
            }
            let music = alignmentAnalysis(analysis, songID: song.id)
            let languages = LyricRecognitionRecovery.languageCandidates(sourceText: lyrics.text,
                suppliedLanguages: lyrics.languages)
            var recognitions: [(language: String, tokens: [RecognizedLyricToken])] = []
            var recognitionError: Error?
            for language in languages {
                try Task.checkCancellation()
                do {
                    let tokens = try await transcriber.transcribe(audioBuffer: audioBuffer, startTime: startTime,
                        sourceText: lyrics.text, language: language, analysis: music, status: { _ in })
                    recognitions.append((language, tokens))
                } catch is CancellationError { throw CancellationError() }
                catch { if recognitionError == nil { recognitionError = error } }
            }
            guard !recognitions.isEmpty else { throw recognitionError ?? LyricRecognitionError.unknownLanguage }
            try Task.checkCancellation()
            let seed = result
            let completed = recognitions
            let alignment = Task.detached(priority: .utility) { () throws -> Self in
                var aligned = seed
                if lyrics.lines.isEmpty {
                    let recognized = try LyricRecognitionRecovery.combinedAlternatives(sourceText: lyrics.text,
                        analysis: music, recognitions: completed)
                    let window = LyricRecognitionRecovery.Window(start: 0, end: music.duration,
                        sourceText: lyrics.text, language: "")
                    aligned.timeline = try LyricRecognitionRecovery.selection(window: window,
                        analysis: music, alternatives: recognized).timeline
                } else {
                    aligned.derivedLines = try recognizedLines(lyrics.lines, analysis: music, recognitions: completed)
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
                                recognitions: [(language: String, tokens: [RecognizedLyricToken])]) throws -> [TimedLyricLine] {
        try lines.map { source in
            try Task.checkCancellation()
            guard !source.hasValidCharacterTimings else { return source }
            do {
                let window = LyricRecognitionRecovery.Window(start: source.start, end: source.end,
                    sourceText: source.text, language: "")
                let alternatives = try LyricRecognitionRecovery.combinedAlternatives(sourceText: source.text,
                    analysis: analysis, recognitions: recognitions.map { recognition in
                        (recognition.language, recognition.tokens.filter { $0.start >= source.start && $0.end <= source.end })
                    })
                let matched = try LyricRecognitionRecovery.selection(window: window, analysis: analysis,
                    alternatives: alternatives).timeline
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

    /// Reading selection is independent of official or recognized word times.
    func applyingReadings(to lyrics: AppleMusicLyrics) -> AppleMusicLyrics? {
        guard songID == lyrics.songID, sourceText == lyrics.text,
              let readings, readings.isCurrent(sourceText: lyrics.text),
              readings.readings(for: lyrics.text) != nil,
              lyrics.lines.allSatisfy({ readings.readings(for: $0.text) != nil }) else { return nil }
        var result = lyrics
        result.readings = readings
        return result
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
            return AppleMusicLyrics(songID: lyrics.songID, text: lyrics.text, lines: derivedLines, languages: lyrics.languages)
        }
        guard let timeline, timeline.sourceText == sourceText,
              (try? LyricAligner.validate(timeline,
                  analysis: music)) != nil else { return nil }
        return AppleMusicLyrics(songID: lyrics.songID, text: lyrics.text, lines: timeline.lines, languages: lyrics.languages)
    }
}
