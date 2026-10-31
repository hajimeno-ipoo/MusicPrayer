import XCTest
import SwiftUI
import AppKit
@testable import MusicPrayer

final class PlayerContentDisplayTests: XCTestCase {
    func testRequestedPressOrderRepeatsAfterInitialCombinedDisplay() {
        var display = PlayerContentDisplay.initial
        XCTAssertTrue(display.showsArtwork)
        XCTAssertTrue(display.showsLyrics)
        XCTAssertFalse(display.showsVisualizer)
        XCTAssertFalse(display.showsCompactArtwork)
        let expected = [(true, false), (true, true), (false, true), (false, false),
                        (true, false), (true, true), (false, true), (false, false)]
        for (artwork, lyrics) in expected {
            display = display.next
            XCTAssertEqual(display.showsArtwork, artwork)
            XCTAssertEqual(display.showsLyrics, lyrics)
            XCTAssertEqual(display.showsVisualizer, !artwork)
            XCTAssertEqual(display.showsCompactArtwork, !artwork)
            XCTAssertFalse(display.title.isEmpty)
        }
    }

    @MainActor
    func testVisualizerIsAbsentForCoversAndFillsStageInVisualizerOnlyMode() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 1000, height: 850)
        for display in [PlayerContentDisplay.initial, .artworkOnly, .artworkAndLyrics, .visualizerOnly] {
            let hosting = NSHostingView(rootView: PlayerVisualizerRegion(source: VisualFrameSource(), display: display,
                                                                         size: size, headerHeight: 58, backgroundOpacity: 0)
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            if display == .visualizerOnly {
                let visualizer = try XCTUnwrap(findVisualizer(in: hosting))
                let frame = hosting.convert(visualizer.bounds, from: visualizer)
                XCTAssertEqual(frame.width, size.width, accuracy: 1)
                XCTAssertEqual(frame.height, size.height, accuracy: 1)
            } else {
                XCTAssertNil(findVisualizer(in: hosting))
            }
            window.close()
        }
    }

    @MainActor
    private func findVisualizer(in view: NSView) -> VisualizerHostView? {
        if let visualizer = view as? VisualizerHostView { return visualizer }
        return view.subviews.compactMap { findVisualizer(in: $0) }.first
    }
}
