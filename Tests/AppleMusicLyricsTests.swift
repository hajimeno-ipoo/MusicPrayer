import XCTest
@testable import MusicPrayer

final class AppleMusicLyricsTests: XCTestCase {
    func testResponseUsesRealLyricDocumentBeforeCatalogAvailabilityFlag() throws {
        let ttml = "<tt xml:lang=\"ja\"><body><p begin=\"1s\" end=\"4s\">取得した歌詞</p></body></tt>"
        for flag in [NSNull(), NSNumber(value: true), NSNumber(value: false)] as [Any] {
            let result = try XCTUnwrap(AppleMusicLyricsParser.parseResponse(
                ["songID": "123", "ttml": ttml, "hasLyrics": flag], songID: "123"))
            XCTAssertEqual(result.songID, "123")
            XCTAssertEqual(result.text, "取得した歌詞")
            XCTAssertEqual(result.languages, ["ja"])
            XCTAssertEqual(result.lines.map(\.start), [1])
            XCTAssertEqual(result.lines.map(\.end), [4])
        }
    }

    func testResponseReturnsNoLyricsOnlyForConfirmedCatalogAbsence() throws {
        XCTAssertNil(try AppleMusicLyricsParser.parseResponse(
            ["songID": "123", "ttml": NSNull(), "hasLyrics": false], songID: "123"))
        XCTAssertNil(try AppleMusicLyricsParser.parseResponse(
            ["songID": "123", "ttml": "", "hasLyrics": false], songID: "123"))
        for flag in [NSNull(), NSNumber(value: true), "false"] as [Any] {
            XCTAssertThrowsError(try AppleMusicLyricsParser.parseResponse(
                ["songID": "123", "ttml": NSNull(), "hasLyrics": flag], songID: "123")) {
                XCTAssertEqual($0 as? AppleMusicLyricsParser.FetchError, .missingData)
            }
        }
        XCTAssertThrowsError(try AppleMusicLyricsParser.parseResponse(
            ["songID": "123"], songID: "123")) {
            XCTAssertEqual($0 as? AppleMusicLyricsParser.FetchError, .missingData)
        }
    }

    func testResponseRejectsMalformedOrEmptyDocumentsInsteadOfTreatingThemAsUnavailable() {
        for (ttml, error) in [
            ("<tt><body><p>途中", AppleMusicLyricsParser.FetchError.invalidDocument),
            ("<tt><body><p>   </p></body></tt>", .emptyDocument)
        ] {
            XCTAssertThrowsError(try AppleMusicLyricsParser.parseResponse(
                ["songID": "123", "ttml": ttml, "hasLyrics": false], songID: "123")) {
                XCTAssertEqual($0 as? AppleMusicLyricsParser.FetchError, error)
            }
        }
    }

