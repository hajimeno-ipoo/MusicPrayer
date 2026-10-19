import AVFoundation
import Foundation
import NaturalLanguage
import OSLog
import Speech

protocol LyricTranscribing: Sendable {
    func transcribe(audioURL: URL, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken]
    func transcribe(audioBuffer: AVAudioPCMBuffer, startTime: Double, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken]
}

extension LyricTranscribing {
    func transcribe(audioBuffer: AVAudioPCMBuffer, startTime: Double = 0, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        throw LyricRecognitionError.unavailable
    }
}

enum LyricRecognitionError: Error, LocalizedError, Sendable {
    case unavailable
    case unknownLanguage
    case unsupportedLanguage(String)
    case modelNotInstalled
    case invalidAudioBuffer

    var errorDescription: String? {
        switch self {
        case .unavailable: return "このMacではAppleの音声認識を利用できません。"
        case .unknownLanguage: return "歌詞の言語を判定できませんでした。"
        case .unsupportedLanguage(let language): return "Appleの音声認識が歌詞の言語（\(language)）に対応していません。"
        case .modelNotInstalled: return "Appleの音声認識モデルを準備できませんでした。ネットワーク接続をご確認のうえ再試行してください。"
        case .invalidAudioBuffer: return "歌詞の音声認識に必要な音声データを取得できませんでした。"
        }
    }
}

/// Apple's on-device recognition accepts local files or captured PCM held in memory.
struct AppleLyricTranscriber: LyricTranscribing {
    private static let logger = Logger(subsystem: "com.hazimeno.MusicPrayer", category: "LyricRecognition")
    func transcribe(audioURL: URL, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        let prepared = try await prepare(sourceText: sourceText, status: status)
        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [prepared.transcriber])
        await status(.recognizing)
        let primary = try await recognize(file: file, transcriber: prepared.transcriber, analyzer: analyzer)
        return try await finish(primary, sourceText: sourceText, analysis: analysis,
                                language: prepared.language, audioURL: audioURL, status: status)
    }

    /// The buffer must use the original song's time scale; startTime is its song position.
    /// Captured Apple Music audio is never written to a temporary audio file.
    func transcribe(audioBuffer: AVAudioPCMBuffer, startTime: Double = 0, sourceText: String,
                    analysis: MusicAnalysis,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        guard audioBuffer.frameLength > 0, startTime.isFinite, startTime >= 0 else {
            throw LyricRecognitionError.invalidAudioBuffer
        }
        let prepared = try await prepare(sourceText: sourceText, status: status)
        let analyzer = SpeechAnalyzer(modules: [prepared.transcriber])
        await status(.recognizing)
        let inputs = try await sequence(audioBuffer: audioBuffer, startTime: startTime, modules: [prepared.transcriber])
        let tokens = try await recognize(analyzer: analyzer, analyze: {
            try await analyzer.analyzeSequence(inputs)
        }, collectResults: { try await collect(prepared.transcriber) })
        await status(.generating)
        return tokens
    }

    private func sequence(audioBuffer: AVAudioPCMBuffer, startTime: Double,
                          modules: [any SpeechModule]) async throws -> AsyncStream<AnalyzerInput> {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules, considering: audioBuffer.format) else {
            throw LyricRecognitionError.unavailable
        }
        let inputs = try Self.analyzerInputs(audioBuffer: audioBuffer, format: format, startTime: startTime)
        return AsyncStream { continuation in
            for input in inputs { continuation.yield(input) }
            continuation.finish()
        }
    }

    static func analyzerInputs(audioBuffer: AVAudioPCMBuffer, format: AVAudioFormat,
                               startTime: Double = 0) throws -> [AnalyzerInput] {
        try Task.checkCancellation()
        guard audioBuffer.frameLength > 0, audioBuffer.format.sampleRate.isFinite,
              audioBuffer.format.sampleRate > 0, startTime.isFinite, startTime >= 0,
              startTime * audioBuffer.format.sampleRate < Double(Int64.max) else {
            throw LyricRecognitionError.invalidAudioBuffer
        }
        let converter = AnalyzerInputConverter(analyzerFormat: format)
        let origin = AVAudioTime(sampleTime: AVAudioFramePosition((startTime * audioBuffer.format.sampleRate).rounded()),
                                 atRate: audioBuffer.format.sampleRate)
        var inputs: [AnalyzerInput] = []
        var offset = 0
        let source = UnsafeMutableAudioBufferListPointer(audioBuffer.mutableAudioBufferList)
        while offset < Int(audioBuffer.frameLength) {
            try Task.checkCancellation()
            let count = min(4096, Int(audioBuffer.frameLength) - offset)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: audioBuffer.format, frameCapacity: AVAudioFrameCount(count)) else {
                throw LyricRecognitionError.invalidAudioBuffer
            }
            chunk.frameLength = AVAudioFrameCount(count)
            let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for index in source.indices {
                let bytesPerFrame = Int(source[index].mDataByteSize) / Int(audioBuffer.frameLength)
                guard let from = source[index].mData, let to = destination[index].mData else {
                    throw LyricRecognitionError.invalidAudioBuffer
                }
                memcpy(to, from.advanced(by: offset * bytesPerFrame), count * bytesPerFrame)
            }
            inputs += try converter.convert(chunk, at: offset == 0 ? origin : nil)
            offset += count
        }
        inputs += try converter.flush()
        guard !inputs.isEmpty else { throw LyricRecognitionError.invalidAudioBuffer }
        return inputs
    }

    private func prepare(sourceText: String,
                         status: @escaping @Sendable (LyricTimingState) async -> Void) async throws
        -> (transcriber: SpeechTranscriber, language: String) {
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
        return (transcriber, language.rawValue)
    }

    private func finish(_ primary: [RecognizedLyricToken], sourceText: String, analysis: MusicAnalysis,
                        language: String, audioURL: URL,
                        status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        guard !primary.isEmpty else { throw LyricAlignmentError.noRecognizedWords }
        Self.logger.info("Recognized language=\(language, privacy: .public) tokens=\(primary.count)")
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
                        primaryLanguage: language, transcription: primary, status: status)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    Self.logger.info("Bounded second-language recognition unavailable: \(String(describing: error), privacy: .public)")
                    throw original
                }
            default: throw original
            }
        }
    }

    private func recognize(analyzer: SpeechAnalyzer, analyze: () async throws -> CMTime?,
                           collectResults: @escaping () async throws -> [RecognizedLyricToken]) async throws -> [RecognizedLyricToken] {
        try await withTaskCancellationHandler {
            async let tokens = collectResults()
            do {
                if let last = try await analyze() {
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

    private func recognize(file: AVAudioFile, transcriber: SpeechTranscriber,
                           analyzer: SpeechAnalyzer) async throws -> [RecognizedLyricToken] {
        try await recognize(analyzer: analyzer, analyze: {
            try await analyzer.analyzeSequence(from: file)
        }, collectResults: { try await collect(transcriber) })
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
