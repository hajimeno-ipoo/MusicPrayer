import AppKit
import XCTest
@testable import MusicPrayer

final class PlayerFileDropTests: XCTestCase {
    func testTextAndAudioHaveDifferentDestinations() throws {
        try withFiles { root in
            let text = try file(root, "lyrics.txt", Data("歌詞\n二行目".utf8))
            let audio = try file(root, "song.mp3", Data())
            XCTAssertEqual(try PlayerFileDrop.destination(for: [text]), .lyrics(text))
            XCTAssertEqual(try PlayerFileDrop.destination(for: [audio]), .audio([audio]))
            XCTAssertEqual(try PlayerFileDrop.destination(for: [audio, text]), .songAndLyrics(audio: audio, lyrics: text))
            XCTAssertEqual(try PlayerFileDrop.destination(for: [text, audio]), .songAndLyrics(audio: audio, lyrics: text))
            let image = try file(root, "image.png", Data())
            XCTAssertThrowsError(try PlayerFileDrop.destination(for: [image]))
            XCTAssertThrowsError(try PlayerFileDrop.destination(for: [root]))
        }
    }

    func testAmbiguousGroupsAndUnsupportedFilesAreRejectedBeforeImporting() throws {
        try withFiles { root in
            let first = try file(root, "first.mp3", Data())
            let second = try file(root, "second.wav", Data())
            let text = try file(root, "lyrics.txt", Data("[Verse]\n歌詞".utf8))
            let otherText = try file(root, "other.txt", Data("別の歌詞".utf8))
            let image = try file(root, "image.png", Data())
            XCTAssertEqual(try PlayerFileDrop.destination(for: [first, second]), .audio([first, second]))
            XCTAssertThrowsError(try PlayerFileDrop.destination(for: [first, second, text]))
            XCTAssertThrowsError(try PlayerFileDrop.destination(for: [first, text, otherText]))
            XCTAssertThrowsError(try PlayerFileDrop.destination(for: [first, text, image]))
            XCTAssertThrowsError(try PlayerFileDrop.destination(for: []))
        }
    }

    @MainActor
    func testNativeFileDropReadsBodyInsteadOfInsertingPath() throws {
        _ = NSApplication.shared
        try withFiles { root in
            let text = "日本語の歌詞\n\n  二行目🌸\n"
            let url = try file(root, "lyrics.txt", Data(text.utf8))
            let drag = LyricTestDrag(urls: [url])
            drag.draggingPasteboard.setString(url.path, forType: .string)
            let editor = LyricDropTextView()
            editor.string = "以前の本文"
            editor.onFileDrop = { urls in
                do { editor.string = try LyricTextFile.read(urls) }
                catch { XCTFail(error.localizedDescription) }
            }
            XCTAssertEqual(editor.draggingEntered(drag), .copy)
            XCTAssertTrue(editor.prepareForDragOperation(drag))
            XCTAssertTrue(editor.performDragOperation(drag))
            XCTAssertEqual(editor.string, text)
        }
    }

    @MainActor
    func testNativeRejectedFilesAreConsumedWithoutPathInsertion() throws {
        _ = NSApplication.shared
        try withFiles { root in
            let first = try file(root, "first.txt", Data("一行目".utf8))
            let second = try file(root, "second.txt", Data("二行目".utf8))
            let rich = try file(root, "lyrics.rtf", Data("{\\rtf1 text}".utf8))
            for urls in [[first, second], [rich]] {
                let editor = LyricDropTextView()
                editor.string = "入力中の本文"
                var receivedError = false
                editor.onFileDrop = { incoming in
                    do { editor.string = try LyricTextFile.read(incoming) }
                    catch { receivedError = true }
                }
                let drag = LyricTestDrag(urls: urls)
                XCTAssertTrue(editor.performDragOperation(drag))
                XCTAssertTrue(receivedError)
                XCTAssertEqual(editor.string, "入力中の本文")
            }
        }
    }

    @MainActor
    func testDisabledNativeEditorDoesNotImport() {
        _ = NSApplication.shared
        let editor = LyricDropTextView()
        editor.isEditable = false
        var imported = false
        editor.onFileDrop = { _ in imported = true }
        let drag = LyricTestDrag(urls: [URL(fileURLWithPath: "/tmp/lyrics.txt")])
        XCTAssertEqual(editor.draggingEntered(drag), [])
        XCTAssertFalse(editor.prepareForDragOperation(drag))
        XCTAssertFalse(editor.performDragOperation(drag))
        XCTAssertFalse(imported)
    }

    private func withFiles(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerFileDropTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func file(_ root: URL, _ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

@MainActor
private final class LyricTestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    init(urls: [URL]) {
        super.init()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
    }
    deinit { draggingPasteboard.releaseGlobally() }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