    func testResponseRejectsAnotherSongAndInvalidDocumentType() {
        for response in [
            ["songID": "456", "ttml": "<tt><body><p>別の曲</p></body></tt>"],
            ["ttml": NSNull(), "hasLyrics": false],
            ["songID": "123", "ttml": 12, "hasLyrics": false]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try AppleMusicLyricsParser.parseResponse(response, songID: "123")) {
                XCTAssertEqual($0 as? AppleMusicLyricsParser.FetchError, .invalidResponse)
            }
        }
    }

    func testSungLanguagesKeepRootAndBodyOrderWithoutHeadTranslationsOrDuplicates() throws {
        let result = try AppleMusicLyricsParser.parse(ttml: """
        <tt xml:lang="en">
          <head><metadata xml:lang="fr"><translation xml:lang="es">Traduction</translation></metadata></head>
          <body xml:lang="ja"><div xml:lang="ja">
            <p begin="1s" end="4s" xml:lang="ko"><span begin="1s" end="2s" xml:lang="en">愛</span><span begin="3s" end="4s" xml:lang="de">Love</span></p>
          </div></body>
        </tt>
        """, songID: "123")
        XCTAssertEqual(result.languages, ["en", "ja", "ko", "de"])
        XCTAssertEqual(result.text, "愛Love")
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.text, "愛Love")
        XCTAssertEqual(line.start, 1)
        XCTAssertEqual(line.end, 4)
        XCTAssertEqual(line.characterTimings, [LyricCharacterTiming(start: 1, end: 2)]
            + Array(repeating: LyricCharacterTiming(start: 3, end: 4), count: 4))
    }

    func testMissingOrEmptyLanguageDoesNotAddAnInferredCandidate() throws {
        for attribute in ["", " xml:lang=\"\"", " xml:lang=\"   \""] {
            let result = try AppleMusicLyricsParser.parse(ttml: """
            <tt\(attribute)><body\(attribute)><p begin="1s" end="4s"\(attribute)>愛とLove</p></body></tt>
            """, songID: "123")
            XCTAssertTrue(result.languages.isEmpty)
            XCTAssertEqual(result.text, "愛とLove")
            XCTAssertEqual(result.lines.map(\.start), [1])
            XCTAssertEqual(result.lines.map(\.end), [4])
            XCTAssertTrue(result.lines[0].characterTimings.isEmpty)
        }
    }

    func testRootLanguageRemainsAvailableForMixedTextWithoutRowLanguageAttributes() throws {
        let result = try AppleMusicLyricsParser.parse(ttml: """
        <tt xml:lang="en"><body><div><p begin="1s" end="4s">愛とLove</p></div></body></tt>
        """, songID: "123")
        XCTAssertEqual(result.languages, ["en"])
        XCTAssertEqual(result.text, "愛とLove")
        XCTAssertEqual(result.lines.map(\.text), ["愛とLove"])
    }

    func testParagraphTimesDoNotInventCharacterTimes() throws {
        let result = try parse("""
        <p begin="00:01:02.250" end="01:04.500">愛が止まらない</p>
        <p begin="64500ms" end="66s">Turn it into love</p>
        """)
        XCTAssertEqual(result.songID, "123")
        XCTAssertEqual(result.text, "愛が止まらない\nTurn it into love")
        XCTAssertEqual(result.lines.map(\.start), [62.25, 64.5])
        XCTAssertEqual(result.lines.map(\.end), [64.5, 66])
        XCTAssertTrue(result.lines.allSatisfy { $0.characterTimings.isEmpty })
    }

    func testSpanIntervalsApplyToWholeCharactersWithoutSplittingEmojiOrCombiningMarks() throws {
        let result = try parse("""
        <p begin="1s" end="4s"><span begin="1s" end="2s">愛👨‍👩‍👧‍👦</span><span begin="2s" end="4s">éが</span></p>
        """)
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.text, "愛👨‍👩‍👧‍👦éが")
        XCTAssertEqual(line.text.count, 4)
        XCTAssertEqual(line.characterTimings, [
            LyricCharacterTiming(start: 1, end: 2), LyricCharacterTiming(start: 1, end: 2),
            LyricCharacterTiming(start: 2, end: 4), LyricCharacterTiming(start: 2, end: 4)
        ])
        XCTAssertTrue(line.hasValidCharacterTimings)
    }

    func testUntimedSpacesBetweenTimedWordsKeepTheirRealIntervals() throws {
        let result = try parse("""
        <p begin="1s" end="4s"><span begin="1s" end="2s">Turn</span> <span begin="3s" end="4s">it</span></p>
        """)
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.text, "Turn it")
        XCTAssertEqual(line.characterTimings, Array(repeating: LyricCharacterTiming(start: 1, end: 2), count: 4)
            + [LyricCharacterTiming(start: 2, end: 2)]
            + Array(repeating: LyricCharacterTiming(start: 3, end: 4), count: 2))
        XCTAssertTrue(line.hasValidCharacterTimings)
    }

    func testUntimedPreservedWhitespaceAndBreaksUseAdjacentRealBoundaries() throws {
        let result = try parse("""
        <p begin="1s" end="4s" xml:space="preserve"> <span begin="1s" end="2s">A</span><br/><span begin="3s" end="4s">B</span> </p>
        """)
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.text, " A\nB ")
        XCTAssertEqual(line.characterTimings, [
            LyricCharacterTiming(start: 1, end: 1), LyricCharacterTiming(start: 1, end: 2),
            LyricCharacterTiming(start: 2, end: 2), LyricCharacterTiming(start: 3, end: 4),
            LyricCharacterTiming(start: 4, end: 4)
        ])
        XCTAssertTrue(line.hasValidCharacterTimings)
    }

    func testWhitespaceRepairDoesNotInventMissingWordTimes() throws {
        let result = try parse("""
        <p begin="1s" end="4s"><span begin="1s" end="2s">A</span> B <span begin="3s" end="4s">C</span></p>
        """)
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.text, "A B C")
        XCTAssertTrue(line.characterTimings.isEmpty)
    }

    func testBreakWhitespaceEntitiesAndBackgroundVocalsRemainInText() throws {
        let result = try parse("""
        <p begin="0s" end="8s">
          Turn <span>it</span>  into<br/>love &amp; 愛<span ttm:role="x-bg"> (oh)</span>
        </p>
        <p>次の行</p>
        """)
        XCTAssertEqual(result.text, "Turn it into\nlove & 愛 (oh)\n次の行")
        XCTAssertEqual(result.lines.first?.text, "Turn it into\nlove & 愛 (oh)")
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].characterTimings.isEmpty)
    }

    func testUntimedLyricsRemainAvailableAsPlainText() throws {
        let result = try parse("""
        <p>時刻のない歌詞</p><p><![CDATA[<そのまま>]]></p><p>   </p>
        """)
        XCTAssertEqual(result.text, "時刻のない歌詞\n<そのまま>")
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testInvalidLineTimesKeepTextWithoutFabricatedSynchronization() throws {
        let result = try parse("""
        <p begin="bad" end="2s">不正</p>
        <p begin="3s" end="2s">逆順</p>
        <p begin="-1s" end="2s">負</p>
        <p begin="NaNs" end="2s">非数</p>
        <p begin="00:61:00" end="4000s">範囲外</p>
        <p begin="2s">終了なし</p>
        <p begin="2s" end="3s">有効</p>
        """)
        XCTAssertEqual(result.text, "不正\n逆順\n負\n非数\n範囲外\n終了なし\n有効")
        XCTAssertEqual(result.lines.map(\.text), ["有効"])
        XCTAssertEqual(result.lines.first?.ordinal, 6)
    }

    func testMissingOrOutOfBoundsSpanTimeDoesNotGetEstimated() throws {
        for content in [
            "<span begin=\"1s\" end=\"2s\">愛</span>が",
            "<span begin=\"1s\" end=\"2s\">愛</span><span begin=\"2s\">が</span>",
            "<span begin=\"0s\" end=\"2s\">愛が</span>",
            "<span begin=\"1s\" end=\"5s\">愛が</span>"
        ] {
            let result = try parse("<p begin=\"1s\" end=\"4s\">\(content)</p>")
            XCTAssertEqual(result.lines.first?.text, "愛が")
            XCTAssertTrue(try XCTUnwrap(result.lines.first).characterTimings.isEmpty)
        }
    }

    func testNestedSpanKeepsExplicitParentIntervalAndPreservedSpaces() throws {
        let result = try parse("""
        <p begin="1s" end="3s" xml:space="preserve"><span begin="1s" end="3s"> A<span>B</span> </span></p>
        """)
        let line = try XCTUnwrap(result.lines.first)
        XCTAssertEqual(line.text, " AB ")
        XCTAssertEqual(line.characterTimings.count, 4)
        XCTAssertTrue(line.characterTimings.allSatisfy { $0.start == 1 && $0.end == 3 })
    }

    func testMalformedXMLThrowsInsteadOfReturningPartialLyrics() {
        XCTAssertThrowsError(try parse("<p begin=\"1s\" end=\"2s\">途中</p><p>壊れた"))
    }

    private func parse(_ body: String) throws -> AppleMusicLyrics {
        try AppleMusicLyricsParser.parse(ttml: "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\"><body><div>\(body)</div></body></tt>", songID: "123")
    }
}
