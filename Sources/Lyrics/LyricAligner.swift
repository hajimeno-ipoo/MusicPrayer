import Foundation
import CoreFoundation
import OSLog

/// Matches complete input lines to the final, time-indexed Apple Speech text.
/// Confidence describes text agreement, not measured synchronization accuracy.
enum LyricAligner {
    private static let minimumMatchRatio = 0.60
    private static let maximumEditRatio = 0.45
    private static let minimumLineDuration = 0.30
    private static let epsilon = 1e-9
    private static let logger = Logger(subsystem: "com.hazimeno.MusicPrayer", category: "LyricAligner")

    /// Cache identity includes every observation used by structure and its support.
    static func analysisDigest(_ analysis: MusicAnalysis) throws -> String {
        guard analysis.duration.isFinite, analysis.duration > 0 else {
            throw LyricAlignmentError.invalidDuration
        }
        guard analysis.fingerprint.utf8.count == 64,
              analysis.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LyricAlignmentError.inconsistentSavedData
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return LyricHash.digest(try encoder.encode(analysis))
    }

    static func align(sourceText: String, analysis: MusicAnalysis,
                      transcription: [RecognizedLyricToken]) throws -> LyricTimeline {
        let digest = try analysisDigest(analysis)
        let lines = LyricParser.parse(sourceText)
        guard !lines.isEmpty else { throw LyricAlignmentError.noFeasiblePath }
        let characters = try prepare(transcription, duration: analysis.duration)
        guard !characters.isEmpty else { throw LyricAlignmentError.noRecognizedWords }
        let placements = try solve(lines, characters: characters)
        let sourceHash = LyricHash.text(sourceText)
        var recognizedLines = zip(lines, placements).map { line, placement in
            TimedLyricLine(id: LyricHash.lineID(audioFingerprint: analysis.fingerprint,
                                              version: LyricVersions.alignment,
                                              sourceTextHash: sourceHash, ordinal: line.ordinal),
                           ordinal: line.ordinal, text: line.text,
                           start: characters[placement.start].start,
                           end: characters[placement.end - 1].end,
                           textWeight: line.textWeight,
                           confidence: Float(placement.matches) / Float(placement.sourceCount))
        }
        let music = LyricMusicContext(analysis: analysis)
        let frames = try music.frames(for: recognizedLines)
        for index in lines.indices {
            recognizedLines[index].characterTimings = try colourTimings(for: lines[index],
                placement: placements[index], characters: characters, music: music)
        }
        let confidence = recognizedLines.reduce(Float(0)) { $0 + $1.confidence } / Float(recognizedLines.count)
        let result = LyricTimeline(version: LyricVersions.alignment,
                                   analysisVersion: analysis.version,
                                   analysisFingerprint: analysis.fingerprint,
                                   analysisDigest: digest, sourceText: sourceText,
                                   sourceTextHash: sourceHash, mode: .speechRecognition,
                                   lines: recognizedLines, confidence: confidence, frames: frames)
        try validate(result, analysis: analysis)
        logger.info("Matched mode=speechRecognition lines=\(lines.count) recognizedCharacters=\(characters.count) textAgreement=\(confidence) structureFrames=\(frames.count) boundaryCorrection=0")
        return result
    }

    static func validate(_ timeline: LyricTimeline, analysis: MusicAnalysis) throws {
        try Task.checkCancellation()
        let expectedDigest = try analysisDigest(analysis)
        guard timeline.version == LyricVersions.alignment,
              timeline.analysisVersion == analysis.version,
              timeline.analysisFingerprint == analysis.fingerprint,
              timeline.analysisDigest == expectedDigest,
              timeline.sourceTextHash == LyricHash.text(timeline.sourceText),
              timeline.mode == .speechRecognition,
              validConfidence(timeline.confidence) else {
            throw LyricAlignmentError.inconsistentSavedData
        }
        let input = LyricParser.parse(timeline.sourceText)
        guard !input.isEmpty, timeline.lines.count == input.count else {
            throw LyricAlignmentError.inconsistentSavedData
        }
        var previousEnd = 0.0
        for (line, source) in zip(timeline.lines, input) {
            guard line.ordinal == source.ordinal, line.text == source.text,
                  line.textWeight == source.textWeight,
                  line.id == LyricHash.lineID(audioFingerprint: analysis.fingerprint,
                                             version: timeline.version,
                                             sourceTextHash: timeline.sourceTextHash,
                                             ordinal: source.ordinal),
                  line.start.isFinite, line.end.isFinite, line.start >= 0,
                  line.start + epsilon >= previousEnd,
                  line.end <= analysis.duration + epsilon,
                  line.end - line.start + epsilon >= minimumLineDuration,
                  line.hasValidCharacterTimings, validConfidence(line.confidence),
                  Double(line.confidence) + epsilon >= minimumMatchRatio else {
                throw LyricAlignmentError.inconsistentSavedData
            }
            previousEnd = line.end
        }
        let mean = timeline.lines.reduce(Float(0)) { $0 + $1.confidence } / Float(input.count)
        guard abs(mean - timeline.confidence) <= 1e-6 else {
            throw LyricAlignmentError.inconsistentSavedData
        }
        guard timeline.frames == (try LyricMusicContext(analysis: analysis).frames(for: timeline.lines)) else {
            throw LyricAlignmentError.inconsistentSavedData
        }
    }

