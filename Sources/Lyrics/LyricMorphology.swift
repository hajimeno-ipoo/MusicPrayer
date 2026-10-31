import CoreFoundation
import Foundation

/// Word boundaries and readings are computed once, while preparing lyrics.
/// This uses the macOS dictionary; it does not run from a rendering view.
struct LyricMorphology {
    struct Token: Equatable {
        var start: Int
        var text: String
        var reading: String
    }

    static func tokens(in text: String) throws -> [Token] {
        let locale = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: "ja_JP" as CFString))
        guard let tokenizer = CFStringTokenizerCreate(nil, text as CFString,
            CFRange(location: 0, length: (text as NSString).length),
            kCFStringTokenizerUnitWord | kCFStringTokenizerAttributeLatinTranscription, locale) else { return [] }
        var result: [Token] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            try Task.checkCancellation()
            let raw = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let range = Range(NSRange(location: raw.location, length: raw.length), in: text),
                  let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer,
                    kCFStringTokenizerAttributeLatinTranscription) as? String else { continue }
            let word = String(text[range])
            guard word.unicodeScalars.contains(where: isHan) else { continue }
            let reading = NSMutableString(string: latin)
            guard CFStringTransform(reading, nil, kCFStringTransformLatinHiragana, false) else { continue }
            let kana = (reading as String).precomposedStringWithCanonicalMapping
            guard !kana.isEmpty, kana.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) }) else { continue }
            result.append(Token(start: text.distance(from: text.startIndex, to: range.lowerBound), text: word, reading: kana))
        }
        return result
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        // The same script property used by the existing okurigana resolver, including rare CJK characters.
        String(scalar).range(of: "^\\p{sc=Han}$", options: .regularExpression) != nil
    }
}

/// Align a token's whole reading against existing font candidates and literal kana.
/// Only a unique, fully consumed alignment is usable; no invented reading or proportional split.
struct LyricReadingAlignment {
    struct Part {
        var start: Int
        var count: Int
        var choices: [(reading: String, salt: Int)]
    }

    static func match(reading: String, parts: [Part]) -> [LyricReading]? {
        let kana = Array(reading)
        var cache: [String: [[LyricReading]]] = [:]
        func paths(_ part: Int, _ offset: Int) -> [[LyricReading]] {
            if part == parts.count { return offset == kana.count ? [[]] : [] }
            let key = "\(part):\(offset)"
            if let saved = cache[key] { return saved }
            let current = parts[part]
            var results: [[LyricReading]] = []
            for choice in current.choices {
                let value = Array(choice.reading)
                guard !value.isEmpty, offset + value.count <= kana.count,
                      kana[offset..<(offset + value.count)].elementsEqual(value) else { continue }
                for tail in paths(part + 1, offset + value.count) {
                    let head = choice.salt == 0 ? [] : [LyricReading(start: current.start, count: current.count, salt: choice.salt)]
                    let path = head + tail
                    if !results.contains(path) { results.append(path) }
                    if results.count == 2 { break }
                }
                if results.count == 2 { break }
            }
            cache[key] = results
            return results
        }
        let matches = paths(0, 0)
        return matches.count == 1 ? matches[0] : nil
    }
}
