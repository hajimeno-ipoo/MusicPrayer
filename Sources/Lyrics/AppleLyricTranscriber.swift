import AVFoundation
import Foundation
import NaturalLanguage
import OSLog
import Speech

protocol LyricTranscribing: Sendable {
    func transcribe(audioURL: URL, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken]
}

enum LyricRecognitionError: Error, LocalizedError, Sendable {
    case unavailable
    case unknownLanguage
    case unsupportedLanguage(String)
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "このMacではAppleの音声認識を利用できません。"
        case .unknownLanguage: return "歌詞の言語を判定できませんでした。"
        case .unsupportedLanguage(let language): return "Appleの音声認識が歌詞の言語（\(language)）に対応していません。"
        case .modelNotInstalled: return "Appleの音声認識モデルを準備できませんでした。ネットワーク接続をご確認のうえ再試行してください。"
        }
    }
}

/// File transcription uses Apple's on-device model; no audio is recorded or uploaded.
struct AppleLyricTranscriber: LyricTranscribing {
    private static let logger = Logger(subsystem: "com.hazimeno.MusicPrayer", category: "LyricRecognition")
    func transcribe(audioURL: URL, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw LyricRecognitionError.unavailable }
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(sourceText)
        guard let language = languageRecognizer.dominantLanguage else { throw LyricRecognitionError.unknownLanguage }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.rawValue)) else {
            throw LyricRecognitionError.unsupportedLanguage(language.rawValue)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        await status(.preparingRecognition)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw LyricRecognitionError.modelNotInstalled
        }
        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await status(.recognizing)
        let primary = try await recognize(file: file, transcriber: transcriber, analyzer: analyzer)
        guard !primary.isEmpty else { throw LyricAlignmentError.noRecognizedWords }
        Self.logger.info("Recognized locale=\(locale.identifier, privacy: .public) tokens=\(primary.count)")
        await status(.generating)
        // Recovery supports Latin-script fragments only. PlayerStore performs
        // final alignment, so do not repeat it when recovery cannot run.
        guard LyricRecognitionRecovery.containsLatinText(sourceText) else { return primary }
        do {
            _ = try LyricAligner.align(sourceText: sourceText, analysis: analysis, transcription: primary)
            return primary
        } catch let original as LyricAlignmentError {
            switch original {
            case .unmatchedLine, .ambiguousMatch:
                do {
                    return try await recover(audioURL: audioURL, sourceText: sourceText, analysis: analysis,
                        primaryLanguage: language.rawValue, transcription: primary, status: status)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    Self.logger.info("Bounded second-language recognition unavailable: \(String(describing: error), privacy: .public)")
                    throw original
                }
            default: throw original
            }
        }
    }

    private func recognize(file: AVAudioFile, transcriber: SpeechTranscriber,
                           analyzer: SpeechAnalyzer) async throws -> [RecognizedLyricToken] {
        try await withTaskCancellationHandler {
            async let tokens = collect(transcriber)
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else { await analyzer.cancelAndFinishNow() }
                let result = try await tokens
                try Task.checkCancellation()
                return result
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func recover(audioURL: URL, sourceText: String, analysis: MusicAnalysis,
                         primaryLanguage: String, transcription: [RecognizedLyricToken],
                         status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        let windows = try LyricRecognitionRecovery.plan(sourceText: sourceText, primaryLanguage: primaryLanguage,
            transcription: transcription, duration: analysis.duration)
        guard !windows.isEmpty else { throw LyricAlignmentError.noFeasiblePath }
        var prepared = Set<String>()
        var replacements: [[RecognizedLyricToken]] = []
        for window in windows {
            try Task.checkCancellation()
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: window.language)),
                  let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw LyricRecognitionError.unsupportedLanguage(window.language)
            }
            let speech = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            let dictation = DictationTranscriber(locale: dictationLocale, contentHints: [.atypicalSpeech],
                transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
            if prepared.insert(locale.identifier).inserted {
                await status(.preparingRecognition)
                let modules: [any SpeechModule] = [speech, dictation]
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await installation.downloadAndInstall()
                }
                try Task.checkCancellation()
                guard await AssetInventory.status(forModules: modules) == .installed else {
                    throw LyricRecognitionError.modelNotInstalled
                }
            }
            let clip = try makeClip(audioURL: audioURL, window: window)
            defer { try? FileManager.default.removeItem(at: clip.url) }
            await status(.recognizing)
            let speechAnalyzer = SpeechAnalyzer(modules: [speech])
            let speechTokens = try await recognize(file: AVAudioFile(forReading: clip.url),
                                                   transcriber: speech, analyzer: speechAnalyzer)
            let dictationAnalyzer = SpeechAnalyzer(modules: [dictation])
            let context = AnalysisContext()
            let words = window.sourceText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var hints = Set(words)
            for pair in zip(words, words.dropFirst()) { hints.insert(pair.0 + " " + pair.1) }
            context.contextualStrings[.general] = Array(hints.sorted().prefix(100))
            try await dictationAnalyzer.setContext(context)
            let dictationTokens = try await recognize(file: AVAudioFile(forReading: clip.url),
                                                      transcriber: dictation, analyzer: dictationAnalyzer)
            func global(_ tokens: [RecognizedLyricToken]) -> [RecognizedLyricToken] {
                tokens.map { RecognizedLyricToken(text: $0.text, start: clip.offset + $0.start,
                                                   end: clip.offset + $0.end, confidence: $0.confidence) }
            }
            let alternatives = [global(speechTokens), global(dictationTokens)]
            let selected = try LyricRecognitionRecovery.select(window: window, analysis: analysis,
                alternatives: alternatives)
            replacements.append(selected)
            Self.logger.info("Recovered locale=\(locale.identifier, privacy: .public) range=\(window.start)-\(window.end) tokens=\(selected.count)")
        }
        let result = try LyricRecognitionRecovery.merge(transcription, windows: windows, replacements: replacements)
        await status(.generating)
        _ = try LyricAligner.align(sourceText: sourceText, analysis: analysis, transcription: result)
        return result
    }

    private func makeClip(audioURL: URL, window: LyricRecognitionRecovery.Window) throws -> (url: URL, offset: Double) {
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        let first = Self.clipFrame(time: window.start, sampleRate: rate, isStart: true)
        let last = min(file.length, Self.clipFrame(time: window.end, sampleRate: rate, isStart: false))
        guard first >= 0, last > first else { throw LyricAlignmentError.invalidFinalBoundaries }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayer-Lyric-\(UUID()).wav")
        do {
            var settings = file.processingFormat.settings
            settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
            let writer = try AVAudioFile(forWriting: url, settings: settings)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else {
                throw LyricRecognitionError.unavailable
            }
            file.framePosition = first
            while file.framePosition < last {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(32_768, last - file.framePosition)))
                guard buffer.frameLength > 0 else { throw LyricAlignmentError.invalidFinalBoundaries }
                try writer.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return (url, Double(first) / rate)
    }

    static func clipFrame(time: Double, sampleRate: Double, isStart: Bool) -> AVAudioFramePosition {
        let frame = time * sampleRate
        let nearest = frame.rounded()
        // An exact native edge can acquire floating-point noise on conversion.
        // Use the same numerical tolerance as the native boundary validation;
        // genuine fractional samples still round inward, not beyond the window.
        if abs(frame - nearest) <= sampleRate * 1e-9 { return AVAudioFramePosition(nearest) }
        return AVAudioFramePosition(isStart ? ceil(frame) : floor(frame))
    }

    private func recognize(file: AVAudioFile, transcriber: DictationTranscriber,
                           analyzer: SpeechAnalyzer) async throws -> [RecognizedLyricToken] {
        try await withTaskCancellationHandler {
            let collector = Task {
                var tokens: [RecognizedLyricToken] = []
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    if result.isFinal { tokens += self.tokens(in: result.text) }
                }
                return tokens
            }
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else { await analyzer.cancelAndFinishNow() }
                let result = try await collector.value
                try Task.checkCancellation()
                return result
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func collect(_ transcriber: SpeechTranscriber) async throws -> [RecognizedLyricToken] {
        var tokens: [RecognizedLyricToken] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            tokens += self.tokens(in: result.text)
        }
        return tokens
    }

    private func tokens(in text: AttributedString) -> [RecognizedLyricToken] {
        var tokens: [RecognizedLyricToken] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            tokens.append(RecognizedLyricToken(text: String(text[run.range].characters),
                                               start: start, end: end,
                                               confidence: run.transcriptionConfidence ?? 0))
        }
        return tokens
    }
}