    private static func validConfidence(_ value: Float) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func normalized(_ text: String) -> [Character] {
        let folded = text.precomposedStringWithCanonicalMapping
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
        let kana = folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
        return kana.filter { LyricParser.characterWeight($0) > 0 }.map { $0 }
    }

    private struct AudioCharacter {
        var value: Character
        var token: Int
        var tokenText: String
        var start: Double
        var end: Double
    }

    private static func prepare(_ tokens: [RecognizedLyricToken], duration: Double) throws -> [AudioCharacter] {
        var result: [AudioCharacter] = []
        var previousEnd = 0.0
        for (index, token) in tokens.enumerated() {
            try Task.checkCancellation()
            let text = normalized(token.text)
            guard !text.isEmpty else { continue }
            guard token.start.isFinite, token.end.isFinite,
                  token.start >= 0, token.end > token.start,
                  token.start + epsilon >= previousEnd, token.end <= duration + epsilon,
                  token.confidence.isFinite, (0...1).contains(token.confidence) else {
                throw LyricAlignmentError.invalidFinalBoundaries
            }
            // Characters from one token retain its identical framework range.
            // Candidate boundaries may never split that range into invented times.
            result += text.map { AudioCharacter(value: $0, token: index,
                                                tokenText: token.text,
                                                start: token.start, end: token.end) }
            previousEnd = token.end
        }
        return result
    }

    private struct EditScore {
        var edits: Int
        var matches: Int

        func isBetter(than other: Self) -> Bool {
            edits < other.edits || (edits == other.edits && matches > other.matches)
        }
    }

    private struct Candidate {
        var start: Int
        var end: Int
        var edits: Int
        var matches: Int
        var sourceCount: Int
        var readingEdits = 0
    }

    /// Reading only breaks otherwise identical spelling scores for Japanese rows.
    /// The whole row/window is tokenized, so 一つ is read as hitotsu rather than ichi.
    private final class ReadingCache {
        private var values: [String: [Character]] = [:]
        private var unavailable: Set<String> = []

