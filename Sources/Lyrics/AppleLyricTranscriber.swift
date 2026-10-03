import AVFoundation
import Foundation
import NaturalLanguage
import OSLog
import Speech

protocol LyricTranscribing: Sendable {
    func transcribe(audioURL: URL, sourceText: String,
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
        return try await withTaskCancellationHandler {
            async let tokens = collect(transcriber)
            do {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else { await analyzer.cancelAndFinishNow() }
                let result = try await tokens
                try Task.checkCancellation()
                guard !result.isEmpty else { throw LyricAlignmentError.noRecognizedWords }
                Self.logger.info("Recognized locale=\(locale.identifier, privacy: .public) tokens=\(result.count)")
                return result
            } catch {
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
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
                guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
                tokens.append(RecognizedLyricToken(text: String(result.text[run.range].characters),
                                                   start: start, end: end,
                                                   confidence: run.transcriptionConfidence ?? 0))
            }
        }
        return tokens
    }
}
