import Foundation

enum LyricInput {
    private static let horizontalWhitespace = CharacterSet(charactersIn: " \t　")
    private static let chordProgression: NSRegularExpression = {
        let root = #"[A-G][#♯b♭]?"#
        let chord = root
            + #"(?:(?:maj|Maj|M|min|m|dim|aug|[+°øΔ△-]))?(?:2|4|5|6|7|9|11|13)?"#
            + #"(?:(?:sus[24]?|add(?:2|4|6|9|11|13)|[#♯b♭](?:5|9|11|13)))*"#
            + "(?:/" + root + ")?"
        let separator = #"(?:[ \t　]+|[ \t　]*[|,、→-][ \t　]*)"#
        return try! NSRegularExpression(pattern: #"\A[ \t　]*"# + chord
            + "(?:" + separator + chord + #")*[ \t　]*\z"#)
    }()

    static func clean(_ source: String) -> String {
        clean(source, selection: NSRange(location: 0, length: 0)).text
    }

    /// Selection offsets use UTF-16, matching NSTextView even with emoji.
    static func clean(_ source: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let metadata = metadataRanges(in: source)
        let removals = (metadata.removed + chordRanges(in: source)
                        + barChordRanges(in: source, ignoring: metadata.removed))
            .filter { removal in
                !metadata.retained.contains { NSIntersectionRange(removal, $0).length > 0 }
            }
        // A chord may also sit inside a metadata tag. Count overlapping ranges once.
        var ranges: [NSRange] = []
        for removal in removals.sorted(by: { $0.location < $1.location }) {
            if let last = ranges.last, removal.location <= NSMaxRange(last) {
                ranges[ranges.count - 1].length = max(NSMaxRange(last), NSMaxRange(removal)) - last.location
            } else {
                ranges.append(removal)
            }
        }
        let text = NSMutableString(string: source)
        for range in ranges.reversed() {
            text.deleteCharacters(in: range)
        }

        func adjusted(_ offset: Int) -> Int {
            var removed = 0
            for range in ranges where offset > range.location {
                removed += min(offset - range.location, range.length)
            }
            return offset - removed
        }

        let start = adjusted(selection.location)
        let end = adjusted(NSMaxRange(selection))
        return (text as String, NSRange(location: start, length: end - start))
    }

    private static func metadataRanges(in source: String) -> (removed: [NSRange], retained: [NSRange]) {
        let text = source as NSString
        let units = Array(source.utf16)
        var groups: [(range: NSRange, isArray: Bool)] = []
        var retained: [NSRange] = []
        var depth = 0
        var start = 0
        var isSingleLine = true
        var isNested = false
        for (offset, unit) in units.enumerated() {
            switch unit {
            case 0x5B: // [
                if depth == 0 {
                    start = offset
                    isSingleLine = true
                    isNested = false
                } else {
                    isNested = true
                }
                depth += 1
            case 0x5D: // ]
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0 {
                    let range = NSRange(location: start, length: offset - start + 1)
                    if isSingleLine {
                        let body = text.substring(with: NSRange(location: start + 1, length: offset - start - 1))
                        let isArray = isNested || body.trimmingCharacters(
                            in: horizontalWhitespace.union(CharacterSet(charactersIn: ","))).isEmpty
                        groups.append((range, isArray))
                    } else {
                        retained.append(range)
                    }
                }
            case 0x0A...0x0D, 0x85, 0x2028, 0x2029:
                if depth > 0 { isSingleLine = false }
            default: break
            }
        }
        if depth > 0 {
            retained.append(NSRange(location: start, length: units.count - start))
        }

        var removed = groups.map { $0.range }
        var index = 0
        while index < groups.count {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: groups[index].range.location, length: 0))
            var cursor = lineStart
            var isMetadataLine = true
            while index < groups.count, groups[index].range.location < contentsEnd {
                let group = groups[index]
                let gap = text.substring(with: NSRange(location: cursor, length: group.range.location - cursor))
                if !gap.trimmingCharacters(in: horizontalWhitespace).isEmpty { isMetadataLine = false }
                cursor = NSMaxRange(group.range)
                // Only an otherwise metadata-only array line may consume its trailing comma.
                if group.isArray {
                    var comma = cursor
                    while comma < contentsEnd, units[comma] == 0x20 || units[comma] == 0x09 || units[comma] == 0x3000 {
                        comma += 1
                    }
                    if comma < contentsEnd, units[comma] == 0x2C { cursor = comma + 1 }
                }
                index += 1
            }
            let suffix = text.substring(with: NSRange(location: cursor, length: contentsEnd - cursor))
            if isMetadataLine, suffix.trimmingCharacters(in: horizontalWhitespace).isEmpty {
                removed.append(NSRange(location: lineStart, length: lineEnd - lineStart))
            }
        }
        return (removed, retained)
    }

    private static func barChordRanges(in source: String, ignoring metadata: [NSRange]) -> [NSRange] {
        let text = source as NSString
        let units = Array(source.utf16)
        let ignored = metadata.sorted { $0.location < $1.location }
        var ignoredIndex = 0
        var ranges: [NSRange] = []
        var offset = 0
        var parenthesisDepth = 0
        while offset < text.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: offset, length: 0))
            let isInsideParenthesis = parenthesisDepth > 0
            for position in lineStart..<lineEnd {
                while ignoredIndex < ignored.count, NSMaxRange(ignored[ignoredIndex]) <= position {
                    ignoredIndex += 1
                }
                if ignoredIndex < ignored.count, NSLocationInRange(position, ignored[ignoredIndex]) { continue }
                switch units[position] {
                case 0x28, 0xFF08: parenthesisDepth += 1
                case 0x29, 0xFF09:
                    if parenthesisDepth > 0 { parenthesisDepth -= 1 }
                default: break
                }
            }
            let body = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                .folding(options: .widthInsensitive, locale: nil)
            if !isInsideParenthesis, body.contains("|") {
                let chords = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t　|"))
                let range = NSRange(location: 0, length: chords.utf16.count)
                if chordProgression.firstMatch(in: chords, range: range) != nil {
                    ranges.append(NSRange(location: lineStart, length: lineEnd - lineStart))
                }
            }
            offset = lineEnd
        }
        return ranges
    }

    private static func chordRanges(in source: String) -> [NSRange] {
        let text = source as NSString
        var ranges: [NSRange] = []
        var depth = 0
        var start = 0
        var opening: UInt16 = 0
        var isSinglePair = false
        for (offset, unit) in source.utf16.enumerated() {
            switch unit {
            case 0x28, 0xFF08: // ( or （
                if depth == 0 {
                    start = offset
                    opening = unit
                    isSinglePair = true
                } else {
                    isSinglePair = false
                }
                depth += 1
            case 0x29, 0xFF09: // ) or ）
                guard depth > 0 else { continue }
                depth -= 1
                guard depth == 0, isSinglePair,
                      unit == (opening == 0x28 ? 0x29 : 0xFF09) else { continue }
                let body = text.substring(with: NSRange(location: start + 1, length: offset - start - 1))
                    .folding(options: .widthInsensitive, locale: nil)
                let bodyRange = NSRange(location: 0, length: body.utf16.count)
                if chordProgression.firstMatch(in: body, range: bodyRange) != nil {
                    ranges.append(NSRange(location: start, length: offset - start + 1))
                }
            case 0x0A, 0x0D:
                isSinglePair = false
            default: break
            }
        }
        return ranges
    }
}
