import Foundation

enum LyricVersions {
    static let schema = 1
    static let alignment = 5
}

enum LyricAlignmentMode: String, Codable, Sendable {
    case speechRecognition
}

/// Final Apple Speech text with the audio range supplied by the framework.
struct RecognizedLyricToken: Codable, Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double
}

struct LyricLine: Sendable, Equatable {
    var ordinal: Int
    var text: String
    var paragraphStart: Bool
    var textWeight: Double
}

struct TimedLyricLine: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var ordinal: Int
    var text: String
    var start: Double
    var end: Double
    var textWeight: Double
    var confidence: Float
    var characterTimings: [LyricCharacterTiming] = []

    var hasValidCharacterTimings: Bool {
        guard characterTimings.count == text.count, characterTimings.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= start &&
                $0.end >= $0.start && $0.end <= end
        }) else { return false }
        var previous = LyricCharacterTiming(start: start, end: start)
        for (character, timing) in zip(text, characterTimings) where LyricParser.characterWeight(character) > 0 {
            guard timing.start >= previous.start, timing.end >= previous.end else { return false }
            previous = timing
        }
        return true
    }
}

/// Original Character order; several characters can share one Speech interval.
struct LyricCharacterTiming: Codable, Sendable, Hashable {
    var start: Double
    var end: Double
}

/// One musical frame can refer to several rows; a row can continue across frames.
struct LyricStructureFrame: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var section: Int
    var segment: Int
    var lineOrdinals: [Int]
    var support: LyricFrameSupport
}

/// All analysis types describe the same frame, without inventing word timestamps.
struct LyricFrameSupport: Codable, Sendable, Equatable {
    var instrumentPresence: [String: Bool] = [:]
    var activity: [String: Float] = [:]
    var beats = 0
    var bars = 0
    var bpm: Float?
    var pace: [Float] = []
    var keys: [String] = []
    var momentary: Float?
    var shortTerm: Float?
    var integrated: Float?
    var peak: TimeValue?
}

struct LyricTimeline: Codable, Sendable, Equatable {
    var version: Int
    var analysisVersion: Int
    var analysisFingerprint: String
    var analysisDigest: String
    var sourceText: String
    var sourceTextHash: String
    var mode: LyricAlignmentMode
    var lines: [TimedLyricLine]
    var confidence: Float
    var frames: [LyricStructureFrame] = []
}

struct SavedLyrics: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var audioFingerprint: String
    var sourceText: String
    var sourceTextHash: String
    var timeline: LyricTimeline?
}

enum LyricTimingState: Sendable, Equatable {
    case unset
    case checkingAudio
    case waitingForAnalysis
    case preparingRecognition
    case recognizing
    case generating
    case generated(LyricAlignmentMode)
    case failed

    var title: String {
        switch self {
        case .unset: return "歌詞未設定"
        case .checkingAudio: return "音源を確認中"
        case .waitingForAnalysis: return "解析待ち"
        case .preparingRecognition: return "Appleの音声認識モデルを準備中"
        case .recognizing: return "音声から歌詞の時刻を確認中"
        case .generating: return "歌詞と認識結果を照合中"
        case .generated: return "生成済み"
        case .failed: return "タイミングを生成できませんでした"
        }
    }

    var isGenerating: Bool {
        switch self {
        case .preparingRecognition, .recognizing, .generating: return true
        default: return false
        }
    }
}

enum LyricAlignmentError: Error, LocalizedError, Sendable, Equatable {
    case analysisUnavailable
    case invalidDuration
    case noFeasiblePath
    case invalidFinalBoundaries
    case inconsistentSavedData
    case noRecognizedWords
    case unmatchedLine(Int)
    case ambiguousMatch

    var errorDescription: String? {
        switch self {
        case .analysisUnavailable: return "解析結果を取得できていません。"
        case .invalidDuration: return "曲の長さが有効ではありません。"
        case .noFeasiblePath: return "すべての行を配置できる候補がありません。"
        case .invalidFinalBoundaries: return "生成した行の境界が条件を満たしません。"
        case .inconsistentSavedData: return "保存データの整合性を確認できませんでした。"
        case .noRecognizedWords: return "音源から時刻付きの歌詞を認識できませんでした。"
        case .unmatchedLine(let ordinal): return "歌詞の\(ordinal + 1)行目を認識結果と照合できませんでした。本文や音源をご確認ください。"
        case .ambiguousMatch: return "歌詞の対応時刻が複数あり、特定できませんでした。"
        }
    }
}

enum LyricStoreError: Error, LocalizedError, Sendable, Equatable {
    case staleRequest
    case invalidFingerprint
    case inconsistentData

    var errorDescription: String? {
        switch self {
        case .staleRequest: return "新しい歌詞要求によって保存要求が失効しました。"
        case .invalidFingerprint: return "音源の識別情報が有効ではありません。"
        case .inconsistentData: return "歌詞の保存データを読み取れませんでした。"
        }
    }
}
