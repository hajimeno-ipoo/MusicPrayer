import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class PlayerGlassWindowTests: XCTestCase {
    @MainActor
    func testSystemAppearanceUsesSystemEnvironmentOnFirstSwitchFromDark() async throws {
        _ = NSApplication.shared
        let store = PlayerStore()
        func content(_ appearance: PlayerAppearance, system: ColorScheme) -> some View {
            PlayerGlassContainer(store: store, appearance: appearance)
                .environment(\.colorScheme, system)
        }
        let hosting = NSHostingView(rootView: content(.dark, system: .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The containing window can still have the previous SwiftUI preference
        // when the native representable receives the new system selection.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer { window.close(); store.engine.stop() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let glass = try XCTUnwrap(findGlass(in: hosting))
        let container = try XCTUnwrap(glass.contentView as? PlayerGlassBackdropView)
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(container.backdrop.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertNotNil(glass.tintColor)

        hosting.rootView = content(.system, system: .light)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua,
                       "Returning to system must use the light system environment on the first selection.")
        XCTAssertNil(glass.tintColor, "The previous dark tint must be removed in the same update.")
        XCTAssertEqual(container.backdrop.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        window.appearance = NSAppearance(named: .aqua)
        hosting.rootView = content(.system, system: .dark)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(glass.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
                       "System mode must also follow a subsequent change to the dark system environment.")
        XCTAssertNotNil(glass.tintColor)
        XCTAssertEqual(container.backdrop.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    @MainActor
    private func findGlass(in view: NSView) -> PlayerGlassEffectView? {
        if let glass = view as? PlayerGlassEffectView { return glass }
        for child in view.subviews {
            if let glass = findGlass(in: child) { return glass }
        }
        return nil
    }

    @MainActor
    func testGlassKeepsWindowTransparentAndContentFillsResizedWindow() async throws {
        _ = NSApplication.shared
        let glass = PlayerGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = 20
        let hosting = NSHostingView(rootView: Color.clear)
        hosting.sizingOptions = []
        let container = PlayerGlassBackdropView(hosting: hosting)
        glass.contentView = container
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
            XCTAssertEqual(container.frame.width, glass.bounds.width, accuracy: 0.5)
            XCTAssertEqual(container.frame.height, glass.bounds.height, accuracy: 0.5)
            XCTAssertEqual(container.frame.minX, glass.bounds.minX, accuracy: 0.5)
            XCTAssertEqual(container.frame.minY, glass.bounds.minY, accuracy: 0.5)
            for view: NSView in [container.backdrop, hosting] {
                XCTAssertEqual(view.frame.width, container.bounds.width, accuracy: 0.5)
                XCTAssertEqual(view.frame.height, container.bounds.height, accuracy: 0.5)
                XCTAssertEqual(view.frame.minX, container.bounds.minX, accuracy: 0.5)
                XCTAssertEqual(view.frame.minY, container.bounds.minY, accuracy: 0.5)
            }
            let hit = try XCTUnwrap(glass.hitTest(NSPoint(x: glass.bounds.midX,
                                                        y: glass.bounds.midY)))
            XCTAssertTrue(hit === glass || hit.isDescendant(of: glass),
                          "The foreground glass must remain on the native drag destination path.")
            XCTAssertTrue(glass.registeredDraggedTypes.contains(.fileURL))
        }
    }
}
