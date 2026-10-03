import CryptoKit
import Foundation

enum LyricParser {
    static func parse(_ sourceText: String) -> [LyricLine] {
        // Split only for parsing; sourceText itself is persisted without normalization.
        let rows = sourceText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var lines: [LyricLine] = []
        var paragraphBoundary = false
        for row in rows {
            if row.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                paragraphBoundary = !lines.isEmpty
                continue
            }
            let weight = row.reduce(0.0) { $0 + characterWeight($1) }
            lines.append(LyricLine(ordinal: lines.count, text: row,
                                   paragraphStart: paragraphBoundary, textWeight: weight))
            paragraphBoundary = false
        }
        return lines
    }

    static func characterWeight(_ character: Character) -> Double {
        let hasVisibleContent = character.unicodeScalars.contains { scalar in
            if scalar.properties.isWhitespace { return false }
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation, .control, .format:
                return false
            default:
                return true
            }
        }
        return hasVisibleContent ? 1 : 0
    }
}

enum LyricHash {
    static func text(_ text: String) -> String {
        digest(Data(text.utf8))
    }

    static func lineID(audioFingerprint: String, version: Int,
                       sourceTextHash: String, ordinal: Int) -> String {
        var bytes = Data()
        for value in [audioFingerprint, String(version), sourceTextHash, String(ordinal)] {
            let component = Data(value.utf8)
            var length = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(component)
        }
        return digest(bytes)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
