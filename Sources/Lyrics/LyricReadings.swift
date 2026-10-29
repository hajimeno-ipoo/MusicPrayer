import Foundation

/// Character offsets in the unchanged display text, not UTF-16 offsets.
struct LyricReading: Codable, Sendable, Equatable {
    var start: Int
    var count: Int
    var salt: Int
}

struct LyricReadings: Codable, Sendable, Equatable {
    static let currentVersion = "rubifont-0.6.23-1"
    var version = currentVersion
    var sourceTextHash: String
    /// An empty array is a completed selection with no font override.
    var lines: [String: [LyricReading]]

    func isCurrent(sourceText: String) -> Bool {
        version == Self.currentVersion && sourceTextHash == LyricHash.text(sourceText) &&
        lines.allSatisfy { text, readings in
            readings.allSatisfy { $0.start >= 0 && $0.count > 0 &&
                $0.start <= text.count && $0.count <= text.count - $0.start && (1...15).contains($0.salt) }
        }
    }

    func readings(for text: String) -> [LyricReading]? { lines[text] }
}

/// Used during lyric preparation only. Rendering consumes the saved value above.
actor LyricReadingResolver {
    static let shared = LyricReadingResolver()

    private struct ReadingLists: Decodable {
        var kanji: [String: [String]]
        var words: [String: [String]]
        var lone: [String: String]
        var salt: Bool
    }

    private struct ContextReading: Decodable {
        var text: String
        var selections: [LyricReading]
        var numberBoundary: Bool?
    }

    private var lists: ReadingLists?
    private var contexts: [ContextReading] = []
    private var pairs: [String: [String: [String]]] = [:]
    private let runs = try! NSRegularExpression(pattern: "(?<!\\p{sc=Han})\\p{sc=Han}+(?=\\p{sc=Hiragana})")
    private let ruby = try! NSRegularExpression(pattern: "\\[([^\\]]*)\\]")

    func prepare(sourceText: String, lines: [String], existing: LyricReadings? = nil) throws -> LyricReadings {
        try Task.checkCancellation()
        if let existing, existing.isCurrent(sourceText: sourceText),
           lines.allSatisfy({ existing.readings(for: $0) != nil }) { return existing }
        if lists == nil {
            let decoder = JSONDecoder()
            guard let readingsURL = Bundle.module.url(forResource: "RubifontSansVF.ivs", withExtension: "json", subdirectory: "Fonts"),
                  let pairsURL = Bundle.module.url(forResource: "okurigana", withExtension: "json", subdirectory: "Fonts"),
                  let contextsURL = Bundle.module.url(forResource: "context-readings", withExtension: "json", subdirectory: "Fonts") else {
                throw ReadingError.missingData
            }
            let loaded = try decoder.decode(ReadingLists.self, from: Data(contentsOf: readingsURL))
            guard loaded.salt else { throw ReadingError.missingData }
            pairs = try decoder.decode([String: [String: [String]]].self, from: Data(contentsOf: pairsURL))
            contexts = try decoder.decode([ContextReading].self, from: Data(contentsOf: contextsURL))
            lists = loaded
        }
        var selected: [String: [LyricReading]] = [:]
        for text in lines where selected[text] == nil {
            try Task.checkCancellation()
            selected[text] = select(in: text, lists: lists!)
        }
        return LyricReadings(sourceTextHash: LyricHash.text(sourceText), lines: selected)
    }

    private func select(in text: String, lists: ReadingLists) -> [LyricReading] {
        var result: [LyricReading] = []
        for match in runs.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let run = String(text[range])
            guard let group = pairs[run] else { continue }
            let after = text[range.upperBound...]
            var suffixes: [String: String] = [:]
            for (reading, endings) in group {
                for ending in endings {
                    if let previous = suffixes[ending], previous != reading { suffixes[ending] = "" }
                    else { suffixes[ending] = reading }
                }
            }
            guard let suffix = suffixes.keys.filter({ after.hasPrefix($0) }).max(by: { $0.utf16.count < $1.utf16.count }),
                  let reading = suffixes[suffix], !reading.isEmpty else { continue }
            let candidates: [String]?
            if run.count > 1 {
                candidates = lists.words[run]?.map { notation in
                    ruby.matches(in: notation, range: NSRange(notation.startIndex..., in: notation)).compactMap {
                        Range($0.range(at: 1), in: notation).map { String(notation[$0]) }
                    }.joined()
                }
            } else { candidates = lists.kanji[run] }
            guard let index = candidates?.firstIndex(of: reading), index < 15,
                  index >= (run.count > 1 ? 1 : 0), lists.lone[run] != reading else { continue }
            result.append(LyricReading(start: text.distance(from: text.startIndex, to: range.lowerBound),
                                       count: text.distance(from: range.lowerBound, to: range.upperBound), salt: index + 1))
        }
        let contextual = selectContexts(in: text)
        result.removeAll { reading in
            contextual.contains { override in
                reading.start < override.start + override.count && override.start < reading.start + reading.count
            }
        }
        return (result + contextual).sorted { $0.start < $1.start }
    }

    private func selectContexts(in text: String) -> [LyricReading] {
        let characters = Array(text)
        var result: [LyricReading] = []
        for context in contexts {
            let target = Array(context.text)
            guard !target.isEmpty, target.count <= characters.count else { continue }
            for start in 0...(characters.count - target.count) {
                guard characters[start..<(start + target.count)].elementsEqual(target),
                      !(context.numberBoundary == true && start > 0 && characters[start - 1].isNumber) else { continue }
                result += context.selections.map { selection in
                    LyricReading(start: start + selection.start, count: selection.count, salt: selection.salt)
                }
            }
        }
        return result
    }

    private enum ReadingError: Error, LocalizedError {
        case missingData
        var errorDescription: String? { "歌詞の読みデータを読み込めませんでした。" }
    }
}
