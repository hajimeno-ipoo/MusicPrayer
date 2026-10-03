import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class LyricInputTests: XCTestCase {
    func testSectionTagLinesAreRemovedWithoutAddingBlankLines() {
        let source = "[Verse]\n朝の光\n\n  [Chorus] [Repeat] \nありがとう\n[Outro]"
        XCTAssertEqual(LyricInput.clean(source), "朝の光\n\nありがとう\n")
    }

    func testInlineTagsLeaveLyricsAndSpacesIntact() {
        XCTAssertEqual(LyricInput.clean("  朝[softly]の光  \n[ar:作者]感謝[Chorus]🌸"),
                       "  朝の光  \n感謝🌸")
        XCTAssertEqual(LyricInput.clean("[Verse]\n[Chorus]\n"), "")
    }

    func testExistingLineEndingsAndEmptyLinesArePreserved() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "[Verse]" + newline + "一行目" + newline + newline
                + "[Bridge]" + newline + "二行目" + newline
            XCTAssertEqual(LyricInput.clean(source), "一行目" + newline + newline + "二行目" + newline)
        }
        let source = "  光 e\u{301}🌸 \r\n\r\n歌詞\n"
        XCTAssertEqual(Array(LyricInput.clean(source).utf8), Array(source.utf8))
    }

    func testUnclosedAndMultilineBracketsKeepTheirContents() {
        let source = "[Verse\n歌詞]\n閉じていない[タグ\n歌詞本文"
        XCTAssertEqual(LyricInput.clean(source), source)
    }

    func testSelectionTracksRemovedTagsInUTF16() {
        let source = "[Verse]\n🌸朝[soft]日"
        let result = LyricInput.clean(source, selection: NSRange(location: source.utf16.count, length: 0))
        XCTAssertEqual(result.text, "🌸朝日")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))

        let selection = LyricInput.clean("朝[tag]日", selection: NSRange(location: 2, length: 5))
        XCTAssertEqual(selection.text, "朝日")
        XCTAssertEqual(selection.selection, NSRange(location: 1, length: 1))
    }

    @MainActor
    func testNativeTextInputUpdatesTheDraftWithoutTags() {
        _ = NSApplication.shared
        var draft = ""
        let view = LyricTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                   isEditable: true, onFileDrop: { _ in }, onFileTargetChanged: { _ in })
        let coordinator = view.makeCoordinator()
        let editor = LyricDropTextView()
        editor.isRichText = false
        editor.delegate = coordinator
        editor.insertText("[Verse]\n朝の光\n\n[Chorus]\nありがとう🌸", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "朝の光\n\nありがとう🌸")
        XCTAssertEqual(draft, editor.string)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: editor.string.utf16.count, length: 0))
    }

    @MainActor
    func testMarkedTextIsKeptUntilJapaneseInputIsCommitted() {
        _ = NSApplication.shared
        var draft = ""
        let view = LyricTextEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                   isEditable: true, onFileDrop: { _ in }, onFileTargetChanged: { _ in })
        let coordinator = view.makeCoordinator()
        let editor = LyricDropTextView()
        editor.setMarkedText("[Verse]朝", selectedRange: NSRange(location: 8, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "[Verse]朝")
        XCTAssertEqual(draft, editor.string)
        editor.unmarkText()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(editor.string, "朝")
        XCTAssertEqual(draft, "朝")
    }
}
