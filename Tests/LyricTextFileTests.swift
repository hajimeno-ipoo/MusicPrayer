import Foundation
import XCTest
@testable import MusicPrayer

final class LyricTextFileTests: XCTestCase {
    func testImportedMetadataIsRemovedWithoutChangingTheOriginalFile() throws {
        let data = Data("[Verse]\r\n朝の光\r\n\r\n[Chorus]\r\n感謝🌸\r\n".utf8)
        try withFile(data) { url in
            XCTAssertEqual(try LyricTextFile.read([url]), "朝の光\r\n\r\n感謝🌸\r\n")
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testUTF8PreservesWhitespaceLineBreaksAndUnicode() throws {
        let source = "  朝の光  \r\n\r\ne\u{301}と🌸\n"
        try withFile(Data(source.utf8)) { url in
            XCTAssertEqual(Array(try LyricTextFile.read([url]).utf8), Array(source.utf8))
        }
    }

    func testUnicodeByteOrderMarksDoNotBecomeLyrics() throws {
        let source = "歌詞の一行目\n次の行🌸"
        for (bom, encoding) in [([UInt8](arrayLiteral: 0xEF, 0xBB, 0xBF), String.Encoding.utf8),
                                ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)] {
            let data = Data(bom) + (try XCTUnwrap(source.data(using: encoding)))
            try withFile(data) { url in XCTAssertEqual(try LyricTextFile.read([url]), source) }
        }
    }

    func testRejectsRichTextDirectoriesAndMultipleFiles() throws {
        try withFile(Data("{\\rtf1 text}".utf8), extension: "rtf") { url in
            XCTAssertThrowsError(try LyricTextFile.read([url]))
        }
        try withFile(Data("本文".utf8)) { url in
            XCTAssertThrowsError(try LyricTextFile.read([url, url]))
            XCTAssertThrowsError(try LyricTextFile.read([url.deletingLastPathComponent()]))
            XCTAssertThrowsError(try LyricTextFile.read([URL(string: "https://example.com/lyrics.txt")!]))
        }
    }

    func testUnreadableMissingAndBinaryFilesFail() throws {
        for bytes: [UInt8] in [[0xFF, 0x80], [0, 1, 2], [0xFF, 0xFE, 0x00, 0xD8]] {
            try withFile(Data(bytes)) { url in XCTAssertThrowsError(try LyricTextFile.read([url])) }
        }
        try withFile(Data("本文".utf8)) { url in
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try LyricTextFile.read([url]))
        }
    }

    func testEmptyTextFileCanBeEditedBeforeApplying() throws {
        try withFile(Data()) { url in XCTAssertEqual(try LyricTextFile.read([url]), "") }
    }

    private func withFile(_ data: Data, extension ext: String = "txt", body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LyricTextFileTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lyrics.\(ext)")
        try data.write(to: url)
        try body(url)
    }
}
