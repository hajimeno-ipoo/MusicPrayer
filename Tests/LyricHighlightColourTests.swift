import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class LyricHighlightColourTests: XCTestCase {
    @MainActor
    func testRequestedPaletteKeepsTheExistingCyanAndAllThirteenAdditionalColours() throws {
        let expected: [(LyricHighlightColour, Double, Double, Double)] = [
            (.cyan, 0.24, 0.87, 1),
            (.red, 255 / 255, 82 / 255, 82 / 255),
            (.coralRed, 255 / 255, 107 / 255, 107 / 255),
            (.rose, 255 / 255, 92 / 255, 138 / 255),
            (.pink, 255 / 255, 122 / 255, 200 / 255),
            (.apricot, 255 / 255, 170 / 255, 92 / 255),
            (.gold, 255 / 255, 209 / 255, 102 / 255),
            (.mintGreen, 104 / 255, 230 / 255, 166 / 255),
            (.blue, 102 / 255, 166 / 255, 255 / 255),
            (.purple, 179 / 255, 136 / 255, 255 / 255),
            (.skyCyan, 0, 207 / 255, 255 / 255),
            (.lightBlue, 77 / 255, 203 / 255, 255 / 255),
            (.turquoise, 50 / 255, 214 / 255, 208 / 255),
            (.aquaMint, 77 / 255, 232 / 255, 212 / 255)
        ]
        XCTAssertEqual(LyricHighlightColour.allCases, expected.map(\.0))
        XCTAssertEqual(EnvironmentValues().lyricHighlightColour, .cyan)
        for (option, red, green, blue) in expected {
            let color = try XCTUnwrap(NSColor(option.color).usingColorSpace(.sRGB))
            XCTAssertEqual(color.redComponent, red, accuracy: 1e-6, option.rawValue)
            XCTAssertEqual(color.greenComponent, green, accuracy: 1e-6, option.rawValue)
            XCTAssertEqual(color.blueComponent, blue, accuracy: 1e-6, option.rawValue)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 1e-6, option.rawValue)
            XCTAssertEqual(LyricHighlightColour(rawValue: option.id), option)
            XCTAssertFalse(option.title.isEmpty)
        }
    }

    @MainActor
    func testSelectedColourChangesRenderedHighlightWithoutChangingGlyphShapeOrProgress() throws {
        _ = NSApplication.shared
        let text = "COLOR"
        let timings = text.enumerated().map { index, _ in
            LyricCharacterTiming(start: index < 2 ? 1 : 3, end: index < 2 ? 2 : 4)
        }
        let line = TimedLyricLine(id: "highlight-colour", ordinal: 0, text: text,
            start: 1, end: 4, textWeight: 5, confidence: 1, characterTimings: timings)
        let motion = LyricMotionParameters(opacity: 1, scale: 1, blur: 0, x: 0, y: 0,
            progress: 0, glowOpacity: 0, glowRadius: 0)
        func render(_ colour: LyricHighlightColour, time: Double) throws -> [UInt8] {
            let renderer = ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: timings,
                motion: motion, time: time, viewport: CGSize(width: 400, height: 100), font: .system,
                columnStyle: true)
                .environment(\.lyricHighlightColour, colour)
                .frame(width: 400, height: 100))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func count(_ bytes: [UInt8], matching predicate: (Int, Int, Int) -> Bool) -> Int {
            stride(from: 0, to: bytes.count, by: 4).filter {
                predicate(Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2]))
            }.count
        }
        let initialRed = try render(.red, time: 0)
        let initialBlue = try render(.blue, time: 0)
        XCTAssertEqual(initialRed, initialBlue, "歌唱前の白い文字は選択色によって変わらないこと")
        let red = try render(.red, time: 2.5)
        let blue = try render(.blue, time: 2.5)
        let isRed: (Int, Int, Int) -> Bool = { $0 > $1 + 40 && $0 > $2 + 40 }
        let isBlue: (Int, Int, Int) -> Bool = { $2 > $0 + 40 && $2 > $1 + 40 }
        let redCount = count(red, matching: isRed)
        XCTAssertGreaterThan(redCount, 20, "進行済みの文字が選択した赤になること")
        XCTAssertGreaterThan(count(blue, matching: isBlue), 20, "進行済みの文字が選択した青になること")
        XCTAssertEqual(count(red, matching: isBlue), 0)
        XCTAssertEqual(count(blue, matching: isRed), 0)
        let alpha = { (bytes: [UInt8]) in stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }
        XCTAssertEqual(alpha(red), alpha(blue), "色の選択で文字の形や位置が変わらないこと")
        XCTAssertGreaterThan(count(try render(.red, time: 5), matching: isRed), redCount,
                             "元の文字時刻どおり、後続文字へ色が進むこと")
        XCTAssertEqual(line.characterTimings, timings)
    }
}
