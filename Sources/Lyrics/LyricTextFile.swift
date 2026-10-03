import Foundation
import UniformTypeIdentifiers

enum LyricTextFile {
    enum ImportError: LocalizedError {
        case singleFileRequired
        case plainTextRequired
        case unreadableText

        var errorDescription: String? {
            switch self {
            case .singleFileRequired: return "歌詞のテキストファイルを1つ選んでください。"
            case .plainTextRequired: return "歌詞は.txtなどのプレーンテキストファイルで読み込んでください。"
            case .unreadableText: return "文字を読み取れませんでした。UTF-8またはUTF-16で保存してください。"
            }
        }
    }

    static func read(_ urls: [URL]) throws -> String {
        guard urls.count == 1, let url = urls.first else { throw ImportError.singleFileRequired }
        guard url.isFileURL else { throw ImportError.plainTextRequired }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true,
              values.contentType?.conforms(to: .plainText) == true else {
            throw ImportError.plainTextRequired
        }
        let data = try Data(contentsOf: url)
        let encoding: String.Encoding
        let body: Data
        if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            body = Data(data.dropFirst(2))
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            body = Data(data.dropFirst(2))
        } else {
            encoding = .utf8
            body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        }
        guard let text = String(data: body, encoding: encoding), !text.contains("\0") else {
            throw ImportError.unreadableText
        }
        return LyricInput.clean(text)
    }
}
