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
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: 0))
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 25), "row-6")
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 1), "row-0")
        XCTAssertNil(LyricReadingPosition.currentID(in: [], at: 1))
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: .nan))
    }

    func testIntroGapsAndOutroHaveNoCurrentRow() {
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: 0.999))
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 3.999), "row-0")
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: 4))
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: 4.999))
        XCTAssertEqual(LyricReadingPosition.currentID(in: lines, at: 5), "row-1")
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: 40))
        XCTAssertNil(LyricReadingPosition.currentID(in: lines, at: 100))
    }

    func testOfficialInterludeDoesNotHoldPreviousRowOrAnticipateNextRow() {
        // Saved official intervals for 暁の車; the reported screenshot is at 1:39.
        let rows = [
            TimedLyricLine(id: "before", ordinal: 0, text: "直前の行",
                start: 80.469, end: 94.218, textWeight: 4, confidence: 1),
            TimedLyricLine(id: "after", ordinal: 1, text: "次の行",
                start: 102.937, end: 111.583, textWeight: 3, confidence: 1)
        ]
        XCTAssertEqual(LyricReadingPosition.currentID(in: rows, at: 94.217), "before")
        for time in [94.218, 99, 102.936] {
            XCTAssertNil(LyricReadingPosition.currentID(in: rows, at: time))
        }
        XCTAssertEqual(LyricReadingPosition.currentID(in: rows, at: 102.937), "after")
        XCTAssertNil(LyricReadingPosition.currentID(in: rows, at: 99))
        XCTAssertEqual(LyricReadingPosition.currentID(in: rows, at: 90), "before")
    }

    func testPreparedLocalEntranceStillStopsAtRowEnd() {
        let row = TimedLyricLine(id: "local", ordinal: 0, text: "歌詞",
            start: 12.4, end: 14, textWeight: 2, confidence: 1)
        let starts = [0: 12.0]
        XCTAssertNil(LyricReadingPosition.currentID(in: [row], at: 11.999, displayStarts: starts))
        XCTAssertEqual(LyricReadingPosition.currentID(in: [row], at: 12, displayStarts: starts), "local")
        XCTAssertNil(LyricReadingPosition.currentID(in: [row], at: 14, displayStarts: starts))
    }

    func testRecognizedAppleMusicPrefixStartsWithOfficialRowWithoutMovingFollowingCharacters() {
        let timings: [LyricCharacterTiming] = [
            .init(start: 241.98, end: 242.16), .init(start: 242.16, end: 242.4),
            .init(start: 242.4, end: 242.76), .init(start: 242.76, end: 243.36),
            .init(start: 243.36, end: 243.78), .init(start: 243.36, end: 243.78),
            .init(start: 243.78, end: 244.44), .init(start: 244.44, end: 244.68)
        ]
        let row = TimedLyricLine(id: "apple-music-22", ordinal: 22, text: "暁の車を見送って",
            start: 238.187, end: 245.875, textWeight: 8, confidence: 0.6551724,
            characterTimings: timings, unrecognizedLeadingCharacters: 0)
        let colours = LyricMotion.colourTimings(for: row, displayStart: row.start,
            anchorsRecognizedPrefixToRow: true)
        XCTAssertEqual(colours[0].start, row.start)
        XCTAssertGreaterThan(LyricMotion.emphasis(time: 240, timing: colours[0]), 0)
        XCTAssertEqual(colours[0].end, timings[0].end)
        XCTAssertEqual(Array(colours.dropFirst()), Array(timings.dropFirst()))
        XCTAssertEqual(row.characterTimings, timings)
        XCTAssertEqual(LyricMotion.colourTimings(for: row, displayStart: nil), timings)
        var officialWords = row
        officialWords.unrecognizedLeadingCharacters = nil
        XCTAssertEqual(LyricMotion.colourTimings(for: officialWords, displayStart: row.start,
            anchorsRecognizedPrefixToRow: true), timings)
    }

    func testRecognizedAppleMusicMissingPrefixSharesOfficialEntranceGap() {
        let row = TimedLyricLine(id: "prefix", ordinal: 0, text: "ああ星海",
            start: 10, end: 16, textWeight: 4, confidence: 1,
            characterTimings: [.init(start: 12, end: 13), .init(start: 12, end: 13),
                               .init(start: 12, end: 13), .init(start: 14, end: 15)],
            unrecognizedLeadingCharacters: 2)
        let colours = LyricMotion.colourTimings(for: row, displayStart: row.start,
            anchorsRecognizedPrefixToRow: true)
        XCTAssertEqual(Array(colours.prefix(2)), [.init(start: 10, end: 12), .init(start: 10, end: 12)])
        XCTAssertEqual(Array(colours.dropFirst(2)), Array(row.characterTimings.dropFirst(2)))
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
