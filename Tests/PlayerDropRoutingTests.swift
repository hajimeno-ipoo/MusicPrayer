import AppKit
import AVFoundation
import SwiftUI
import WebKit
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
    func testEmptyPlayerRoutesAudioAndLyricsTogetherIntoSelectedSongAndEditor() async throws {
        try await verifyLyricDrop(includesAudio: true)
    }

    @MainActor
    func testAppleMusicPlayerRoutesAudioAndLyricsTogetherIntoLocalSongAndEditor() async throws {
        try await verifyLyricDrop(includesAudio: true, appleMusicActive: true)
    }

    @MainActor
    func testLocalPlayerWithRegisteredAppleMusicSongRoutesAudioAndLyricsIntoNewSongAndEditor() async throws {
        try await verifyLyricDrop(includesAudio: true, appleMusicRegistered: true)
    }

    @MainActor
    func testSelectedLocalSongRoutesLyricFileIntoEditor() async throws {
        try await verifyLyricDrop(includesAudio: false)
    }

    @MainActor
    func testInvisibleAppleMusicWebViewsStayOutsidePlayerDropAreaAndBrowserCanStillOpen() async throws {
        _ = NSApplication.shared
        let queue = try? Data(contentsOf: QueuePersistence.file)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PlayerStore(lyricDirectory: directory.appendingPathComponent("Lyrics"),
                                appleMusicAnalysisDirectory: directory.appendingPathComponent("AppleMusic"))
        store.appleMusic.preanalysis.operation = { _ in return .complete }
        let song = AppleMusicSong(id: "123456", title: "配信曲", artist: "", album: "", duration: 180)
        store.tracks = [Track(appleMusicSong: song)]
        store.isAppleMusicActive = true
        let playback = store.appleMusic.webViewForDisplay()
        let browser = store.appleMusicBrowser.webViewForDisplay()
        playback.stopLoading()
        browser.stopLoading()
        let host = NSHostingView(rootView: PlayerGlassContainer(store: store, appearance: .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
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
        func assertOutsidePlayerDropArea(_ view: WKWebView, _ message: String) {
            XCTAssertTrue(view.isDescendant(of: host), "WebViewを初期化したプレイヤーの階層で確認すること")
            let rect = view.convert(view.bounds, to: host)
            XCTAssertTrue(rect.isEmpty || !host.bounds.intersects(rect), message)
        }
        assertOutsidePlayerDropArea(playback, "透明な再生用WebViewがプレイヤーのドロップ領域を覆わないこと")
        assertOutsidePlayerDropArea(browser, "非表示の公式ブラウザーがプレイヤーのドロップ領域を覆わないこと")

        store.isAppleMusicBrowserVisible = true
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(browser.bounds.width, 0, "公式ブラウザーを開いたら表示幅が戻ること")
        XCTAssertGreaterThan(browser.bounds.height, 0, "公式ブラウザーを開いたら表示高さが戻ること")
        XCTAssertTrue(host.bounds.intersects(browser.convert(browser.bounds, to: host)),
                      "開いた公式ブラウザーはプレイヤー内に表示されること")
        assertOutsidePlayerDropArea(playback, "公式ブラウザーを表示しても再生用WebViewは領域を覆わないこと")
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
        store.appleMusic.preanalysis.operation = { _ in return .complete }
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
        let host = NSHostingView(rootView: PlayerGlassContainer(store: store, appearance: .dark))
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
        if appleMusicActive {
            XCTAssertTrue(store.appleMusic.webViewForDisplay().registeredDraggedTypes.isEmpty,
                          "透明な再生接続用WebViewをドロップの受付候補に残さない")
        }
        let drag = PlayerRoutingDrag(window: window, urls: [url])
        let destination = try fileDragDestination(in: host, at: drag.draggingLocation)
        XCTAssertTrue(destination is PlayerFileDropHostingView, "ガラス背景ではなく実プレイヤーのビューが受け付けること")
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

    @MainActor
    private func verifyLyricDrop(includesAudio: Bool, appleMusicActive: Bool = false,
                                 appleMusicRegistered: Bool = false) async throws {
        _ = NSApplication.shared
        let queue = try? Data(contentsOf: QueuePersistence.file)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("歌詞と読み込む曲.wav")
        let lyrics = directory.appendingPathComponent("歌詞.txt")
        let text = "ドロップした歌詞\n次の行も読み込む"
        try text.write(to: lyrics, atomically: true, encoding: .utf8)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        do {
            let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
            try writer.write(from: buffer)
        }
        let store = PlayerStore(lyricDirectory: directory.appendingPathComponent("Lyrics"),
                                appleMusicAnalysisDirectory: directory.appendingPathComponent("AppleMusic"))
        store.appleMusic.preanalysis.operation = { _ in return .complete }
        if appleMusicActive || appleMusicRegistered {
            let song = AppleMusicSong(id: "123456", title: "配信曲", artist: "", album: "", duration: 180)
            store.tracks = [Track(appleMusicSong: song)]
        }
        let previousAudio = directory.appendingPathComponent("先に選択していた曲.wav")
        if appleMusicActive {
            store.isAppleMusicActive = true
            store.position = 33; store.duration = 180
            store.appleMusic.webViewForDisplay().stopLoading()
            store.appleMusicBrowser.webViewForDisplay().stopLoading()
        } else if appleMusicRegistered {
            try FileManager.default.copyItem(at: audio, to: previousAudio)
            store.tracks.append(Track(url: previousAudio))
            store.select(1, autoplay: false)
        } else if !includesAudio {
            store.tracks = [Track(url: audio)]
            store.select(0, autoplay: false)
        }
        let initialTrackCount = store.tracks.count
        let generation = store.playbackGeneration
        let host = NSHostingView(rootView: PlayerGlassContainer(store: store, appearance: .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; store.shutdown()
            if let queue { try? queue.write(to: QueuePersistence.file) }
            else { try? FileManager.default.removeItem(at: QueuePersistence.file) }
            try? FileManager.default.removeItem(at: directory)
        }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let drag = PlayerRoutingDrag(window: window, urls: includesAudio ? [audio, lyrics] : [lyrics])
        let destination = try fileDragDestination(in: host, at: drag.draggingLocation)
        XCTAssertTrue(destination is PlayerFileDropHostingView)
        XCTAssertEqual(destination.draggingEntered(drag), .copy)
        XCTAssertEqual(destination.draggingUpdated(drag), .copy)
        XCTAssertTrue(destination.prepareForDragOperation(drag))
        XCTAssertTrue(destination.performDragOperation(drag))
        func editor(in view: NSView) -> LyricDropTextView? {
            if let editor = view as? LyricDropTextView { return editor }
            return view.subviews.compactMap(editor).first
        }
        var importedEditor: LyricDropTextView?
        for _ in 0..<150 {
            importedEditor = NSApp.windows.compactMap { $0.contentView }.compactMap(editor)
                .first(where: { $0.string == text })
            if importedEditor != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.tracks.count, initialTrackCount + (includesAudio ? 1 : 0))
        if appleMusicActive || appleMusicRegistered {
            XCTAssertEqual(store.tracks.first?.appleMusicSong?.id, "123456", "登録済みのApple Music曲を残すこと")
        }
        if appleMusicRegistered {
            XCTAssertTrue(store.tracks.contains { $0.url == previousAudio }, "先に選択していたローカル曲も残すこと")
        }
        XCTAssertFalse(store.isAppleMusicActive, "同時にドロップしたローカル曲へ切り替わること")
        XCTAssertEqual(store.currentTrack?.url, audio)
        XCTAssertEqual(importedEditor?.string, text, "受付した歌詞本文が実際の編集欄まで届くこと")
        XCTAssertEqual(store.lyricText, "", "適用ボタンを押すまでは保存済み歌詞へ反映しないこと")
        XCTAssertNil(store.playbackError)
        XCTAssertFalse(store.isPlaying)
        if includesAudio {
            XCTAssertGreaterThan(store.playbackGeneration, generation)
        } else {
            XCTAssertEqual(store.playbackGeneration, generation, "歌詞だけのドロップでは選曲を変えないこと")
        }
    }

    @MainActor
    private func fileDragDestination(in view: NSView, at point: NSPoint) throws -> NSView {
        // Test AppKit's drag-specific hit testing; ordinary hitTest misses WebKit's drag override.
        // This private selector is used only by the test target.
        let selector = NSSelectorFromString("_hitTest:dragTypes:")
        let implementation = try XCTUnwrap(view.method(for: selector))
        typealias DragHitTest = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> Unmanaged<AnyObject>?
        let hitTest = unsafeBitCast(implementation, to: DragHitTest.self)
        var location = point
        let types = NSSet(object: NSPasteboard.PasteboardType.fileURL.rawValue)
        return try XCTUnwrap(hitTest(view, selector, &location, types)?.takeUnretainedValue() as? NSView,
                             "AppKitのドラッグ専用判定でファイルの受付先が見つかること")
    }
}

@MainActor
private final class PlayerRoutingDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingDestinationWindow: NSWindow?
    init(window: NSWindow, urls: [URL]) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
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
