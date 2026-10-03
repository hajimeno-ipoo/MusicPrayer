import Foundation

enum LyricInput {
    private static let metadata = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:\[[^\[\]\r\n]*\][ \t]*)+(?:\r\n|\r|\n|$)|\[[^\[\]\r\n]*\]"#,
        options: [.anchorsMatchLines]
    )

    static func clean(_ source: String) -> String {
        clean(source, selection: NSRange(location: 0, length: 0)).text
    }

    /// Selection offsets use UTF-16, matching NSTextView even with emoji.
    static func clean(_ source: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let range = NSRange(location: 0, length: source.utf16.count)
        let matches = metadata.matches(in: source, range: range)
        let text = NSMutableString(string: source)
        for match in matches.reversed() {
            text.deleteCharacters(in: match.range)
        }

        func adjusted(_ offset: Int) -> Int {
            var removed = 0
            for match in matches where offset > match.range.location {
                removed += min(offset - match.range.location, match.range.length)
            }
            return offset - removed
        }

        let start = adjusted(selection.location)
        let end = adjusted(NSMaxRange(selection))
        return (text as String, NSRange(location: start, length: end - start))
    }
}
