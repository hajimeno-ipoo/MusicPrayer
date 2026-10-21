import AVFoundation
import XCTest
@testable import MusicPrayer

final class AppleMusicLyricTimingTests: XCTestCase {
    private let song = AppleMusicSong(id: "971956345", title: "Test", artist: "", album: "", duration: 30)

    private func analysis() -> MusicAnalysis {
        MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: song.duration,
            sections: [TimeSpan(start: 0, duration: song.duration)],
            segments: [TimeSpan(start: 0, duration: song.duration)],
            phrases: [TimeSpan(start: 0, duration: song.duration)])
    }

    private func lyrics() throws -> AppleMusicLyrics {
        try AppleMusicLyricsParser.parse(ttml: """
        <tt><body><p begin="1s" end="8s">AB</p><p begin="9s" end="14s">CD</p></body></tt>
        """, songID: song.id)
    }

    private func result() throws -> AppleMusicLyricTiming {
        let text = try lyrics().text
        let timeline = try LyricAligner.align(sourceText: text,
            analysis: AppleMusicLyricTiming.alignmentAnalysis(analysis(), songID: song.id),
            transcription: [
                RecognizedLyricToken(text: "A", start: 2, end: 2.4, confidence: 1),
                RecognizedLyricToken(text: "B", start: 3.5, end: 5, confidence: 1),
                RecognizedLyricToken(text: "C", start: 10, end: 10.8, confidence: 1),
                RecognizedLyricToken(text: "D", start: 12, end: 12.4, confidence: 1)
            ])
        return AppleMusicLyricTiming(songID: song.id, duration: song.duration,
                                    sourceText: text, timeline: timeline)
    }

    func testCompletionDistinguishesUnknownEmptyLyricsUnpublishedLyricsAndNativeTiming() throws {
        var timing = AppleMusicLyricTiming(songID: song.id, duration: song.duration,
            sourceText: "", timeline: nil, errorMessage: nil)
        XCTAssertEqual(timing.completion, .missingLyrics)
        timing.hasLyrics = false
        XCTAssertEqual(timing.completion, .noLyrics)
        let native = try AppleMusicLyricsParser.parse(ttml: """
        <tt><body><p begin="1s" end="4s"><span begin="1s" end="2s">A</span><span begin="3s" end="4s">B</span></p></body></tt>
        """, songID: song.id)
        XCTAssertTrue(native.lines.allSatisfy(\.hasValidCharacterTimings))
        timing.sourceText = native.text
        timing.hasLyrics = true
        XCTAssertEqual(timing.completion, .missingLyrics)
        timing.usesOfficialWordTimings = true
        XCTAssertEqual(timing.completion, .complete)
        timing.errorMessage = "歌詞を取得できませんでした。"
        XCTAssertEqual(timing.completion, .failedLyrics)
    }

    func testRecognitionKeepsUnevenWordIntervalsAndOriginalMusicAnalysis() throws {
        let music = analysis()
        let applied = try XCTUnwrap(result().applying(to: try lyrics(), song: song, analysis: music))
        XCTAssertEqual(applied.lines.map(\.start), [2, 10])
        XCTAssertEqual(applied.lines.map(\.end), [5, 12.4])
        XCTAssertEqual(applied.lines[0].characterTimings, [
            LyricCharacterTiming(start: 2, end: 2.4), LyricCharacterTiming(start: 3.5, end: 5)
        ])
        XCTAssertEqual(applied.text, try lyrics().text)
        XCTAssertEqual(music.fingerprint, "appleMusic:" + song.id)
    }

    func testAnotherSongOrChangedLyricsCannotUseSavedTiming() throws {
        let timing = try result()
        var anotherSong = song
        anotherSong.id = "294796280"
        XCTAssertFalse(timing.isCurrent(for: anotherSong))
        XCTAssertNil(timing.applying(to: try lyrics(), song: anotherSong, analysis: analysis()))
        var changed = try lyrics()
        changed.text += "E"
        XCTAssertNil(timing.applying(to: changed, song: song, analysis: analysis()))
        changed = try lyrics()
        changed.songID = anotherSong.id
        XCTAssertNil(timing.applying(to: changed, song: song, analysis: analysis()))
    }

    func testDifferentAnalysisAndDamagedTimelineAreRejected() throws {
        let timing = try result()
        var changed = analysis()
        changed.bpm = 99
        XCTAssertNil(timing.applying(to: try lyrics(), song: song, analysis: changed))
        changed = analysis()
        changed.fingerprint = "appleMusic:294796280"
        XCTAssertNil(timing.applying(to: try lyrics(), song: song, analysis: changed))
        var damaged = timing
        damaged.timeline?.lines[0].characterTimings[0].end = 99
        XCTAssertNil(damaged.applying(to: try lyrics(), song: song, analysis: analysis()))
        damaged = timing
        damaged.timeline?.sourceText = "other"
        XCTAssertNil(damaged.applying(to: try lyrics(), song: song, analysis: analysis()))
    }

    func testVersionDurationAndFailureCannotBeApplied() throws {
        let timing = try result()
        var stale = timing
        stale.version += 1
        XCTAssertFalse(stale.isCurrent(for: song))
        stale = timing
        stale.alignmentVersion -= 1
        XCTAssertFalse(stale.isCurrent(for: song))
        stale = timing
        stale.duration = .nan
        XCTAssertFalse(stale.isCurrent(for: song))
        stale = timing
        stale.duration += 2
        XCTAssertFalse(stale.isCurrent(for: song))
        stale = timing
        stale.errorMessage = "認識に失敗しました。"
        XCTAssertNil(stale.applying(to: try lyrics(), song: song, analysis: analysis()))
        stale = timing
        stale.timeline = nil
        XCTAssertNil(stale.applying(to: try lyrics(), song: song, analysis: analysis()))
    }

    func testNativeWordTimesHavePriority() throws {
        var native = try lyrics()
        for index in native.lines.indices {
            native.lines[index].characterTimings = native.lines[index].text.map { _ in
                LyricCharacterTiming(start: native.lines[index].start, end: native.lines[index].end)
            }
        }
        XCTAssertTrue(native.lines.allSatisfy(\.hasValidCharacterTimings))
        XCTAssertNil(try result().applying(to: native, song: song, analysis: analysis()))
    }

    func testDerivedResultRoundTripsWithoutLosingRecognitionTimes() throws {
        let encoded = try JSONEncoder().encode(result())
        let decoded = try JSONDecoder().decode(AppleMusicLyricTiming.self, from: encoded)
        let applied = try XCTUnwrap(decoded.applying(to: try lyrics(), song: song, analysis: analysis()))
        XCTAssertEqual(applied.lines, try result().timeline?.lines)
        XCTAssertEqual(decoded.completion, .complete)
    }

    func testInvalidatingStaleLyricTimingKeepsSavedMusicAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        try await cache.retainSongs([song.id])
        let issuedTicket = await cache.ticket(for: song.id)
        let ticket = try XCTUnwrap(issuedTicket)
        let original = analysis()
        _ = try await cache.save(original, id: song.id, ticket: ticket)
        _ = try await cache.saveLyricTiming(result(), ticket: ticket)
        var changed = original
        changed.bpm = 99
        _ = try await cache.save(changed, id: song.id, ticket: ticket)
        let stale = await cache.loadLyricTiming(for: song)
        XCTAssertNil(stale?.applying(to: try lyrics(), song: song, analysis: changed))
        try await cache.invalidateLyricTiming(for: song)
        let removed = await cache.loadLyricTiming(for: song)
        let kept = await cache.load(id: song.id, duration: song.duration)
        XCTAssertNil(removed)
        XCTAssertEqual(kept?.bpm, 99)
        XCTAssertEqual(kept?.fingerprint, original.fingerprint)
        XCTAssertEqual(kept?.duration, original.duration)
    }

    func testGeneratePassesCapturedPCMOriginAndLyricsToRecognition() async throws {
        let buffer = try pcm()
        let timing = try result()
        let speech = timing.timeline!.lines.flatMap { line in
            zip(line.text, line.characterTimings).map { character, interval in
                RecognizedLyricToken(text: String(character), start: interval.start,
                                     end: interval.end, confidence: 1)
            }
        }
        let transcriber = PCMTranscriberStub(tokens: speech)
        let generated = try await AppleMusicLyricTiming.generate(lyrics: lyrics(), song: song,
            analysis: analysis(), audioBuffer: buffer, startTime: 1.25, transcriber: transcriber)
        let calls = await transcriber.calls
        XCTAssertFalse(calls.isEmpty)
        for call in calls {
            XCTAssertEqual(call.startTime, 1.25)
            XCTAssertEqual(call.frames, buffer.frameLength)
            XCTAssertEqual(call.sampleRate, buffer.format.sampleRate)
            XCTAssertEqual(call.firstSample, buffer.floatChannelData![0][0])
            XCTAssertEqual(call.sourceText, try lyrics().text)
            XCTAssertEqual(call.fingerprint, LyricHash.text("appleMusic:" + song.id))
        }
        let applied = try XCTUnwrap(generated.applying(to: lyrics(), song: song, analysis: analysis()))
        XCTAssertEqual(applied.lines.map(\.start), [1, 9])
        XCTAssertEqual(applied.lines.map(\.end), [8, 14])
        XCTAssertEqual(applied.lines.map(\.characterTimings), timing.timeline?.lines.map(\.characterTimings))
        XCTAssertNil(generated.errorMessage)
        XCTAssertEqual(generated.completion, .complete)
    }

    func testMixedLyricsRecognizeBothLanguagesAndKeepEachLanguagesRealWordTimes() async throws {
        let fixture = try mixedRecognition()
        let transcriber = PCMTranscriberStub(languageTokens: ["ja": fixture.japanese, "en": fixture.english])
        let generated = try await AppleMusicLyricTiming.generate(lyrics: fixture.source, song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        let calls = await transcriber.calls
        XCTAssertTrue(calls.contains { $0.language == "en" })
        XCTAssertTrue(calls.contains { $0.language == "ja" })
        let applied = try XCTUnwrap(generated.applying(to: fixture.source, song: song, analysis: analysis()))
        XCTAssertEqual(applied.text, fixture.source.text)
        XCTAssertEqual(applied.languages, ["en"])
        XCTAssertEqual(applied.lines.map(\.start), [1, 9])
        XCTAssertEqual(applied.lines.map(\.end), [8, 20])
        XCTAssertEqual(applied.lines[0].characterTimings, fixture.japanese.map {
            LyricCharacterTiming(start: $0.start, end: $0.end)
        })
        XCTAssertTrue(applied.lines[1].hasValidCharacterTimings)
        XCTAssertEqual(applied.lines[1].characterTimings[0], LyricCharacterTiming(start: 10, end: 10.8))
        XCTAssertEqual(applied.lines[1].characterTimings[7], LyricCharacterTiming(start: 11.5, end: 12.9))
        XCTAssertEqual(applied.lines[1].characterTimings.last, LyricCharacterTiming(start: 16, end: 16.3))
        XCTAssertNil(generated.errorMessage)
    }

    func testOneLanguageFailureKeepsAnotherLanguagesRecognizedRowAndOfficialText() async throws {
        let fixture = try mixedRecognition()
        let transcriber = PCMTranscriberStub(languageTokens: ["ja": fixture.japanese],
                                             languageFailures: ["en": .recognition])
        let generated = try await AppleMusicLyricTiming.generate(lyrics: fixture.source, song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        let calls = await transcriber.calls
        XCTAssertTrue(calls.contains { $0.language == "en" })
        XCTAssertTrue(calls.contains { $0.language == "ja" })
        let applied = try XCTUnwrap(generated.applying(to: fixture.source, song: song, analysis: analysis()))
        XCTAssertEqual(applied.text, fixture.source.text)
        XCTAssertEqual(applied.lines.map(\.start), fixture.source.lines.map(\.start))
        XCTAssertEqual(applied.lines.map(\.end), fixture.source.lines.map(\.end))
        XCTAssertTrue(applied.lines[0].hasValidCharacterTimings)
        XCTAssertEqual(applied.lines[1], fixture.source.lines[1])
        XCTAssertNil(generated.errorMessage)
    }

    func testInlineKoreanAndEnglishKeepBothRecognitionsWhenAnotherKoreanRowIsMissing() async throws {
        let source = try AppleMusicLyricsParser.parse(ttml: """
        <tt xml:lang="en"><body><p begin="9s" end="19s">별빛아래 summer moonlight 마음이빛나요</p><p begin="20s" end="25s">새벽이와요</p></body></tt>
        """, songID: song.id)
        let korean = [
            RecognizedLyricToken(text: "별빛아래", start: 10, end: 12, confidence: 1),
            RecognizedLyricToken(text: "썸머문라이트", start: 14, end: 15, confidence: 1),
            RecognizedLyricToken(text: "마음이빛나요", start: 16, end: 18, confidence: 1)
        ]
        let english = [
            RecognizedLyricToken(text: "summer", start: 13, end: 14, confidence: 1),
            RecognizedLyricToken(text: "moonlight", start: 14, end: 15.5, confidence: 1)
        ]
        let transcriber = PCMTranscriberStub(languageTokens: ["ko": korean, "en": english])
        let generated = try await AppleMusicLyricTiming.generate(lyrics: source, song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        let calls = await transcriber.calls
        XCTAssertTrue(calls.contains { $0.language == "ko" })
        XCTAssertTrue(calls.contains { $0.language == "en" })
        let applied = try XCTUnwrap(generated.applying(to: source, song: song, analysis: analysis()))
        XCTAssertEqual(applied.text, source.text)
        XCTAssertEqual(applied.lines.map(\.start), [9, 20])
        XCTAssertEqual(applied.lines.map(\.end), [19, 25])
        let mixed = applied.lines[0]
        XCTAssertTrue(mixed.hasValidCharacterTimings)
        guard mixed.hasValidCharacterTimings else { return }
        XCTAssertEqual(mixed.characterTimings.first, LyricCharacterTiming(start: 10, end: 12))
        XCTAssertEqual(mixed.characterTimings[5], LyricCharacterTiming(start: 13, end: 14))
        XCTAssertEqual(mixed.characterTimings[12], LyricCharacterTiming(start: 14, end: 15.5))
        XCTAssertEqual(mixed.characterTimings.last, LyricCharacterTiming(start: 16, end: 18))
        XCTAssertEqual(applied.lines[1], source.lines[1])
        XCTAssertNil(generated.errorMessage)
    }

    func testUnrecognizedRowDoesNotDiscardAnotherRowsTimingOrOfficialIntervals() async throws {
        let source = try lyrics()
        let transcriber = PCMTranscriberStub(tokens: [
            RecognizedLyricToken(text: "A", start: 2, end: 2.4, confidence: 1),
            RecognizedLyricToken(text: "B", start: 3.5, end: 5, confidence: 1)
        ])
        let generated = try await AppleMusicLyricTiming.generate(lyrics: source, song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        let applied = try XCTUnwrap(generated.applying(to: source, song: song, analysis: analysis()))
        XCTAssertTrue(applied.lines[0].hasValidCharacterTimings)
        XCTAssertEqual(applied.lines[1], source.lines[1])
        XCTAssertEqual(applied.lines.map(\.start), source.lines.map(\.start))
        XCTAssertEqual(applied.lines.map(\.end), source.lines.map(\.end))
        XCTAssertNil(generated.errorMessage)
        XCTAssertEqual(generated.completion, .partialLyrics(recognized: 1, total: 2))
        var damaged = generated
        damaged.derivedLines?[0].start = 0
        XCTAssertNil(damaged.applying(to: source, song: song, analysis: analysis()))
        damaged = generated
        damaged.analysisDigest = nil
        XCTAssertNil(damaged.applying(to: source, song: song, analysis: analysis()))
        var changed = analysis()
        changed.bpm = 99
        XCTAssertNil(generated.applying(to: source, song: song, analysis: changed))
    }

    func testRepeatedTextUsesItsOfficialOccurrenceAndPreservesNativeWordTimes() throws {
        let source = try AppleMusicLyricsParser.parse(ttml: """
        <tt><body><p begin="1s" end="5s">AB</p><p begin="9s" end="14s">AB</p><p begin="15s" end="18s"><span begin="16s" end="17s">CD</span></p></body></tt>
        """, songID: song.id)
        let tokens = [
            RecognizedLyricToken(text: "AB", start: 2, end: 4, confidence: 1),
            RecognizedLyricToken(text: "AB", start: 10, end: 12, confidence: 1)
        ]
        let result = try AppleMusicLyricTiming.recognizedLines(source.lines,
            analysis: AppleMusicLyricTiming.alignmentAnalysis(analysis(), songID: song.id),
            recognitions: [(language: "en", tokens: tokens)])
        XCTAssertEqual(result[0].characterTimings.first?.start, 2)
        XCTAssertEqual(result[1].characterTimings.first?.start, 10)
        XCTAssertEqual(result[2], source.lines[2])
    }

    func testGeneratePreservesRecognitionFailureWithoutEstimatedTiming() async throws {
        let transcriber = PCMTranscriberStub(failure: .recognition)
        let generated = try await AppleMusicLyricTiming.generate(lyrics: lyrics(), song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        XCTAssertNil(generated.timeline)
        XCTAssertEqual(generated.errorMessage, PCMTranscriberStub.Failure.recognition.localizedDescription)
        XCTAssertNil(generated.applying(to: try lyrics(), song: song, analysis: analysis()))
        XCTAssertEqual(generated.completion, .failedLyrics)
    }

    func testNoRecognizedOfficialRowsRemainUnmatchedInsteadOfComplete() async throws {
        let generated = try await AppleMusicLyricTiming.generate(lyrics: lyrics(), song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: PCMTranscriberStub())
        XCTAssertNil(generated.errorMessage)
        XCTAssertEqual(generated.derivedLines, try lyrics().lines)
        XCTAssertEqual(generated.completion, .unmatchedLyrics)
    }

    func testGenerateDoesNotRecognizeNativeWordTimesOrMissingLyrics() async throws {
        let native = try AppleMusicLyricsParser.parse(ttml: """
        <tt><body><p begin="1s" end="4s"><span begin="1s" end="2s">A</span><span begin="3s" end="4s">B</span></p></body></tt>
        """, songID: song.id)
        let transcriber = PCMTranscriberStub(failure: .recognition)
        let generated = try await AppleMusicLyricTiming.generate(lyrics: native, song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        let missing = try await AppleMusicLyricTiming.generate(lyrics: nil, song: song,
            analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
        let calls = await transcriber.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(generated.timeline)
        XCTAssertNil(generated.errorMessage)
        XCTAssertEqual(generated.sourceText, native.text)
        XCTAssertEqual(generated.completion, .complete)
        XCTAssertNil(missing.timeline)
        XCTAssertNil(missing.errorMessage)
        XCTAssertEqual(missing.completion, .noLyrics)
    }

    func testGeneratePropagatesCancellationInsteadOfSavingRecognitionFailure() async throws {
        let transcriber = PCMTranscriberStub(failure: .cancelled)
        do {
            _ = try await AppleMusicLyricTiming.generate(lyrics: lyrics(), song: song,
                analysis: analysis(), audioBuffer: pcm(), startTime: 0, transcriber: transcriber)
            XCTFail("Cancellation must not become a cached failure")
        } catch is CancellationError {
            // The worker owns cancellation and must be able to abandon this result.
        }
        let calls = await transcriber.calls
        XCTAssertEqual(calls.count, 1)
    }

    private func mixedRecognition() throws -> (source: AppleMusicLyrics,
                                               japanese: [RecognizedLyricToken], english: [RecognizedLyricToken]) {
        let source = try AppleMusicLyricsParser.parse(ttml: """
        <tt xml:lang="en"><body><p begin="1s" end="8s">静かな夜空に星が輝く</p><p begin="9s" end="20s">Summer moonlight shines above us</p></body></tt>
        """, songID: song.id)
        let japanese = source.lines[0].text.enumerated().map { index, character in
            let start = 2 + Double(index) * 0.4
            return RecognizedLyricToken(text: String(character), start: start,
                end: start + (index.isMultiple(of: 2) ? 0.1 : 0.2), confidence: 1)
        }
        let english = [
            RecognizedLyricToken(text: "Summer", start: 10, end: 10.8, confidence: 1),
            RecognizedLyricToken(text: "moonlight", start: 11.5, end: 12.9, confidence: 1),
            RecognizedLyricToken(text: "shines", start: 13.4, end: 14, confidence: 1),
            RecognizedLyricToken(text: "above", start: 14.8, end: 15.5, confidence: 1),
            RecognizedLyricToken(text: "us", start: 16, end: 16.3, confidence: 1)
        ]
        return (source, japanese, english)
    }

    private func pcm() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        buffer.floatChannelData![0].initialize(repeating: 0.42, count: 8)
        return buffer
    }
}

private actor PCMTranscriberStub: LyricTranscribing {
    struct Call: Sendable {
        var startTime: Double
        var frames: AVAudioFrameCount
        var sampleRate: Double
        var firstSample: Float
        var sourceText: String
        var language: String?
        var fingerprint: String
    }
    enum Failure: Error, LocalizedError {
        case recognition, cancelled, unexpectedFile
        var errorDescription: String? { "認識に失敗しました。" }
    }

    private let tokens: [RecognizedLyricToken]
    private let failure: Failure?
    private let languageTokens: [String: [RecognizedLyricToken]]
    private let languageFailures: [String: Failure]
    private(set) var calls: [Call] = []

    init(tokens: [RecognizedLyricToken] = [], failure: Failure? = nil,
         languageTokens: [String: [RecognizedLyricToken]] = [:], languageFailures: [String: Failure] = [:]) {
        self.tokens = tokens
        self.failure = failure
        self.languageTokens = languageTokens
        self.languageFailures = languageFailures
    }

    func transcribe(audioURL: URL, sourceText: String, analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        throw Failure.unexpectedFile
    }

    func transcribe(audioBuffer: AVAudioPCMBuffer, startTime: Double, sourceText: String,
                    language: String?, analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        calls.append(Call(startTime: startTime, frames: audioBuffer.frameLength,
            sampleRate: audioBuffer.format.sampleRate, firstSample: audioBuffer.floatChannelData![0][0],
            sourceText: sourceText, language: language, fingerprint: analysis.fingerprint))
        let failure = language.flatMap { languageFailures[$0] } ?? self.failure
        if case .cancelled? = failure { throw CancellationError() }
        if let failure { throw failure }
        return language.flatMap { languageTokens[$0] } ?? tokens
    }
}
