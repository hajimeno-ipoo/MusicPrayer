import Foundation
import CoreFoundation
import OSLog

/// Matches complete input lines to the final, time-indexed Apple Speech text.
/// Confidence describes spelling or reading agreement, not synchronization accuracy.
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
        let placements: [Candidate]
        do {
            placements = try solve(lines, characters: characters, useReading: false)
        } catch LyricAlignmentError.unmatchedLine {
            placements = try solve(lines, characters: characters, useReading: true)
        }
        let sourceHash = LyricHash.text(sourceText)
        var recognizedLines = zip(lines, placements).map { line, placement in
            TimedLyricLine(id: LyricHash.lineID(audioFingerprint: analysis.fingerprint,
                                              version: LyricVersions.alignment,
                                              sourceTextHash: sourceHash, ordinal: line.ordinal),
                           ordinal: line.ordinal, text: line.text,
                           start: characters[placement.start].start,
                           end: characters[placement.end - 1].end,
                           textWeight: line.textWeight,
                           confidence: placement.readingAgreement ??
                               Float(placement.matches) / Float(placement.sourceCount))
        }
        let music = LyricMusicContext(analysis: analysis)
        let frames = try music.frames(for: recognizedLines)
        for index in lines.indices {
            let colour = try colourTimings(for: lines[index],
                placement: placements[index], characters: characters, music: music)
            recognizedLines[index].characterTimings = colour.timings
            recognizedLines[index].unrecognizedLeadingCharacters = colour.unrecognizedLeadingCharacters
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
        var firstMatch: Int?

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
        var firstMatch: Int?
        var readingEdits = 0
        var readingAgreement: Float?
        var readingOccurrenceStart: Int?
    }

    /// Read whole rows/windows, so 一つ is read as hitotsu rather than ichi.
    private final class ReadingCache {
        private var values: [String: [Character]] = [:]
        private var unavailable: Set<String> = []

        func reading(_ text: String) throws -> [Character]? {
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
                try Task.checkCancellation()
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

    private static func editScore(_ source: [Character], _ target: [Character],
                                  maximumEdits: Int? = nil) throws -> EditScore {
        let limit = maximumEdits ?? max(source.count, target.count)
        let rejected = EditScore(edits: limit + 1, matches: 0)
        guard abs(source.count - target.count) <= limit else { return rejected }
        if source.isEmpty { return EditScore(edits: target.count, matches: 0) }
        if target.isEmpty { return EditScore(edits: source.count, matches: 0) }
        var previous = (0...target.count).map { $0 <= limit ? EditScore(edits: $0, matches: 0) : rejected }
        var current = Array(repeating: rejected, count: target.count + 1)
        var sourceIndex = 0
        while sourceIndex < source.count {
            try Task.checkCancellation()
            let first = max(1, sourceIndex + 1 - limit)
            let last = min(target.count, sourceIndex + 1 + limit)
            current[first - 1] = first == 1 && sourceIndex + 1 <= limit
                ? EditScore(edits: sourceIndex + 1, matches: 0) : rejected
            if last < target.count { current[last + 1] = rejected }
            var rowMinimum = current[first - 1].edits
            var column = first
            while column <= last {
                let equal = source[sourceIndex] == target[column - 1]
                var best = EditScore(edits: previous[column - 1].edits + (equal ? 0 : 1),
                                     matches: previous[column - 1].matches + (equal ? 1 : 0))
                let deletion = EditScore(edits: previous[column].edits + 1,
                                         matches: previous[column].matches)
                if deletion.isBetter(than: best) { best = deletion }
                let insertion = EditScore(edits: current[column - 1].edits + 1,
                                          matches: current[column - 1].matches)
                if insertion.isBetter(than: best) { best = insertion }
                current[column] = best.edits <= limit ? best : rejected
                rowMinimum = min(rowMinimum, current[column].edits)
                column += 1
            }
            guard rowMinimum <= limit else { return rejected }
            swap(&previous, &current)
            sourceIndex += 1
        }
        return previous[target.count]
    }

    /// Backtrace only the already selected row. It cannot change row placement.
    private struct ColourAlignment {
        var timings: [LyricCharacterTiming]
        var unrecognizedLeadingCharacters: Int
    }

    private static func colourTimings(for line: LyricLine, placement: Candidate,
                                     characters: [AudioCharacter], music: LyricMusicContext) throws
        -> ColourAlignment {
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
        // Record missing leading spelling before filling it with a shared interval.
        // Shared times alone cannot distinguish an omission from a multi-letter token.
        let weighted = original.indices.filter { LyricParser.characterWeight(original[$0]) > 0 }
        let unrecognizedLeadingCharacters = weighted.prefix { timings[$0] == nil }.count
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
        return ColourAlignment(timings: timings.map { $0! },
                               unrecognizedLeadingCharacters: unrecognizedLeadingCharacters)
    }

    private static func addReadingEvidence(to candidates: inout [Candidate], line: LyricLine,
                                           characters: [AudioCharacter], cache: ReadingCache) throws {
        guard containsJapanese(line.text), let source = try cache.reading(line.text) else { return }
        var distances: [Int] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard let target = try cache.reading(recognizedText(candidate, characters: characters)) else {
                // An unavailable reading must not favor another candidate. Disable
                // this third score for the entire row rather than inventing a reading.
                return
            }
            distances.append(try editScore(source, target).edits)
        }
        for index in candidates.indices { candidates[index].readingEdits = distances[index] }
    }

    /// Every candidate is one consecutive recognition interval. The bounded edit
    /// window allows spelling errors without joining scattered words across song sections.
    private static func candidates(for line: LyricLine, characters: [AudioCharacter],
                                   cache: ReadingCache, useReading: Bool) throws -> [Candidate] {
        let source = normalized(line.text)
        guard !source.isEmpty else { throw LyricAlignmentError.unmatchedLine(line.ordinal) }
        let sourceCount = source.count
        let editLimit = max(2, Int(floor(Double(sourceCount) * maximumEditRatio)))
        let sourceReading = useReading && containsJapanese(line.text) ? try cache.reading(line.text) : nil
        let readingFrequency = sourceReading?.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 } ?? [:]
        let readingLimit = sourceReading.map { max(2, Int(floor(Double($0.count) * maximumEditRatio))) } ?? 0
        let windowLimit = max(Int(ceil(Double(sourceCount) * 1.8)) + 2,
                              sourceReading.map { $0.count + readingLimit } ?? 0)
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
                                         matches: previous[offset - 1].matches + (equal ? 1 : 0),
                                         firstMatch: previous[offset - 1].firstMatch ?? (equal ? start + offset - 1 : nil))
                    let deletion = EditScore(edits: previous[offset].edits + 1,
                                             matches: previous[offset].matches, firstMatch: previous[offset].firstMatch)
                    if deletion.isBetter(than: best) { best = deletion }
                    let insertion = EditScore(edits: current[offset - 1].edits + 1,
                                              matches: current[offset - 1].matches, firstMatch: current[offset - 1].firstMatch)
                    if insertion.isBetter(than: best) { best = insertion }
                    current.append(best)
                }
                previous = current
            }
            for offset in 1...count {
                let end = start + offset
                if end < characters.count, characters[end - 1].token == characters[end].token { continue }
                try Task.checkCancellation()
                let score = previous[offset]
                guard characters[end - 1].end - characters[start].start + epsilon >= minimumLineDuration else { continue }
                var candidate = Candidate(start: start, end: end, edits: score.edits,
                                          matches: score.matches, sourceCount: sourceCount,
                                          firstMatch: score.firstMatch)
                if score.edits > editLimit ||
                    Double(score.matches) / Double(sourceCount) + epsilon < minimumMatchRatio {
                    // A spelling error must still agree with the recognized reading.
                    // Reuse the same evidence limits; retain Apple's exact time range.
                    guard let sourceReading,
                          let targetReading = try cache.reading(recognizedText(candidate, characters: characters)) else { continue }
                    guard abs(sourceReading.count - targetReading.count) <= readingLimit else { continue }
                    // Character frequency bounds any alignment's matches from above
                    // and its edits from below. Reject only impossible readings.
                    var used: [Character: Int] = [:]
                    var common = 0
                    for character in targetReading {
                        let count = used[character, default: 0]
                        if count < readingFrequency[character, default: 0] { common += 1 }
                        used[character] = count + 1
                    }
                    guard Double(common) / Double(sourceReading.count) + epsilon >= minimumMatchRatio,
                          max(sourceReading.count, targetReading.count) - common <= readingLimit else { continue }
                    let readingScore = try editScore(sourceReading, targetReading, maximumEdits: readingLimit)
                    let agreement = Double(readingScore.matches) / Double(sourceReading.count)
                    guard readingScore.edits <= readingLimit,
                          agreement + epsilon >= minimumMatchRatio else { continue }
                    candidate.readingAgreement = Float(agreement)
                    // Prefix variants share an occurrence only within connected
                    // Speech ranges; an earlier, separate voice remains distinct.
                    if let firstMatch = score.firstMatch {
                        let prefix = characters[start...firstMatch]
                        let connected = zip(prefix, prefix.dropFirst()).allSatisfy {
                            $1.start <= $0.end + epsilon
                        }
                        if connected { candidate.readingOccurrenceStart = firstMatch }
                    }
                }
                result.append(candidate)
            }
        }
        return result
    }

    private struct PathScore: Equatable {
        var readingFallbacks: Int
        var edits: Int
        var unmatched: Int
        var readingEdits: Int

        func isBetter(than other: Self) -> Bool {
            if readingFallbacks != other.readingFallbacks {
                return readingFallbacks < other.readingFallbacks
            }
            return edits < other.edits || (edits == other.edits &&
                (unmatched < other.unmatched || (unmatched == other.unmatched &&
                    readingEdits < other.readingEdits)))
        }
    }

    /// Interns row occurrences by the first matched character when an unmatched
    /// prefix belongs to connected Speech ranges. Boundary variants share one identity.
    private struct OccurrenceKey: Hashable {
        let previous: Int
        let start: Int
    }

    private final class Path {
        let candidate: Candidate?
        let previous: Path?
        let score: PathScore
        let occurrenceID: Int
        let boundaryDeviation: Int
        let rank: Int
        var end: Int { candidate?.end ?? 0 }

        init(candidate: Candidate?, previous: Path?, score: PathScore,
             occurrenceID: Int, boundaryDeviation: Int, rank: Int) {
            self.candidate = candidate
            self.previous = previous
            self.score = score
            self.occurrenceID = occurrenceID
            self.boundaryDeviation = boundaryDeviation
            self.rank = rank
        }
    }

    private static func precedes(_ lhs: Path, _ rhs: Path) -> Bool {
        if lhs.score != rhs.score { return lhs.score.isBetter(than: rhs.score) }
        if lhs.boundaryDeviation != rhs.boundaryDeviation {
            return lhs.boundaryDeviation < rhs.boundaryDeviation
        }
        return lhs.rank < rhs.rank
    }

    private static func keepBestTwoOccurrences(_ path: Path, in best: inout [Path]) {
        if let index = best.firstIndex(where: { $0.occurrenceID == path.occurrenceID }) {
            if precedes(path, best[index]) { best[index] = path }
        } else {
            best.append(path)
        }
        best.sort(by: precedes)
        if best.count > 2 { best.removeLast() }
    }

    private static func solve(_ lines: [LyricLine], characters: [AudioCharacter],
                              useReading: Bool) throws -> [Candidate] {
        var previous = [Path(candidate: nil, previous: nil,
                             score: PathScore(readingFallbacks: 0, edits: 0, unmatched: 0, readingEdits: 0),
                             occurrenceID: 0, boundaryDeviation: 0, rank: 0)]
        var nextRank = 1
        let readingCache = ReadingCache()
        for line in lines {
            try Task.checkCancellation()
            var possible = try candidates(for: line, characters: characters, cache: readingCache, useReading: useReading)
                .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            guard !possible.isEmpty else { throw LyricAlignmentError.unmatchedLine(line.ordinal) }
            try addReadingEvidence(to: &possible, line: line, characters: characters, cache: readingCache)
            let ordered = previous.sorted { $0.end == $1.end ? $0.rank < $1.rank : $0.end < $1.end }
            var prefix: [Path] = []
            var previousIndex = 0
            var current: [Path] = []
            var occurrences: [OccurrenceKey: Int] = [:]
            for candidate in possible {
                while previousIndex < ordered.count, ordered[previousIndex].end <= candidate.start {
                    // Group only parents that can reach this start. A shorter
                    // ending may be the only one that leaves room for this row.
                    keepBestTwoOccurrences(ordered[previousIndex], in: &prefix)
                    previousIndex += 1
                }
                for parent in prefix {
                    var occurrenceStart = candidate.readingOccurrenceStart ?? candidate.start
                    // Connected prefix variants before the same matched character are one utterance.
                    if let first = candidate.firstMatch,
                       zip(characters[candidate.start...first],
                           characters[candidate.start...first].dropFirst()).allSatisfy({
                               $1.start <= $0.end + epsilon
                           }) {
                        occurrenceStart = first
                    }
                    let key = OccurrenceKey(previous: parent.occurrenceID,
                                            start: occurrenceStart)
                    let occurrenceID: Int
                    if let existing = occurrences[key] {
                        occurrenceID = existing
                    } else {
                        occurrenceID = occurrences.count
                        occurrences[key] = occurrenceID
                    }
                    current.append(Path(candidate: candidate, previous: parent,
                                        score: PathScore(readingFallbacks: parent.score.readingFallbacks +
                                            (candidate.readingAgreement == nil ? 0 : 1),
                                                         edits: parent.score.edits + candidate.edits,
                                                         unmatched: parent.score.unmatched + candidate.sourceCount - candidate.matches,
                                                         readingEdits: parent.score.readingEdits + candidate.readingEdits),
                                        occurrenceID: occurrenceID,
                                        boundaryDeviation: parent.boundaryDeviation +
                                            abs(candidate.end - candidate.start - candidate.sourceCount),
                                        rank: nextRank))
                    nextRank += 1
                }
            }
            guard !current.isEmpty else { throw LyricAlignmentError.unmatchedLine(line.ordinal) }
            previous = current
        }
        var final: [Path] = []
        for path in previous { keepBestTwoOccurrences(path, in: &final) }
        guard let best = final.first else { throw LyricAlignmentError.noFeasiblePath }
        // Length chooses a representative ending, never a different occurrence.
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

    /// Locates remaining-language fragments for a bounded second recognition pass.
    /// These anchors do not become row or colour times. An omitted leading spelling
    /// begins at its first matched native token; distinct singing positions still fail.
    static func recognitionAnchors(fragments: [String], transcription: [RecognizedLyricToken],
                                   duration: Double) throws -> [LyricCharacterTiming] {
        let lines = LyricParser.parse(fragments.joined(separator: "\n"))
        guard lines.count == fragments.count, !lines.isEmpty else {
            throw LyricAlignmentError.noFeasiblePath
        }
        let characters = try prepare(transcription, duration: duration)
        guard !characters.isEmpty else { throw LyricAlignmentError.noRecognizedWords }
        let placements: [Candidate]
        do { placements = try solve(lines, characters: characters, useReading: false) }
        catch LyricAlignmentError.unmatchedLine {
            placements = try solve(lines, characters: characters, useReading: true)
        }
        return placements.map {
            LyricCharacterTiming(start: characters[$0.firstMatch ?? $0.start].start,
                                 end: characters[$0.end - 1].end)
        }
    }
}
