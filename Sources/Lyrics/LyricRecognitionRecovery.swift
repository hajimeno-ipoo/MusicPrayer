import Foundation
import NaturalLanguage

/// Uses recognized surrounding text to bound another-language recognition pass.
/// It never assigns a time to text or changes an existing native token's range.
enum LyricRecognitionRecovery {
    struct Window: Sendable, Equatable {
        var start: Double
        var end: Double
        var sourceText: String
        var language: String
    }

    private enum Part {
        case fragment(String)
        case foreign(String, String?)
    }

    private static let latin = try! NSRegularExpression(
        pattern: "[\\p{Latin}]+(?:[ \\t]+[\\p{Latin}]+)*")
    private static let epsilon = 1e-9

    static func containsLatinText(_ sourceText: String) -> Bool {
        latin.firstMatch(in: sourceText,
            range: NSRange(location: 0, length: (sourceText as NSString).length)) != nil
    }

    /// Metadata describes the document, not every sung phrase. Keep the
    /// languages found in individual rows and embedded Latin phrases as well.
    static func languageCandidates(sourceText: String, suppliedLanguages: [String]) -> [String] {
        var result: [String] = []
        func append(_ language: String?) {
            guard let language, !language.isEmpty else { return }
            let locale = Locale(identifier: language).language
            guard !result.contains(where: {
                let other = Locale(identifier: $0).language
                return other.languageCode == locale.languageCode && other.script == locale.script
            }) else { return }
            result.append(language)
        }
        for language in suppliedLanguages { append(language) }
        for line in LyricParser.parse(sourceText) {
            append(NLLanguageRecognizer.dominantLanguage(for: line.text)?.rawValue)
            let source = line.text as NSString
            var cursor = 0
            for match in latin.matches(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) {
                if match.range.location > cursor {
                    append(NLLanguageRecognizer.dominantLanguage(for: source.substring(with:
                        NSRange(location: cursor, length: match.range.location - cursor)))?.rawValue)
                }
                let text = source.substring(with: match.range)
                // Match the existing recovery rule for short abbreviations.
                if text.filter(\.isLetter).count >= 5 {
                    append(NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue)
                }
                cursor = NSMaxRange(match.range)
            }
            if cursor < source.length {
                append(NLLanguageRecognizer.dominantLanguage(for: source.substring(from: cursor))?.rawValue)
            }
        }
        return result
    }

