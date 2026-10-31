import Foundation

/// Character offsets in the unchanged display text, not UTF-16 offsets.
struct LyricReading: Codable, Sendable, Equatable {
    var start: Int
    var count: Int
    var salt: Int
}

struct LyricReadings: Codable, Sendable, Equatable {
    static let currentVersion = "rubifont-0.6.23-morphology-1"
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
            selected[text] = try select(in: text, lists: lists!)
        }
        return LyricReadings(sourceTextHash: LyricHash.text(sourceText), lines: selected)
    }

    private func select(in text: String, lists: ReadingLists) throws -> [LyricReading] {
        var result: [LyricReading] = []
        // Pair matches, including an ambiguous/default pair, take precedence over OS guesses.
        var protectedRanges: [Range<Int>] = []
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
            guard let suffix = suffixes.keys.filter({ after.hasPrefix($0) }).max(by: { $0.utf16.count < $1.utf16.count }) else { continue }
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            protectedRanges.append(start..<(start + run.count))
            guard let reading = suffixes[suffix], !reading.isEmpty else { continue }
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
        let explicit = result + contextual
        protectedRanges += contextual.map { $0.start..<($0.start + $0.count) }
        let inferred = try selectMorphology(in: text, lists: lists, protectedRanges: protectedRanges)
        return (explicit + inferred).sorted { $0.start < $1.start }
    }

    private func selectMorphology(in text: String, lists: ReadingLists, protectedRanges: [Range<Int>]) throws -> [LyricReading] {
        let characters = Array(text)
        var selected: [LyricReading] = []
        for token in try LyricMorphology.tokens(in: text) {
            try Task.checkCancellation()
            let word = Array(token.text)
            // A bare spelling supplies no extra context; retain the font's ordinary reading.
            // Evaluate this per line so preparing a whole source and its display lines agrees.
            if word.allSatisfy({ $0.unicodeScalars.allSatisfy(LyricMorphology.isHan) }) {
                var lower = token.start
                var upper = token.start + word.count
                while lower > 0 && !characters[lower - 1].isNewline { lower -= 1 }
                while upper < characters.count && !characters[upper].isNewline { upper += 1 }
                if String(characters[lower..<upper]).trimmingCharacters(in: .whitespaces) == token.text { continue }
            }
            var parts: [LyricReadingAlignment.Part] = []
            var at = 0
            var supported = true
            while at < word.count {
                let start = at
                if word[at].unicodeScalars.allSatisfy(LyricMorphology.isHan) {
                    while at < word.count && word[at].unicodeScalars.allSatisfy(LyricMorphology.isHan) { at += 1 }
                    let run = String(word[start..<at])
                    let choices: [(reading: String, salt: Int)]
                    if at - start == 1 {
                        choices = (lists.kanji[run] ?? []).prefix(15).enumerated().map {
                            ($0.element, lists.lone[run] == $0.element ? 0 : $0.offset + 1)
                        }
                    } else {
                        // A registered whole word already has a deliberate default. The correspondence
                        // tables may choose an alternate; OS guesses do not replace that default.
                        guard let notation = lists.words[run]?.first else { supported = false; break }
                        let reading = ruby.matches(in: notation, range: NSRange(notation.startIndex..., in: notation)).compactMap {
                            Range($0.range(at: 1), in: notation).map { String(notation[$0]) }
                        }.joined()
                        choices = reading.isEmpty ? [] : [(reading, 0)]
                    }
                    guard !choices.isEmpty else { supported = false; break }
                    parts.append(.init(start: token.start + start, count: at - start, choices: choices))
                } else {
                    let kana = String(word[at]).applyingTransform(.hiraganaToKatakana, reverse: true) ?? String(word[at])
                    guard kana.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) }) else { supported = false; break }
                    parts.append(.init(start: token.start + at, count: 1, choices: [(kana, 0)]))
                    at += 1
                }
            }
            guard supported, let aligned = LyricReadingAlignment.match(reading: token.reading, parts: parts) else { continue }
            for reading in aligned {
                let range = reading.start..<(reading.start + reading.count)
                guard !protectedRanges.contains(where: { $0.overlaps(range) }) else { continue }
                // salt_first can clear a later override within a continuous Han run. Do not save
                // a per-character guess that this font cannot display independently.
                let beforeIsHan = range.lowerBound > 0 && characters[range.lowerBound - 1].unicodeScalars.allSatisfy(LyricMorphology.isHan)
                let afterIsHan = range.upperBound < characters.count && characters[range.upperBound].unicodeScalars.allSatisfy(LyricMorphology.isHan)
                let besideNumber = (range.lowerBound > 0 && characters[range.lowerBound - 1].isNumber)
                    || (range.upperBound < characters.count && characters[range.upperBound].isNumber)
                guard !beforeIsHan && !afterIsHan && !besideNumber else { continue }
                selected.append(reading)
            }
        }
        return selected
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
