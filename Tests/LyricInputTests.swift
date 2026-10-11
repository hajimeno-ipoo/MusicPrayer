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

    func testNestedMetadataAndTrailingArrayCommasDoNotBecomeLyricLines() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "[melody progress]" + newline
                + "[[G#4,4], [B4,8], [D5,8], [G#4,4]], " + newline
                + "  [[A4,4], [C#5,8]],\t" + newline
                + "[[E4,4], [G#4,8], [B4,8], [A4,4]]" + newline + newline
                + "🌸朝[[softly], [repeat]]の光, [tag]" + newline
            XCTAssertEqual(LyricInput.clean(source), newline + "🌸朝の光, " + newline)
        }
        XCTAssertEqual(LyricInput.clean("歌[[G4,4], [C5,8]], 続き"), "歌, 続き")
        XCTAssertEqual(LyricInput.clean("[Verse],\n歌"), ",\n歌")
    }

    func testUnclosedAndMultilineOuterBracketsDoNotLoseNestedContents() {
        for newline in ["\n", "\r\n", "\r", "\u{2028}"] {
            let source = "[outer [inner]" + newline + "|C|G|" + newline + "(Am)歌詞]"
            XCTAssertEqual(LyricInput.clean(source), source)
        }
        let source = "[outer [inner]\n|C|G|\n(Am)歌詞"
        XCTAssertEqual(LyricInput.clean(source), source)
    }

    func testSymbolOnlyArrayLinesLoseTheirTrailingCommaButTagAndLyricPunctuationRemain() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "[Verse]," + newline + "[Chorus]。" + newline
                + "[, , , ]," + newline + "  [ ,　, ], \t" + newline + "[]," + newline + newline
                + "🌸歌[, , ], 続き" + newline
            XCTAssertEqual(LyricInput.clean(source), "," + newline + "。" + newline + newline
                           + "🌸歌, 続き" + newline)
        }
        let source = "[, , , ],\r\n🌸歌"
        let result = LyricInput.clean(source, selection: NSRange(location: source.utf16.count, length: 0))
        XCTAssertEqual(result.text, "🌸歌")
        XCTAssertEqual(result.selection, NSRange(location: 3, length: 0))
    }

    func testBarDelimitedChordOnlyLinesAreRemovedAndOrdinaryLyricsRemain() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "[Code progress]" + newline
                + "|G#m7b5|A|Bm F#m|E7|C#m|E Amaj7|" + newline + newline
                + " A" + newline + "C" + newline + "A C" + newline
                + "歌|コードではない" + newline + "A | love" + newline + "|||" + newline
                + "　｜Ｃ＃ｍ７｜Ｆ♯７｜　" + newline + "A|C"
            XCTAssertEqual(LyricInput.clean(source), newline + " A" + newline + "C" + newline
                           + "A C" + newline + "歌|コードではない" + newline
                           + "A | love" + newline + "|||" + newline)
        }
    }

    func testBarChordLinesInsideOrdinaryMultilineAndUnclosedParenthesesArePreserved() {
        for (opening, closing) in [("(", ")"), ("（", "）")] {
            let ordinary = opening + "君の |C|G| 声" + closing
            XCTAssertEqual(LyricInput.clean(ordinary), ordinary)
            for newline in ["\n", "\r\n", "\r"] {
                let multiline = opening + "歌詞" + newline + "|C|G|" + newline + "続き" + closing
                XCTAssertEqual(LyricInput.clean(multiline), multiline)
                let bounded = "|Am|F|" + newline + multiline + newline + "|C|G|" + newline + "🌸歌"
                XCTAssertEqual(LyricInput.clean(bounded), multiline + newline + "🌸歌")
                let unclosed = opening + "歌詞" + newline + "|C|G|" + newline + "続き"
                XCTAssertEqual(LyricInput.clean(unclosed), unclosed)
                let nested = opening + "歌詞" + newline + opening + "声" + closing + newline
                    + "|C|G|" + newline + "続き" + closing
                XCTAssertEqual(LyricInput.clean(nested), nested)
                let tagged = "[Verse " + opening + "soft]" + newline + "|C|G|" + newline + "🌸歌"
                let cleaned = LyricInput.clean(tagged)
                XCTAssertEqual(cleaned, "🌸歌")
                XCTAssertEqual(LyricInput.clean(cleaned), cleaned)
            }
        }
    }

    func testSelectionTracksNestedMetadataAndBarChordLinesInUTF16() {
        let source = "[outer [(Am)]]\r\n|C|Am|\r\n🌸朝[[G4,4], [C5,8]],日"
        let result = LyricInput.clean(source, selection: NSRange(location: source.utf16.count, length: 0))
        XCTAssertEqual(result.text, "🌸朝,日")
        XCTAssertEqual(result.selection, NSRange(location: 5, length: 0))
        let inline = "🌸朝[[G4,4], [C5,8]]日"
        let selection = LyricInput.clean(inline, selection: NSRange(location: 4, length: inline.utf16.count - 4))
        XCTAssertEqual(selection.text, "🌸朝日")
        XCTAssertEqual(selection.selection, NSRange(location: 3, length: 1))
        XCTAssertEqual(LyricInput.clean(result.text), result.text)
    }

    func testParenthesizedChordsAreRemovedWithoutChangingLyricsOrSpacing() {
        let source = "(G#m7b5) 흔들리는 불빛이 (A)  \n画面の(Bm)君を（F#m）探す\n(E7)影(C#m)の中(E Amaj7)\n君の（声）(I love you)🌸"
        XCTAssertEqual(LyricInput.clean(source),
                       " 흔들리는 불빛이   \n画面の君を探す\n影の中\n君の（声）(I love you)🌸")
    }

    func testCommonChordNotationAndProgressionSeparators() {
        let chords = ["A", "C", "G#m7b5", "E Amaj7", "C/G", "Bbmaj7", "F♯m7", "B♭7",
                      "Dm7 G7 Cmaj7", "C→Am→F→G", "C | Am | F | G", "Am-F-G", "C, G7",
                      "Cadd9", "Dsus4", "G7sus4", "Fdim7", "Eaug", "CΔ7", "C7b9#11"]
        for chord in chords {
            XCTAssertEqual(LyricInput.clean("前(\(chord))後"), "前後", chord)
            XCTAssertEqual(LyricInput.clean("前（\(chord)）後"), "前後", chord)
        }
        XCTAssertEqual(LyricInput.clean("🌸（Ｃ＃ｍ７　Ｆ♯７）歌"), "🌸歌")
    }

    func testOrdinaryMixedNestedAndIncompleteParenthesesArePreserved() {
        let source = "（君の声）(oh) (I love you) (Dream) (Am I alone) (CとG) (C lyrics)\n"
            + "(君(C)の声) （君（Am）の声） (C） （D) (H7) ()\n"
            + "(Am\nG)\n(C"
        XCTAssertEqual(LyricInput.clean(source), source)
    }

    func testChordCleanupKeepsLineEndingsAndExistingBlankLines() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "[Verse](Am)" + newline + "  (C G)  " + newline + newline
                + "歌（声）(F#m)" + newline
            XCTAssertEqual(LyricInput.clean(source), newline + "    " + newline + newline
                           + "歌（声）" + newline)
        }
    }

    func testSelectionTracksOverlappingChordAndMetadataRangesInUTF16() {
        let source = "[repeat (Am)]\n🌸(C)朝（Dm G7）日"
        let result = LyricInput.clean(source, selection: NSRange(location: source.utf16.count, length: 0))
        XCTAssertEqual(result.text, "🌸朝日")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
        let selection = LyricInput.clean("🌸(C)朝（君）", selection: NSRange(location: 3, length: 3))
        XCTAssertEqual(selection.text, "🌸朝（君）")
        XCTAssertEqual(selection.selection, NSRange(location: 2, length: 1))
        XCTAssertEqual(LyricInput.clean(result.text), result.text)
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
        editor.insertText("[Verse]\n(Am)朝の（光）\n\n[Chorus]\nありがとう🌸（C G）", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "朝の（光）\n\nありがとう🌸")
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
        editor.setMarkedText("[Verse](Am)朝", selectedRange: NSRange(location: 12, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "[Verse](Am)朝")
        XCTAssertEqual(draft, editor.string)
        editor.unmarkText()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(editor.string, "朝")
        XCTAssertEqual(draft, "朝")
    }
}