    /// Reuse the bounded recovery path with recognition already obtained from
    /// the same PCM. Native token edges remain the only merge boundaries.
    static func combinedAlternatives(sourceText: String, analysis: MusicAnalysis,
                                     recognitions: [(language: String, tokens: [RecognizedLyricToken])]) throws
        -> [[RecognizedLyricToken]] {
        var alternatives = recognitions.map(\.tokens)
        guard recognitions.count > 1, containsLatinText(sourceText) else { return alternatives }
        for recognition in recognitions {
            try Task.checkCancellation()
            do {
                let windows = try plan(sourceText: sourceText, primaryLanguage: recognition.language,
                    transcription: recognition.tokens, duration: analysis.duration)
                guard !windows.isEmpty else { continue }
                let replacements = try windows.map { window in
                    try select(window: window, analysis: analysis, alternatives: recognitions.filter {
                        Locale(identifier: $0.language).language.languageCode ==
                            Locale(identifier: window.language).language.languageCode
                    }.map { $0.tokens.filter { $0.start >= window.start && $0.end <= window.end } })
                }
                alternatives.append(try merge(recognition.tokens, windows: windows, replacements: replacements))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return alternatives
    }

    static func plan(sourceText: String, primaryLanguage: String,
                     transcription: [RecognizedLyricToken], duration: Double) throws -> [Window] {
        var parts: [Part] = []
        for line in LyricParser.parse(sourceText) {
            try Task.checkCancellation()
            let ns = line.text as NSString
            var cursor = 0
            for match in latin.matches(in: line.text, range: NSRange(location: 0, length: ns.length)) {
                appendFragment(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &parts)
                let text = ns.substring(with: match.range)
                let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
                // Short abbreviations do not establish a second spoken language.
                let eligible = text.filter(\.isLetter).count >= 5 && language != primaryLanguage
                parts.append(.foreign(text, eligible ? language : nil))
                cursor = NSMaxRange(match.range)
            }
            appendFragment(ns.substring(from: cursor), to: &parts)
        }
        let fragments = parts.enumerated().compactMap { index, part -> (Int, String)? in
            if case .fragment(let text) = part { return (index, text) }
            return nil
        }
        guard !fragments.isEmpty, parts.contains(where: {
            if case .foreign(_, .some) = $0 { return true }
            return false
        }) else { return [] }
        let masked = transcription.compactMap { token -> RecognizedLyricToken? in
            let text = latin.stringByReplacingMatches(in: token.text,
                range: NSRange(location: 0, length: (token.text as NSString).length), withTemplate: "")
            guard text.contains(where: { LyricParser.characterWeight($0) > 0 }) else { return nil }
            return RecognizedLyricToken(text: text, start: token.start, end: token.end, confidence: token.confidence)
        }
        let ranges = try LyricAligner.recognitionAnchors(fragments: fragments.map(\.1),
                                                       transcription: masked, duration: duration)
        let anchors = zip(fragments, ranges).map { (index: $0.0.0, range: $0.1) }
        var groups: [(window: Window, languages: Set<String>)] = []
        for (index, part) in parts.enumerated() {
            guard case .foreign(let text, let language) = part else { continue }
            let start = anchors.last(where: { $0.index < index })?.range.end ?? 0
            let end = anchors.first(where: { $0.index > index })?.range.start ?? duration
            guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration else {
                throw LyricAlignmentError.noFeasiblePath
            }
            if let last = groups.last, abs(last.window.start - start) <= epsilon,
               abs(last.window.end - end) <= epsilon {
                groups[groups.count - 1].window.sourceText += "\n" + text
                if let language { groups[groups.count - 1].languages.insert(language) }
            } else {
                guard groups.last.map({ $0.window.end <= start + epsilon }) ?? true else {
                    throw LyricAlignmentError.noFeasiblePath
                }
                groups.append((Window(start: start, end: end, sourceText: text, language: ""),
                               language.map { Set([$0]) } ?? []))
            }
        }
        var windows: [Window] = []
        for group in groups {
            guard !group.languages.isEmpty else { continue }
            guard group.languages.count == 1, let language = group.languages.first else {
                throw LyricAlignmentError.noFeasiblePath
            }
            var window = group.window
            window.language = language
            windows.append(window)
        }
        // Cutting a token would invent a boundary. Require existing native edges.
        for window in windows {
            guard !transcription.contains(where: {
                ($0.start < window.start - epsilon && window.start < $0.end - epsilon) ||
                ($0.start < window.end - epsilon && window.end < $0.end - epsilon)
            }) else { throw LyricAlignmentError.invalidFinalBoundaries }
        }
        return windows
    }

    private static func appendFragment(_ text: String, to parts: inout [Part]) {
        if text.contains(where: { LyricParser.characterWeight($0) > 0 }) { parts.append(.fragment(text)) }
    }

    /// Both recognizers must meet the normal alignment rules. Agreement chooses
    /// between native results; text supplied as a hint is never itself a result.
    static func select(window: Window, analysis: MusicAnalysis,
                       alternatives: [[RecognizedLyricToken]]) throws -> [RecognizedLyricToken] {
        try selection(window: window, analysis: analysis, alternatives: alternatives).tokens
    }

    static func selection(window: Window, analysis: MusicAnalysis,
                          alternatives: [[RecognizedLyricToken]]) throws
        -> (timeline: LyricTimeline, tokens: [RecognizedLyricToken]) {
        var best: [(timeline: LyricTimeline, tokens: [RecognizedLyricToken])] = []
        for tokens in alternatives {
            try Task.checkCancellation()
            guard tokens.allSatisfy({ $0.start >= window.start - epsilon && $0.end <= window.end + epsilon }) else { continue }
            let timeline: LyricTimeline
            do { timeline = try LyricAligner.align(sourceText: window.sourceText, analysis: analysis, transcription: tokens) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            let selected = tokens.filter { token in
                timeline.lines.contains { token.start >= $0.start - epsilon && token.end <= $0.end + epsilon }
            }
            if let agreement = best.first?.timeline.confidence, timeline.confidence < agreement { continue }
            if best.first.map({ timeline.confidence > $0.timeline.confidence }) ?? false { best.removeAll() }
            best.append((timeline, selected))
        }
        guard let selected = best.first else { throw LyricAlignmentError.noFeasiblePath }
        // Equal text agreement at disjoint native positions is still ambiguous.
        // Overlapping ranges may differ because the recognizers report different
        // boundaries for the same utterance; keep the first native result intact.
        for (index, candidate) in best.enumerated() {
            for other in best.dropFirst(index + 1) {
                guard candidate.timeline.lines.count == other.timeline.lines.count,
                      zip(candidate.timeline.lines, other.timeline.lines).allSatisfy({
                          max($0.0.start, $0.1.start) < min($0.0.end, $0.1.end)
                      }) else { throw LyricAlignmentError.ambiguousMatch }
            }
        }
        return selected
    }

    static func merge(_ transcription: [RecognizedLyricToken], windows: [Window],
                      replacements: [[RecognizedLyricToken]]) throws -> [RecognizedLyricToken] {
        guard windows.count == replacements.count else { throw LyricAlignmentError.invalidFinalBoundaries }
        var result = transcription
        for (window, replacement) in zip(windows, replacements) {
            try Task.checkCancellation()
            guard !replacement.isEmpty,
                  replacement.allSatisfy({ $0.start >= window.start - epsilon && $0.end <= window.end + epsilon }),
                  !result.contains(where: {
                      ($0.start < window.start - epsilon && window.start < $0.end - epsilon) ||
                      ($0.start < window.end - epsilon && window.end < $0.end - epsilon)
                  }) else { throw LyricAlignmentError.invalidFinalBoundaries }
            result.removeAll { $0.start < window.end - epsilon && window.start < $0.end - epsilon }
            result += replacement
        }
        return result.sorted { $0.start < $1.start }
    }
}
