import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class TimedLyricReadingTests: XCTestCase {
    private var lines: [TimedLyricLine] {
        (0..<10).map { i in
            TimedLyricLine(id: "row-\(i)", ordinal: i, text: "繰り返す歌詞の行",
                start: Double(i * 4 + 1), end: Double(i * 4 + 4), textWeight: 8, confidence: 1)
        }
    }

    func testPositionUsesOccurrenceAndReturnsAfterSeeking() {
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 0), "row-0")
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 25), "row-6")
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 1), "row-0")
        XCTAssertNil(LyricReadingPosition.currentID(in: [], at: 1))
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: .nan))
    }

    @MainActor
    func testColumnKeepsColourProgressAndRestoresItAfterSeek() throws {
        let text = "歌詞の色変化"
        let row = TimedLyricLine(id: "colour", ordinal: 0, text: text, start: 1, end: 4,
            textWeight: Double(text.count), confidence: 1,
            characterTimings: text.enumerated().map { index, _ in
                LyricCharacterTiming(start: 1 + Double(index) * 0.4, end: 1.4 + Double(index) * 0.4)
            })
        func render(_ time: Double, font: LyricFont) throws -> Data {
            let motion = LyricMotionParameters(opacity: 1, scale: 1, blur: 0, x: 0, y: 0,
                progress: 0, glowOpacity: 0, glowRadius: 0)
            let renderer = ImageRenderer(content: LyricMotionLineView(line: row,
                colourTimings: row.characterTimings, motion: motion, time: time,
                viewport: CGSize(width: 440, height: 100), font: font, columnStyle: true)
                .frame(width: 440, height: 100).background(.black))
            return try XCTUnwrap(renderer.cgImage?.dataProvider?.data) as Data
        }
        for font in LyricFont.allCases {
            let initial = try render(1, font: font)
            XCTAssertFalse(initial == (try render(3, font: font)))
            XCTAssertTrue(initial == (try render(1, font: font)))
        }
    }

    @MainActor
    func testCurrentRowScrollsForwardAndBackWithoutShowingScroller() async throws {
        _ = NSApplication.shared
        func content(_ time: Double) -> some View {
            TimedLyricReadingView(lines: lines, time: time, viewport: CGSize(width: 440, height: 300),
                onSeek: { _ in }).frame(width: 440, height: 300)
        }
        let host = NSHostingView(rootView: content(1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap(find).first
        }
        let scroll = try XCTUnwrap(find(host))
        let initial = scroll.contentView.bounds.origin.y
        host.rootView = content(25)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, initial + 100)
        XCTAssertFalse(scroll.hasVerticalScroller)
        host.rootView = content(1)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, initial, accuracy: 2)
    }
}
