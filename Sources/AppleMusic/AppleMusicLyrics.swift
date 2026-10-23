import Foundation

/// Display-only lyrics from the current Apple Music song; never stored as local lyrics.
struct AppleMusicLyrics: Equatable, Sendable {
    var songID: String
    var text: String
    var lines: [TimedLyricLine]
    var languages: [String] = []
    var readings: LyricReadings? = nil
}

enum AppleMusicLyricsParser {
    enum ParseError: Error { case invalidXML }

    enum FetchError: Error, LocalizedError, Equatable {
        case invalidResponse
        case missingData
        case invalidDocument
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "選択中の曲に対応する歌詞データを取得できませんでした。"
            case .missingData: return "歌詞データを取得できませんでした。もう一度お試しください。"
            case .invalidDocument: return "取得した歌詞データを読み取れませんでした。"
            case .emptyDocument: return "取得した歌詞データに本文がありません。"
            }
        }
    }

    /// A missing document is an unavailable lyric only when the catalog says so.
    static func parseResponse(_ response: [String: Any], songID: String) throws -> AppleMusicLyrics? {
        guard response["songID"] as? String == songID else { throw FetchError.invalidResponse }
        if let value = response["ttml"], !(value is NSNull), !(value is String) {
            throw FetchError.invalidResponse
        }
        if let ttml = response["ttml"] as? String, !ttml.isEmpty {
            let lyrics: AppleMusicLyrics
            do { lyrics = try parse(ttml: ttml, songID: songID) }
            catch { throw FetchError.invalidDocument }
            guard !lyrics.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FetchError.emptyDocument
            }
            return lyrics
        }
        if let hasLyrics = response["hasLyrics"] as? Bool, !hasLyrics { return nil }
        throw FetchError.missingData
    }

    static func parse(ttml: String, songID: String) throws -> AppleMusicLyrics {
        let delegate = LyricsDelegate()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        return AppleMusicLyrics(songID: songID, text: delegate.paragraphs.joined(separator: "\n"),
                                lines: delegate.lines, languages: delegate.languages)
    }

    /// TTML clock-time and the second/millisecond offsets used in song lyrics.
    private static func time(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let result: Double?
        if value.hasSuffix("ms") {
            result = Double(value.dropLast(2)).map { $0 / 1_000 }
        } else if value.hasSuffix("s") {
            result = Double(value.dropLast())
        } else {
            let components = value.split(separator: ":", omittingEmptySubsequences: false)
            if components.count == 2 || components.count == 3 {
                let numbers = components.compactMap { Double($0) }
                guard numbers.count == components.count,
                      numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      numbers.last! < 60,
                      numbers.dropLast().allSatisfy({ $0.rounded(.towardZero) == $0 }),
                      components.count == 2 || numbers[1] < 60 else { return nil }
                result = numbers.reduce(0) { $0 * 60 + $1 }
            } else {
                result = Double(value)
            }
        }
        guard let result, result.isFinite, result >= 0 else { return nil }
        return result
    }

    private struct Interval: Equatable {
        var start: Double
        var end: Double

        init?(_ attributes: [String: String]) {
            guard let start = time(attributes["begin"]), let end = time(attributes["end"]), end >= start else { return nil }
            self.start = start
            self.end = end
        }
    }

    private struct Element {
        var timing: Interval?
        var preserveSpace: Bool
        var isInBody: Bool
    }

    private struct Scalar {
        var value: Unicode.Scalar
        var timing: Interval?
        var preserveSpace: Bool
    }

    private struct CharacterToken {
        var character: Character
        var timing: Interval?
        var preserveSpace: Bool
    }

    private final class LyricsDelegate: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        var lines: [TimedLyricLine] = []
        var languages: [String] = []
        private var stack: [Element] = []
        private var paragraphDepth: Int?
        private var paragraphTiming: Interval?
        private var scalars: [Scalar] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let inherited = stack.last
            let isInBody = name == "body" || inherited?.isInBody == true
            if (stack.isEmpty && name == "tt") || isInBody,
               let language = attributes["xml:lang"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !language.isEmpty, !languages.contains(language) {
                languages.append(language)
            }
            let preserve = attributes["xml:space"].map { $0 == "preserve" } ?? inherited?.preserveSpace ?? false
            var timing = inherited?.timing
            if name == "p" {
                paragraphDepth = stack.count
                paragraphTiming = Interval(attributes)
                scalars = []
                timing = nil // Paragraph timing is not a word or character timestamp.
            } else if name == "span", attributes["begin"] != nil || attributes["end"] != nil {
                timing = Interval(attributes)
            }
            stack.append(Element(timing: timing, preserveSpace: preserve, isInBody: isInBody))
            if name == "br", paragraphDepth != nil {
                scalars.append(Scalar(value: "\n", timing: timing, preserveSpace: true))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard paragraphDepth != nil else { return }
            let element = stack.last
            scalars.append(contentsOf: string.unicodeScalars.map {
                Scalar(value: $0, timing: element?.timing, preserveSpace: element?.preserveSpace ?? false)
            })
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if paragraphDepth == stack.count - 1 {
                finishParagraph()
                paragraphDepth = nil
                scalars = []
            }
            _ = stack.popLast()
        }

        private func finishParagraph() {
            // Form Characters only after joining XML callbacks, which can split a grapheme.
            let raw = String(String.UnicodeScalarView(scalars.map(\.value)))
            var offset = 0
            var tokens: [CharacterToken] = []
            var pendingSpace: CharacterToken?
            for character in raw {
                let count = character.unicodeScalars.count
                let parts = scalars[offset..<(offset + count)]
                offset += count
                let first = parts.first!
                let timing = parts.allSatisfy({ $0.timing == first.timing }) ? first.timing : nil
                let preserve = parts.contains(where: \.preserveSpace)
                let token = CharacterToken(character: character, timing: timing, preserveSpace: preserve)
                let collapsible = character.unicodeScalars.allSatisfy { " \t\r\n".unicodeScalars.contains($0) }
                if collapsible && !preserve {
                    if pendingSpace == nil { pendingSpace = CharacterToken(character: " ", timing: timing, preserveSpace: false) }
                    else if pendingSpace?.timing != timing { pendingSpace?.timing = nil }
                    continue
                }
                if let space = pendingSpace, !tokens.isEmpty, tokens.last?.character != "\n", character != "\n" {
                    tokens.append(space)
                }
                pendingSpace = nil
                tokens.append(token)
            }
            let text = String(tokens.map(\.character))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let ordinal = paragraphs.count
            paragraphs.append(text)
            guard let interval = paragraphTiming else { return }
            // Separators have no sung duration. Keep real word times even when
            // TTML places spaces or breaks outside its timed spans.
            let firstStart = tokens.compactMap(\.timing).first?.start
            var previousEnd: Double?
            let timings: [LyricCharacterTiming?] = tokens.map { token in
                if let timing = token.timing {
                    previousEnd = timing.end
                    return LyricCharacterTiming(start: timing.start, end: timing.end)
                }
                guard token.character.isWhitespace, let boundary = previousEnd ?? firstStart else { return nil }
                return LyricCharacterTiming(start: boundary, end: boundary)
            }
            let allTimed = timings.allSatisfy { timing in
                guard let timing else { return false }
                return timing.start >= interval.start && timing.end <= interval.end
            }
            let characterTimings = allTimed ? timings.compactMap { $0 } : []
            lines.append(TimedLyricLine(id: "apple-music-\(ordinal)", ordinal: ordinal, text: text,
                                       start: interval.start, end: interval.end, textWeight: Double(text.count),
                                       confidence: 1, characterTimings: characterTimings))
        }
    }
}