        func reading(_ text: String) -> [Character]? {
            if let value = values[text] { return value }
            if unavailable.contains(text) { return nil }
            let locale = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: "ja_JP" as CFString))
            guard let tokenizer = CFStringTokenizerCreate(nil, text as CFString,
                CFRange(location: 0, length: (text as NSString).length),
                kCFStringTokenizerUnitWord | kCFStringTokenizerAttributeLatinTranscription,
                locale) else {
                unavailable.insert(text)
                return nil
            }
            var characters: [Character] = []
            while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
                guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer,
                    kCFStringTokenizerAttributeLatinTranscription) as? String else {
                    unavailable.insert(text)
                    return nil
                }
                characters += normalized(latin)
            }
            guard !characters.isEmpty else {
                unavailable.insert(text)
                return nil
            }
            values[text] = characters
            return characters
        }
    }

    private static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3040...0x30ff).contains($0.value) || (0x3400...0x4dbf).contains($0.value)
                || (0x4e00...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value)
        }
    }

    private static func recognizedText(_ candidate: Candidate, characters: [AudioCharacter]) -> String {
        var result = ""
        var previousToken: Int?
        for character in characters[candidate.start..<candidate.end] {
            if previousToken != character.token {
                result += character.tokenText
                previousToken = character.token
            }
        }
        return result
    }

    private static func editDistance(_ source: [Character], _ target: [Character]) -> Int {
        var previous = Array(0...target.count)
        for sourceIndex in source.indices {
            var current = [sourceIndex + 1]
            for targetIndex in target.indices {
                current.append(min(previous[targetIndex + 1] + 1, current[targetIndex] + 1,
                                   previous[targetIndex] + (source[sourceIndex] == target[targetIndex] ? 0 : 1)))
            }
            previous = current
        }
        return previous[target.count]
    }

    /// Backtrace only the already selected row. It cannot change row placement.
    private static func colourTimings(for line: LyricLine, placement: Candidate,
                                     characters: [AudioCharacter], music: LyricMusicContext) throws
        -> [LyricCharacterTiming] {
        let original = Array(line.text)
        let source = original.enumerated().flatMap { index, character in
            normalized(String(character)).map { (owner: index, value: $0) }
        }
        let target = Array(characters[placement.start..<placement.end])
        var scores = Array(repeating: Array(repeating: EditScore(edits: 0, matches: 0),
            count: target.count + 1), count: source.count + 1)
        var steps = Array(repeating: Array(repeating: 0, count: target.count + 1), count: source.count + 1)
        for i in 1...source.count { scores[i][0].edits = i; steps[i][0] = 1 }
        for j in 1...target.count { scores[0][j].edits = j; steps[0][j] = 2 }
        for i in 1...source.count {
            try Task.checkCancellation()
            for j in 1...target.count {
                let equal = source[i - 1].value == target[j - 1].value
                var best = EditScore(edits: scores[i - 1][j - 1].edits + (equal ? 0 : 1),
                                     matches: scores[i - 1][j - 1].matches + (equal ? 1 : 0))
                let deletion = EditScore(edits: scores[i - 1][j].edits + 1, matches: scores[i - 1][j].matches)
                if deletion.isBetter(than: best) { best = deletion; steps[i][j] = 1 }
                let insertion = EditScore(edits: scores[i][j - 1].edits + 1, matches: scores[i][j - 1].matches)
                if insertion.isBetter(than: best) { best = insertion; steps[i][j] = 2 }
                scores[i][j] = best
            }
        }
        var tokenRanges: [Int: LyricCharacterTiming] = [:]
        for character in target {
            tokenRanges[character.token] = LyricCharacterTiming(start: character.start, end: character.end)
        }
        // Only an unusually long leading token can contain a pre-word pause.
        // Use its own measured interval, never a fixed shift or beat/phrase snap.
        if let first = target.first, first.value == source.first?.value,
           target.filter({ $0.token == first.token }).count == 1,
           var leading = tokenRanges[first.token],
           let longestOther = tokenRanges.filter({ $0.key != first.token }).values
                .map({ $0.end - $0.start }).max(),
           let bpm = music.analysis.bpm, bpm.isFinite, bpm > 0,
           leading.end - leading.start > max(longestOther, 60 / Double(bpm)) {
            leading.start = music.leadingColourStart(in: leading)
            tokenRanges[first.token] = leading
        }
        var timings = Array<LyricCharacterTiming?>(repeating: nil, count: original.count)
        var i = source.count, j = target.count
        while i > 0 || j > 0 {
            switch steps[i][j] {
            case 1: i -= 1
            case 2: j -= 1
            default:
                let owner = source[i - 1].owner
                let range = tokenRanges[target[j - 1].token]!
                if let existing = timings[owner] {
                    timings[owner] = LyricCharacterTiming(start: min(existing.start, range.start),
                                                          end: max(existing.end, range.end))
                } else { timings[owner] = range }
                i -= 1; j -= 1
            }
        }
        // A missing spelling shares the next recognised interval. Trailing spelling
        // completes with the preceding word; no fabricated intermediate timestamps.
        var next: LyricCharacterTiming?
        for index in original.indices.reversed() where LyricParser.characterWeight(original[index]) > 0 {
            if let known = timings[index] { next = known }
            else if let next { timings[index] = next }
        }
        var previous = LyricCharacterTiming(start: target[0].start, end: target[0].start)
        for index in original.indices {
            if let known = timings[index] { previous = known }
            else { timings[index] = LyricCharacterTiming(start: previous.end, end: previous.end) }
        }
        return timings.map { $0! }
    }

    private static func addReadingEvidence(to candidates: inout [Candidate], line: LyricLine,
                                           characters: [AudioCharacter], cache: ReadingCache) throws {
        guard containsJapanese(line.text), let source = cache.reading(line.text) else { return }
        var distances: [Int] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let target = cache.reading(recognizedText(candidate, characters: characters)) else {
                // An unavailable reading must not favor another candidate. Disable
                // this third score for the entire row rather than inventing a reading.
                return
            }
            distances.append(editDistance(source, target))
        }
        for index in candidates.indices { candidates[index].readingEdits = distances[index] }
    }

    /// Every candidate is one consecutive recognition interval. The bounded edit
    /// window allows spelling errors without joining scattered words across song sections.
    private static func candidates(for line: LyricLine, characters: [AudioCharacter]) throws -> [Candidate] {
        let source = normalized(line.text)
        guard !source.isEmpty else { throw LyricAlignmentError.unmatchedLine(line.ordinal) }
        let sourceCount = source.count
        let editLimit = max(2, Int(floor(Double(sourceCount) * maximumEditRatio)))
        let windowLimit = Int(ceil(Double(sourceCount) * 1.8)) + 2
        var result: [Candidate] = []
        for start in characters.indices {
            if start % 64 == 0 { try Task.checkCancellation() }
            if start > 0, characters[start - 1].token == characters[start].token { continue }
            let count = min(windowLimit, characters.count - start)
            var previous = (0...count).map { EditScore(edits: $0, matches: 0) }
            for sourceIndex in source.indices {
                var current = [EditScore(edits: sourceIndex + 1, matches: 0)]
                current.reserveCapacity(count + 1)
                for offset in 1...count {
                    let equal = source[sourceIndex] == characters[start + offset - 1].value
                    var best = EditScore(edits: previous[offset - 1].edits + (equal ? 0 : 1),
                                         matches: previous[offset - 1].matches + (equal ? 1 : 0))
                    let deletion = EditScore(edits: previous[offset].edits + 1,
                                             matches: previous[offset].matches)
                    if deletion.isBetter(than: best) { best = deletion }
                    let insertion = EditScore(edits: current[offset - 1].edits + 1,
                                              matches: current[offset - 1].matches)
                    if insertion.isBetter(than: best) { best = insertion }
                    current.append(best)
                }
                previous = current
            }
            for offset in 1...count {
                let end = start + offset
                if end < characters.count, characters[end - 1].token == characters[end].token { continue }
                let score = previous[offset]
                guard score.edits <= editLimit,
                      Double(score.matches) / Double(sourceCount) + epsilon >= minimumMatchRatio,
                      characters[end - 1].end - characters[start].start + epsilon >= minimumLineDuration else { continue }
                result.append(Candidate(start: start, end: end, edits: score.edits,
                                        matches: score.matches, sourceCount: sourceCount))
            }
        }
        return result
    }

    private struct PathScore: Equatable {
        var edits: Int
        var unmatched: Int
        var readingEdits: Int

        func isBetter(than other: Self) -> Bool {
            edits < other.edits || (edits == other.edits &&
                (unmatched < other.unmatched || (unmatched == other.unmatched &&
                    readingEdits < other.readingEdits)))
        }
    }

    private final class Path {
        let candidate: Candidate?
        let previous: Path?
        let score: PathScore
        let rank: Int
        var end: Int { candidate?.end ?? 0 }

        init(candidate: Candidate?, previous: Path?, score: PathScore, rank: Int) {
            self.candidate = candidate
            self.previous = previous
            self.score = score
            self.rank = rank
        }
    }

    private static func precedes(_ lhs: Path, _ rhs: Path) -> Bool {
        lhs.score.isBetter(than: rhs.score) || (lhs.score == rhs.score && lhs.rank < rhs.rank)
    }

    private static func keepBestTwo(_ path: Path, in best: inout [Path]) {
        best.append(path)
        best.sort(by: precedes)
        if best.count > 2 { best.removeLast() }
    }

    private static func solve(_ lines: [LyricLine], characters: [AudioCharacter]) throws -> [Candidate] {
        var previous = [Path(candidate: nil, previous: nil,
                             score: PathScore(edits: 0, unmatched: 0, readingEdits: 0), rank: 0)]
        var nextRank = 1
        let readingCache = ReadingCache()
        for line in lines {
            try Task.checkCancellation()
            var possible = try candidates(for: line, characters: characters)
                .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            guard !possible.isEmpty else { throw LyricAlignmentError.unmatchedLine(line.ordinal) }
            try addReadingEvidence(to: &possible, line: line, characters: characters, cache: readingCache)
            let ordered = previous.sorted { $0.end == $1.end ? $0.rank < $1.rank : $0.end < $1.end }
            var prefix: [Path] = []
            var previousIndex = 0
            var current: [Path] = []
            for candidate in possible {
                while previousIndex < ordered.count, ordered[previousIndex].end <= candidate.start {
                    keepBestTwo(ordered[previousIndex], in: &prefix)
                    previousIndex += 1
                }
                for parent in prefix {
                    current.append(Path(candidate: candidate, previous: parent,
                                        score: PathScore(edits: parent.score.edits + candidate.edits,
                                                         unmatched: parent.score.unmatched + candidate.sourceCount - candidate.matches,
                                                         readingEdits: parent.score.readingEdits + candidate.readingEdits),
                                        rank: nextRank))
                    nextRank += 1
                }
            }
            guard !current.isEmpty else { throw LyricAlignmentError.unmatchedLine(line.ordinal) }
            previous = current
        }
        var final: [Path] = []
        for path in previous { keepBestTwo(path, in: &final) }
        guard let best = final.first else { throw LyricAlignmentError.noFeasiblePath }
        if final.count == 2, final[1].score == best.score {
            throw LyricAlignmentError.ambiguousMatch
        }
        var result: [Candidate] = []
        var node: Path? = best
        while let current = node, let candidate = current.candidate {
            result.append(candidate)
            node = current.previous
        }
        return result.reversed()
    }
}
