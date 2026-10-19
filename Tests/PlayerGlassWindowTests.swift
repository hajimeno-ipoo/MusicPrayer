import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class PlayerGlassWindowTests: XCTestCase {
    @MainActor
    func testGlassKeepsWindowTransparentAndContentFillsResizedWindow() async throws {
        _ = NSApplication.shared
        let glass = PlayerGlassEffectView()
        glass.style = .clear
        let hosting = NSHostingView(rootView: Color.clear)
        hosting.sizingOptions = []
        glass.contentView = hosting
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 900),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = glass
        defer { window.close() }

        for size in [NSSize(width: 1160, height: 900), NSSize(width: 860, height: 800)] {
            window.setContentSize(size)
            glass.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            glass.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 0)
            XCTAssertEqual(glass.bounds.width, size.width, accuracy: 0.5)
            XCTAssertEqual(glass.bounds.height, size.height, accuracy: 0.5)
            XCTAssertEqual(hosting.frame.width, glass.bounds.width, accuracy: 0.5)
            XCTAssertEqual(hosting.frame.height, glass.bounds.height, accuracy: 0.5)
            XCTAssertEqual(hosting.frame.minX, glass.bounds.minX, accuracy: 0.5)
            XCTAssertEqual(hosting.frame.minY, glass.bounds.minY, accuracy: 0.5)
        }
    }
}
