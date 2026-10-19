import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import MusicPrayer

final class PlayerDropRoutingTests: XCTestCase {
    @MainActor
    func testEmptyPlayerAcceptsNativeFileDragThroughItsWindowHierarchy() async throws {
        try await verifyFileDrop(appleMusicActive: false)
    }

    @MainActor
    func testAppleMusicPlayerAcceptsNativeFileDragWithoutChangingSelectedSong() async throws {
        try await verifyFileDrop(appleMusicActive: true)
    }

    @MainActor
    private func verifyFileDrop(appleMusicActive: Bool) async throws {
        _ = NSApplication.shared
        let queue = try? Data(contentsOf: QueuePersistence.file)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ドロップ確認.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            try writer.write(from: buffer)
        }
        let store = PlayerStore(lyricDirectory: directory.appendingPathComponent("Lyrics"), appleMusicAnalysisDirectory: directory.appendingPathComponent("AppleMusic"))
        store.appleMusic.preanalysis.operation = { _ in }
        if appleMusicActive {
            let song = AppleMusicSong(id: "123456", title: "配信曲", artist: "", album: "", duration: 180)
            store.tracks = [Track(appleMusicSong: song)]
            store.isAppleMusicActive = true
            store.position = 33; store.duration = song.duration
            let native = store.appleMusic.webViewForDisplay()
            native.stopLoading()
            let browser = store.appleMusicBrowser.webViewForDisplay()
            browser.stopLoading()
        }
        let selected = store.currentQueueTrack?.id
        let host = NSHostingView(rootView: PlayerGlassContainer(store: store, usesDarkAppearance: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; store.shutdown()
            if let queue { try? queue.write(to: QueuePersistence.file) }
            else { try? FileManager.default.removeItem(at: QueuePersistence.file) }
            try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let drag = PlayerRoutingDrag(window: window, url: url)
        var view = host.hitTest(NSPoint(x: 430, y: 400))
        var registeredAncestor: NSView?
        while let candidate = view {
            if candidate.registeredDraggedTypes.contains(.fileURL) {
                registeredAncestor = candidate
                break
            }
            view = candidate.superview
        }
        let destination = try XCTUnwrap(registeredAncestor, "ドラッグ位置からウインドウまでにファイルを受け取るビューが必要")
        XCTAssertEqual(destination.draggingEntered(drag), .copy)
        XCTAssertEqual(destination.draggingUpdated(drag), .copy)
        XCTAssertEqual(store.tracks.count, appleMusicActive ? 1 : 0, "ドロップ確定前には追加しない")
        XCTAssertTrue(destination.prepareForDragOperation(drag))
        XCTAssertTrue(destination.performDragOperation(drag))
        for _ in 0..<150 {
            if store.tracks.first(where: { $0.url == url })?.duration ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.tracks.count, appleMusicActive ? 2 : 1)
        XCTAssertTrue(store.tracks.contains { $0.url == url && $0.duration > 0 })
        XCTAssertNil(store.playbackError)
        XCTAssertFalse(store.isPlaying)
        if appleMusicActive {
            XCTAssertTrue(store.isAppleMusicActive)
            XCTAssertEqual(store.currentQueueTrack?.id, selected)
            XCTAssertEqual(store.position, 33)
        } else {
            XCTAssertEqual(store.currentTrack?.url, url)
        }
    }
}

@MainActor
private final class PlayerRoutingDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingDestinationWindow: NSWindow?
    init(window: NSWindow, url: URL) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.writeObjects([url as NSURL])
    }
    deinit { draggingPasteboard.releaseGlobally() }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 430, y: 400) }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 42 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
