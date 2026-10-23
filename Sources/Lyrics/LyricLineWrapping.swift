import AppKit
import NaturalLanguage

struct LyricLinePresentation: Equatable {
    var fontSize: CGFloat
    /// Character offset in the original text; the display-only newline has no timing.
    var breakOffset: Int?
}

@MainActor
enum LyricLineWrapping {
    private final class Cached: NSObject {
        let value: LyricLinePresentation?
        init(_ value: LyricLinePresentation?) { self.value = value }
    }

    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 64
        return cache
    }()

    static func presentation(text: String, viewport: CGSize, font: LyricFont = .system,
                             readings: [LyricReading] = []) -> LyricLinePresentation? {
        guard viewport.width > 0, viewport.height > 0, !text.isEmpty else { return nil }
        let readings = font == .rubifont ? readings : []
        let readingKey = readings.map { "\($0.start),\($0.count),\($0.salt)" }.joined(separator: ";")
        let key = "\(font.rawValue):\(viewport.width):\(viewport.height):\(readingKey):\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = measure(text: text, viewport: viewport, font: font, readings: readings)
        cache.setObject(Cached(value), forKey: key)
        return value
    }

    private static func measure(text: String, viewport: CGSize, font: LyricFont,
                                readings: [LyricReading]) -> LyricLinePresentation? {
        let characters = Array(text)
        guard !characters.contains("\n") else { return nil }
        let indices = Array(text.indices) + [text.endIndex]
        let offsets = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var boundaries = Set<Int>()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let start = offsets[range.lowerBound] { boundaries.insert(start) }
            if let end = offsets[range.upperBound] { boundaries.insert(end) }
            return true
        }

        let opening = Set("（「『【〔〈《［｛([{")
        let closingBrackets = Set("）」』】〕〉》］｝)]}")
        let closing = Set("、。，．！？!?）」』】〕〉》］｝)]},.:;…ーぁぃぅぇぉっゃゅょァィゥェォッャュョ")
        let particles = Set(["は", "が", "を", "に", "へ", "と", "で", "の", "も", "や", "ね", "よ", "か"])
        var candidates: [(offset: Int, penalty: Double)] = []
        var depth = 0
        for offset in 1..<characters.count {
            let previous = characters[offset - 1], next = characters[offset]
            if opening.contains(previous) { depth += 1 }
            if closingBrackets.contains(previous) { depth = max(0, depth - 1) }
            guard !opening.contains(previous), !closing.contains(next), !next.isWhitespace else { continue }
            // A multi-kanji reading must keep its shaping context on one row.
            guard !readings.contains(where: { $0.start < offset && offset < $0.start + $0.count }) else { continue }
            let punctuation = "。！？.!?".contains(previous) ? -0.30 : ("、，,;；".contains(previous) ? -0.18 : 0)
            let whitespace = previous.isWhitespace || next.isWhitespace
            guard boundaries.contains(offset) || punctuation < 0 || whitespace else { continue }
            // Do not split an English word or leave a Japanese particle at the start.
            let splitWord = previous.isASCII && next.isASCII && previous.isLetter && next.isLetter
            guard !splitWord else { continue }
            let nextTokenEnd = boundaries.filter { $0 > offset }.min() ?? characters.count
            let nextToken = String(characters[offset..<nextTokenEnd])
            let penalty = punctuation + (whitespace ? -0.10 : 0) + (depth > 0 ? 0.65 : 0)
                + (particles.contains(nextToken) ? 0.45 : 0)
            candidates.append((offset, penalty))
        }

        for size in stride(from: 32, through: 14, by: -1) {
            let attributed = NSMutableAttributedString(string: text,
                attributes: [.font: font.nativeFont(size: CGFloat(size))])
            for reading in readings where reading.start >= 0 && reading.count > 0
                && reading.start <= characters.count && reading.count <= characters.count - reading.start {
                let range = indices[reading.start]..<indices[reading.start + reading.count]
                attributed.addAttribute(.font, value: font.nativeFont(size: CGFloat(size), salt: reading.salt),
                                        range: NSRange(range, in: text))
            }
            let fullSize = attributed.size()
            if fullSize.width <= viewport.width - 2, fullSize.height <= viewport.height {
                return LyricLinePresentation(fontSize: CGFloat(size), breakOffset: nil)
            }
            guard fullSize.height * 2 + 6 <= viewport.height else { continue }
            guard fullSize.width <= viewport.width * 2 + CGFloat(size) else { continue }
            var best: (offset: Int, score: Double)?
            for candidate in candidates {
                let split = indices[candidate.offset]
                let first = String(text[..<split])
                let second = String(text[split...])
                guard !first.isEmpty, !second.isEmpty else { continue }
                let firstWidth = attributed.attributedSubstring(from: NSRange(text.startIndex..<split, in: text)).size().width
                let secondWidth = attributed.attributedSubstring(from: NSRange(split..<text.endIndex, in: text)).size().width
                guard max(firstWidth, secondWidth) <= viewport.width - 2 else { continue }
                let imbalance = Double(abs(firstWidth - secondWidth) / max(firstWidth, secondWidth))
                let score = imbalance + candidate.penalty
                if best == nil || score < best!.score { best = (candidate.offset, score) }
            }
            if let best { return LyricLinePresentation(fontSize: CGFloat(size), breakOffset: best.offset) }
        }
        // Extremely long text retains the existing minimum font and vertical scrolling.
        return nil
    }
}
