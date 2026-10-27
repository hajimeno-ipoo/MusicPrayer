import AppKit
import AVFoundation
import Combine
import CoreText
import SwiftUI
import XCTest
@testable import MusicPrayer

final class LyricMotionTests: XCTestCase {
    func testBundledFurifontUsesMediumFaceAtRequestedSizes() {
        for size: CGFloat in [14, 24, 32] {
            let font = LyricFont.furifont.nativeFont(size: size)
            XCTAssertEqual(font.fontName, "FurifontSansVF-Medium")
            XCTAssertEqual(font.pointSize, size)
            let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
            XCTAssertEqual(variation?[NSNumber(value: 2003265652)]?.doubleValue, 500)
        }
    }

    func testBundledRubifontUsesMediumFaceAtRequestedSizes() {
        for size: CGFloat in [14, 24, 32] {
            let font = LyricFont.rubifont.nativeFont(size: size)
            XCTAssertEqual(font.fontName, "RubifontSansVF-Medium")
            XCTAssertEqual(font.pointSize, size)
            let variation = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]
            XCTAssertEqual(variation?[NSNumber(value: 2003265652)]?.doubleValue, 500)
        }
    }

    @MainActor
    func testSavedRubifontReadingsKeepColourProgressAndSeekWithoutChangingTimings() throws {
        let source = "😀来ない 一回り"
        let store = offscreenStore(source: source)
        defer { store.engine.stop() }
        let timings = store.lyricTimeline?.lines.first?.characterTimings
        let plan = LyricReadings(sourceTextHash: LyricHash.text(source), lines: [source: [
            LyricReading(start: 1, count: 1, salt: 5),
            LyricReading(start: 5, count: 2, salt: 2)
        ]])
        func render(_ font: LyricFont) throws -> RenderedPixels {
            try pixels(ImageRenderer(content: LyricMotionView(store: store, font: font)
                .frame(width: 600, height: 240).background(.black)))
        }
        let original = try render(.rubifont)
        let system = try render(.system)
        let furifont = try render(.furifont)
        store.lyricReadings = nil
        XCTAssertEqual(try render(.rubifont).litPixels, 0, "読みの準備前にRubifontの既定読みを先行表示しないこと")
        // This value represents a restored JSON result; no resolver is called by the view.
        store.lyricReadings = try JSONDecoder().decode(LyricReadings.self, from: JSONEncoder().encode(plan))
        let selected = try render(.rubifont)
        XCTAssertGreaterThan(selected.litPixels, 30)
        XCTAssertNotEqual(original.bytes, selected.bytes, "保存したsalt指定で実際の読み字形が変わること")
        // Rebuilding Text can change an 8-bit antialiasing sample by one step.
        let systemAfter = try render(.system)
        let systemDifference = zip(system.bytes, systemAfter.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(systemDifference, 1)
        XCTAssertEqual(furifont.bytes, try render(.furifont).bytes)
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        frame.time = 2.5
        publish(frame, to: store)
        let progressed = try render(.rubifont)
        XCTAssertNotEqual(selected.bytes, progressed.bytes, "読み指定と文字色の進行が両立すること")
        frame.time = 1
        publish(frame, to: store)
        XCTAssertEqual(selected.bytes, try render(.rubifont).bytes, "シークで同じ読みと色へ戻ること")
        XCTAssertEqual(store.lyricTimeline?.lines.first?.characterTimings, timings)
        XCTAssertEqual(store.lyricTimeline?.sourceText, source)
    }

    @MainActor
    func testPreparedReportedReadingsRenderWithBundledFontAndKeepOriginalText() async throws {
        _ = NSApplication.shared
        let sources = ["暗闇走り抜ける", "1つの街と人が", "2人でいても離れていても", "車道で踊るあの娘", "想い出を", "１つの街と人が", "２人でいても離れていても",
                       "2つの国と", "あの時感じた", "不満の声", "あなたの声聞きたくて", "金のハンドルで街を飛びまわれ", "胸の鼓動焼きつけろ", "AH AHいくつかの場面", "２つの国と",
                       "そんな1日でもいいでしょう", "そんな１日でもいいでしょう", "Oh 人生楽ありゃ苦あり", "大きな声で 自由に歌っているの",
                       "もっと楽に生きていきたい", "今朝もミニのスカートで 人ゴミの中走ってく", "ゴミの中走っていく", "走っていく", "candy pretty doll",
                       "あぁ、愛で全部抱きしめて愛して", "受け入れて", "終わんないで 見続けてる 逃さないで"]
        let plan = try await LyricReadingResolver().prepare(sourceText: sources.joined(separator: "\n"), lines: sources)
        let viewport = CGSize(width: 800, height: 160)
        for (index, source) in sources.enumerated() {
            let timings = source.map { _ in LyricCharacterTiming(start: 1, end: 3) }
            let line = TimedLyricLine(id: "reported-\(index)", ordinal: index, text: source, start: 1, end: 3,
                                      textWeight: Double(source.count), confidence: 1, characterTimings: timings)
            let motion = try XCTUnwrap(LyricMotion.parameters(for: line, time: 1, vocal: nil,
                                                             beat: 0, beatPhase: 0, barPhase: 0))
            let readings = try XCTUnwrap(plan.readings(for: source))
            let original = ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: timings,
                motion: motion, time: 1, viewport: viewport, font: .rubifont).background(.black))
            let selected = ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: timings,
                motion: motion, time: 1, viewport: viewport, font: .rubifont, readings: readings).background(.black))
            let before = try pixels(original)
            let after = try pixels(selected)
            XCTAssertGreaterThan(after.litPixels, 100, source)
            if !readings.isEmpty {
                XCTAssertNotEqual(before.bytes, after.bytes, "準備した読み指定が実際の描画へ反映されること: \(source)")
            }
            XCTAssertEqual(line.text, source)
            XCTAssertEqual(line.characterTimings, timings)
            try saveWrappingEvidence(original, name: "reported-\(index + 1)-default.png")
            try saveWrappingEvidence(selected, name: "reported-\(index + 1)-prepared.png")
        }
    }

    @MainActor
    func testShomonWordDefaultAndExplicitAlternateRenderDifferentReadings() throws {
        _ = NSApplication.shared
        let source = "声聞"
        let timings = source.map { _ in LyricCharacterTiming(start: 1, end: 3) }
        let line = TimedLyricLine(id: "shomon-alternate", ordinal: 0, text: source, start: 1, end: 3,
                                  textWeight: Double(source.count), confidence: 1, characterTimings: timings)
        let motion = try XCTUnwrap(LyricMotion.parameters(for: line, time: 1, vocal: nil,
                                                         beat: 0, beatPhase: 0, barPhase: 0))
        let viewport = CGSize(width: 400, height: 160)
        let original = ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: timings,
            motion: motion, time: 1, viewport: viewport, font: .rubifont).background(.black))
        let alternate = ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: timings,
            motion: motion, time: 1, viewport: viewport, font: .rubifont,
            readings: [LyricReading(start: 0, count: 2, salt: 2)]).background(.black))
        let before = try pixels(original)
        let after = try pixels(alternate)
        XCTAssertGreaterThan(before.litPixels, 30)
        XCTAssertGreaterThan(after.litPixels, 30)
        XCTAssertNotEqual(before.bytes, after.bytes, "声聞の通常読みと明示した別読みが描き分けられること")
        XCTAssertEqual(line.text, source)
        XCTAssertEqual(line.characterTimings, timings)
        try saveWrappingEvidence(original, name: "shomon-default-koeki.png")
        try saveWrappingEvidence(alternate, name: "shomon-alternate-shomon.png")
    }

    @MainActor
    func testSavedMultiKanjiReadingsFitWrappingAndRemainOnOneRow() throws {
        let source = "夜が明けてから一回りして、来ない人を待ちながら街を一回り歩いて帰ります。"
        let readings = [LyricReading(start: 7, count: 2, salt: 2),
                        LyricReading(start: 13, count: 1, salt: 5),
                        LyricReading(start: 25, count: 2, salt: 2)]
        let store = offscreenStore(source: source)
        defer { store.engine.stop() }
        store.lyricReadings = LyricReadings(sourceTextHash: LyricHash.text(source), lines: [source: readings])
        for width in [600, 1000] {
            let viewport = CGSize(width: width - 48, height: 208)
            let initial = LyricLineWrapping.presentation(text: source, viewport: viewport, font: .rubifont)
            let selected = try XCTUnwrap(LyricLineWrapping.presentation(text: source, viewport: viewport,
                                                                       font: .rubifont, readings: readings))
            let split = try XCTUnwrap(selected.breakOffset)
            XCTAssertFalse(readings.contains { $0.start < split && split < $0.start + $0.count })
            XCTAssertEqual(initial, LyricLineWrapping.presentation(text: source, viewport: viewport, font: .rubifont),
                           "読み指定ありの計測を既定表示のキャッシュへ混ぜないこと")
            let image = try pixels(ImageRenderer(content: LyricMotionView(store: store, font: .rubifont)
                .frame(width: CGFloat(width), height: 240).background(.black)))
            let bounds = try XCTUnwrap(image.litBounds)
            XCTAssertGreaterThan(bounds.minX, 24)
            XCTAssertLessThan(bounds.maxX, CGFloat(width - 24))
            XCTAssertGreaterThan(bounds.minY, 16)
            XCTAssertLessThan(bounds.maxY, 224)
        }
    }

    @MainActor
    func testFontSwitchChangesPausedLyricsAndRestoresSystemRendering() async throws {
        let source = "日本語の歌詞と Hello Settings Save"
        let audio = try silentAudioFixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let store = offscreenStore(source: source)
        try store.engine.load(url: audio)
        defer { store.engine.unload() }
        store.duration = store.engine.duration
        store.previewTime = 1
        let timings = store.lyricTimeline?.lines[0].characterTimings
        let size = CGSize(width: 600, height: 240)
        let renderer = ImageRenderer(content: LyricMotionView(store: store)
            .frame(width: size.width, height: size.height).background(.black))
        let system = try pixels(renderer)
        try saveWrappingEvidence(renderer, name: "font-system-initial.png")
        for font in [LyricFont.furifont, .rubifont] {
            try await expectRendererUpdate(renderer) {
                renderer.content = LyricMotionView(store: store, font: font)
                    .frame(width: size.width, height: size.height).background(.black)
            }
            let rendered = try pixels(renderer)
            XCTAssertGreaterThan(rendered.litPixels, 100)
            XCTAssertFalse(system.bytes == rendered.bytes)
            try saveWrappingEvidence(renderer, name: "font-\(font.rawValue).png")
        }
        try await expectRendererUpdate(renderer) {
            renderer.content = LyricMotionView(store: store, font: .system)
                .frame(width: size.width, height: size.height).background(.black)
        }
        let returned = try pixels(renderer)
        XCTAssertEqual(system.litBounds, returned.litBounds)
        // Rebuilding text can change an 8-bit antialiasing sample by one step.
        let maximumDifference = zip(system.bytes, returned.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, 1)
        try saveWrappingEvidence(renderer, name: "font-system.png")
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(store.lyricTimeline?.sourceText, source)
        XCTAssertEqual(store.lyricTimeline?.lines[0].characterTimings, timings)
    }

    @MainActor
    func testFontSwitchRemeasuresScrollingLyricsAtSameViewport() throws {
        let source = String(repeating: "遠い夜の向こうから歌声が聞こえる ", count: 35)
        let store = offscreenStore(source: source)
        defer { store.engine.stop() }
        let viewport = CGSize(width: 252, height: 88)
        for font in LyricFont.allCases {
            XCTAssertNil(LyricLineWrapping.presentation(text: source, viewport: viewport, font: font))
        }
        func content(_ font: LyricFont) -> some View {
            LyricMotionView(store: store, font: font).frame(width: 300, height: 120).background(.black)
        }
        let renderer = ImageRenderer(content: content(.system))
        _ = try pixels(renderer)
        for font in [LyricFont.furifont, .rubifont, .system] {
            renderer.content = content(font)
            let switched = try pixels(renderer)
            let fresh = try pixels(ImageRenderer(content: content(font)))
            XCTAssertGreaterThan(switched.litPixels, 100)
            let maximumDifference = zip(switched.bytes, fresh.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(maximumDifference, 1)
        }
        XCTAssertEqual(store.lyricTimeline?.sourceText, source)
    }

    @MainActor
    func testBundledFontsLongLyricsFitAndKeepSeparateLayoutCache() throws {
        for font in [LyricFont.furifont, .rubifont] {
            for (index, source) in longLyricExamples.enumerated() {
                let store = offscreenStore(source: source)
                defer { store.engine.stop() }
                for width in [600, 1000, 1280] {
                    let viewport = CGSize(width: width - 48, height: 208)
                    let system = LyricLineWrapping.presentation(text: source, viewport: viewport)
                    let presentation = try XCTUnwrap(LyricLineWrapping.presentation(text: source, viewport: viewport, font: font))
                    let offset = try XCTUnwrap(presentation.breakOffset)
                    let characters = Array(source)
                    let rows = [String(characters[..<offset]), String(characters[offset...])]
                    let attributes: [NSAttributedString.Key: Any] = [.font: font.nativeFont(size: presentation.fontSize)]
                    for row in rows {
                        XCTAssertLessThanOrEqual((row as NSString).size(withAttributes: attributes).width, viewport.width - 2)
                    }
                    XCTAssertEqual(rows.joined(), source)
                    XCTAssertEqual(system, LyricLineWrapping.presentation(text: source, viewport: viewport))
                    let size = CGSize(width: width, height: 240)
                    let renderer = ImageRenderer(content: LyricMotionView(store: store, font: font)
                        .frame(width: size.width, height: size.height).background(.black))
                    let image = try pixels(renderer)
                    let bounds = try XCTUnwrap(image.litBounds)
                    XCTAssertGreaterThan(bounds.minX, 24)
                    XCTAssertLessThan(bounds.maxX, CGFloat(width - 24))
                    XCTAssertGreaterThan(bounds.minY, 16)
                    XCTAssertLessThan(bounds.maxY, 224)
                    try saveWrappingEvidence(renderer, name: "\(font.rawValue)-example-\(index + 1)-\(width).png")
                }
            }
        }
    }

    private let longLyricExamples = [
        "「このカキの種をまけば、毎年おいしいカキの実がなるよ。どうだい、おにぎりと交換してあげようか？」",
        "そして、お見舞いに来た友達の臼(うす→もちをつくる道具)とハチとクリにその事を話しました。"
    ]

    @MainActor
    func testLongLyricChoosesSentenceBoundaryAndBalancedRows() throws {
        let source = longLyricExamples[0]
        let presentation = try XCTUnwrap(LyricLineWrapping.presentation(text: source,
                                                                       viewport: CGSize(width: 1180, height: 160)))
        let offset = try XCTUnwrap(presentation.breakOffset)
        let characters = Array(source)
        XCTAssertEqual(String(characters[..<offset]), "「このカキの種をまけば、毎年おいしいカキの実がなるよ。")
        XCTAssertEqual(presentation.fontSize, 32)
        XCTAssertEqual(String(characters[..<offset]) + String(characters[offset...]), source)
    }

    @MainActor
    func testWrappingKeepsWordsPunctuationAndParenthesesTogether() throws {
        for source in [longLyricExamples[1], "A beautiful melody carries our memories across the quiet evening sky."] {
            let presentation = try XCTUnwrap(LyricLineWrapping.presentation(text: source,
                                                                           viewport: CGSize(width: 960, height: 160)))
            let offset = try XCTUnwrap(presentation.breakOffset)
            let characters = Array(source)
            let first = String(characters[..<offset]), second = String(characters[offset...])
            XCTAssertFalse("、。！？!?）」)]}".contains(characters[offset]))
            XCTAssertFalse("（「([{".contains(characters[offset - 1]))
            XCTAssertEqual(first + second, source)
            if source == longLyricExamples[1] {
                XCTAssertEqual(first.filter { $0 == "(" }.count, first.filter { $0 == ")" }.count,
                               "画像の括弧内の説明を途中で分けないこと")
            } else {
                XCTAssertTrue(characters[offset - 1].isWhitespace || characters[offset].isWhitespace,
                              "英単語を途中で分けないこと")
            }
        }
    }

    @MainActor
    func testShortLyricsKeepOneRowAndExtremeTextKeepsScrollingLayout() throws {
        for source in ["君の声", "Cafe\u{301}", "家族 👨‍👩‍👧‍👦 と音楽 🎵"] {
            let presentation = try XCTUnwrap(LyricLineWrapping.presentation(text: source,
                                                                           viewport: CGSize(width: 552, height: 208)))
            XCTAssertEqual(presentation.fontSize, 32)
            XCTAssertNil(presentation.breakOffset)
        }
        XCTAssertNil(LyricLineWrapping.presentation(text: String(repeating: "遠い夜の向こうから ", count: 35),
                                                   viewport: CGSize(width: 252, height: 88)))
    }

    @MainActor
    func testScreenshotExamplesRenderTwoBalancedRowsWithoutChangingSource() throws {
        var records: [[String: Any]] = []
        for (index, source) in longLyricExamples.enumerated() {
            let store = offscreenStore(source: source)
            defer { store.engine.stop() }
            for width in [600, 1000, 1280] {
                let size = CGSize(width: width, height: 240)
                let imageRenderer = renderer(for: store, size: size)
                let image = try pixels(imageRenderer)
                let rows = brightRowRanges(image, width: width)
                XCTAssertEqual(rows.count, 2, "画像\(index + 1)、幅\(width)で2行に表示すること: \(rows)")
                let viewport = CGSize(width: width - 48, height: 208)
                let presentation = try XCTUnwrap(LyricLineWrapping.presentation(text: source, viewport: viewport))
                let offset = try XCTUnwrap(presentation.breakOffset)
                let characters = Array(source)
                let first = String(characters[..<offset]), second = String(characters[offset...])
                records.append(["example": index + 1, "width": width, "font_size": presentation.fontSize,
                                "first": first, "second": second, "rendered_rows": rows.count])
                try saveWrappingEvidence(imageRenderer, name: "example-\(index + 1)-\(width).png")
                XCTAssertEqual(store.lyricTimeline?.sourceText, source)
                XCTAssertEqual(store.lyricTimeline?.lines.first?.text, source)
                XCTAssertEqual(store.lyricTimeline?.lines.first?.characterTimings.count, source.count)
            }
        }
        if let directory = ProcessInfo.processInfo.environment["MUSIC_PRAYER_LYRIC_WRAP_EVIDENCE_DIR"] {
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("line-layouts.json"))
        }
    }

    @MainActor
    func testTwoLineColourProgressAndSeekKeepOriginalCharacterTimings() throws {
        let source = longLyricExamples[0]
        let store = offscreenStore(source: source)
        defer { store.engine.stop() }
        var timeline = try XCTUnwrap(store.lyricTimeline)
        let timings = source.enumerated().map { index, _ in
            LyricCharacterTiming(start: 1 + 2 * Double(index) / Double(source.count),
                                 end: 1 + 2 * Double(index + 1) / Double(source.count))
        }
        timeline.lines[0].characterTimings = timings
        store.lyricTimeline = timeline
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        let size = CGSize(width: 1000, height: 240)
        let initial = try pixels(renderer(for: store, size: size))
        frame.time = 2.8
        publish(frame, to: store)
        let progressedRenderer = renderer(for: store, size: size)
        let progressed = try pixels(progressedRenderer)
        XCTAssertFalse(initial.bytes == progressed.bytes)
        XCTAssertEqual(brightRowRanges(progressed, width: 1000).count, 2)
        var cyanInSecondRow = 0
        for y in 120..<240 {
            for x in 0..<1000 {
                let pixel = (y * 1000 + x) * 4
                if Int(progressed.bytes[pixel + 1]) > Int(progressed.bytes[pixel]) + 50,
                   progressed.bytes[pixel + 2] > 120 { cyanInSecondRow += 1 }
            }
        }
        XCTAssertGreaterThan(cyanInSecondRow, 100, "改行後も元の文字時刻で2行目へ色が進むこと")
        try saveWrappingEvidence(progressedRenderer, name: "two-line-colour-progress.png")
        frame.time = 1
        publish(frame, to: store)
        XCTAssertEqual(initial.bytes, try pixels(renderer(for: store, size: size)).bytes)
        XCTAssertEqual(store.lyricTimeline?.lines[0].characterTimings, timings)
    }

    private func brightRowRanges(_ image: RenderedPixels, width: Int) -> [ClosedRange<Int>] {
        let height = image.bytes.count / (width * 4)
        var ranges: [ClosedRange<Int>] = []
        for y in 0..<height {
            let lit = (0..<width).contains { x in
                let offset = (y * width + x) * 4
                return Int(image.bytes[offset]) + Int(image.bytes[offset + 1]) + Int(image.bytes[offset + 2]) > 180
            }
            guard lit else { continue }
            if let last = ranges.last, y - last.upperBound <= 6 {
                ranges[ranges.count - 1] = last.lowerBound...y
            } else { ranges.append(y...y) }
        }
        return ranges
    }

    @MainActor
    private func saveWrappingEvidence<Content: View>(_ renderer: ImageRenderer<Content>, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MUSIC_PRAYER_LYRIC_WRAP_EVIDENCE_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url.appendingPathComponent(name))
    }

    @MainActor
    func testPlayerLyricPositionStaysFixedWhenAnalysisPanelOpens() throws {
        _ = NSApplication.shared
        let store = offscreenStore(source: "誰かのために 僕は歌う")
        defer { store.engine.stop() }
        for height in [800.0, 850.0, 1000.0] {
            let size = CGSize(width: 1000, height: height)
            func region(_ showAnalysis: Bool) -> some View {
                ZStack {
                    PlayerLyricRegion(store: store, size: size, headerHeight: 58)
                    if showAnalysis {
                        AnalysisPanel(analysis: MusicAnalysis(duration: 10), time: 1, duration: 10, isPlaying: false)
                            .frame(height: min(400, max(280, height - 460)))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(width: size.width, height: size.height).background(.black)
            }
            let closed = try pixels(ImageRenderer(content: region(false)))
            let opened = try pixels(ImageRenderer(content: region(true)))
            let bounds = try XCTUnwrap(closed.litBounds)
            XCTAssertEqual(bounds.midY, height * 0.24, accuracy: 3, "画像2の上寄りの位置を保つこと")
            XCTAssertGreaterThan(bounds.minY, 58, "ヘッダーに重ならないこと")
            // Compare the lyric area of the actual wrapper with a real panel sibling.
            let first = Int(bounds.minY) * 1000 * 4
            let last = Int(bounds.maxY) * 1000 * 4
            XCTAssertTrue(closed.bytes[first..<last] == opened.bytes[first..<last],
                          "解析パネルを開閉しても歌詞の画素位置を変えないこと")
        }
    }

    private func line(_ ordinal: Int, _ start: Double, _ end: Double) -> TimedLyricLine {
        TimedLyricLine(id: "line-\(ordinal)", ordinal: ordinal, text: "君の声", start: start, end: end,
                       textWeight: 3, confidence: 1)
    }

    func testSeekReturnsDestinationWithoutAnimationHistory() throws {
        let lyric = line(0, 10, 14)
        let initial = LyricMotion.parameters(for: lyric, time: 12, vocal: 0.5, beat: 1, beatPhase: 0, barPhase: 0.25)
        _ = LyricMotion.parameters(for: lyric, time: 13.9, vocal: 1, beat: 0, beatPhase: 0.9, barPhase: 0.9)
        let afterSeek = try XCTUnwrap(LyricMotion.parameters(for: lyric, time: 12, vocal: 0.5,
                                                           beat: 1, beatPhase: 0, barPhase: 0.25))
        XCTAssertEqual(initial, afterSeek)
        XCTAssertEqual(afterSeek.progress, 0.5)
        XCTAssertEqual(afterSeek.scale, 1.02, accuracy: 0.000001)
        XCTAssertEqual(afterSeek.x, 2, accuracy: 0.000001)
        XCTAssertNil(LyricMotion.parameters(for: lyric, time: 30, vocal: nil, beat: 0, beatPhase: 0, barPhase: 0))
    }

    func testShortAdjacentLinesShowOnlyOnePhrase() {
        let lines = [line(0, 10, 10.3), line(1, 10.3, 10.6), line(2, 10.6, 10.9)]
        XCTAssertEqual(LyricMotion.visibleLines(lines, at: 10.5).map(\.ordinal), [1])
        XCTAssertEqual(LyricMotion.visibleLines(lines, at: 30).count, 0)
    }

    func testFadeWindowsNeverOverlayTouchingShortOrOverlappingPhrases() {
        let cases = [
            [line(0, 10, 14), line(1, 14, 18)],
            [line(0, 10, 14), line(1, 14.2, 18)],
            [line(0, 10, 10.3), line(1, 10.3, 10.6), line(2, 10.6, 10.9)],
            [line(0, 10, 18), line(1, 12, 13), line(2, 13.1, 14)],
            [line(0, 10, 14), line(1, 10, 12), line(2, 12, 14)]
        ]
        for lines in cases {
            let windows = LyricMotion.displayWindows(lines)
            var previousOrdinal = -1
            for time in stride(from: 9.5, through: 18.5, by: 0.005) {
                let visible = LyricMotion.visibleLines(lines, at: time, windows: windows)
                XCTAssertLessThanOrEqual(visible.count, 1, "別フレーズを同じ場所へ重ねないこと")
                if let ordinal = visible.first?.ordinal {
                    XCTAssertGreaterThanOrEqual(ordinal, previousOrdinal, "古いフレーズを再表示しないこと")
                    previousOrdinal = ordinal
                }
            }
        }
    }

    func testSharedBoundaryFadesToZeroThenInAndSeeksDeterministically() throws {
        let lines = [line(0, 10, 14), line(1, 14.3, 18)]
        let windows = LyricMotion.displayWindows(lines)
        let boundary = try XCTUnwrap(windows[0]).end
        func motion(_ ordinal: Int, at time: Double) throws -> LyricMotionParameters {
            try XCTUnwrap(LyricMotion.parameters(for: lines[ordinal], time: time, vocal: nil,
                beat: 0, beatPhase: 0, barPhase: 0, window: windows[ordinal]))
        }
        XCTAssertEqual(try motion(0, at: boundary).opacity, 0, accuracy: 1e-12)
        XCTAssertEqual(try motion(1, at: boundary).opacity, 0, accuracy: 1e-12)
        XCTAssertTrue(LyricMotion.visibleLines(lines, at: boundary, windows: windows).isEmpty)
        XCTAssertLessThan(try motion(0, at: boundary - 0.001).opacity, 0.001)
        XCTAssertLessThan(try motion(1, at: boundary + 0.001).opacity, 0.001)
        XCTAssertGreaterThan(try motion(0, at: 13.8).opacity, 0.1)
        XCTAssertGreaterThan(try motion(1, at: 14.2).opacity, 0.1)
        let initial = try motion(1, at: 14.2)
        _ = try motion(1, at: 17)
        XCTAssertEqual(initial, try motion(1, at: 14.2))
        XCTAssertEqual(LyricMotion.visibleLines(lines, at: 13.8, windows: windows).map(\.ordinal), [0])
        XCTAssertEqual(lines.map(\.start), [10, 14.3])
        XCTAssertEqual(lines.map(\.end), [14, 18])
    }

    func testFadesStayOutsideVocalsAndNoGapNeverDelaysTheNextEntrance() throws {
        for gap in [0.0, 0.02, 0.2, 0.7, 2.0] {
            let lines = [line(0, 10, 14), line(1, 14 + gap, 18)]
            let windows = LyricMotion.displayWindows(lines)
            for line in lines {
                let window = try XCTUnwrap(windows[line.ordinal])
                XCTAssertLessThanOrEqual(window.entranceEnd, line.start)
                XCTAssertGreaterThanOrEqual(window.exitStart, line.end)
                for time in stride(from: line.start, to: line.end, by: 0.01) {
                    let motion = try XCTUnwrap(LyricMotion.parameters(for: line, time: time, vocal: nil,
                        beat: 0, beatPhase: 0, barPhase: 0, window: window))
                    XCTAssertEqual(motion.opacity, 1, accuracy: 1e-10, "歌唱中に歌詞を薄くしないこと")
                    XCTAssertEqual(motion.blur, 0, accuracy: 1e-10)
                }
            }
            XCTAssertEqual(LyricMotion.visibleLines(lines, at: lines[1].start, windows: windows).map(\.ordinal), [1])
        }
    }

    func testSeparatedPhrasesKeepExistingEntranceAndExitFades() throws {
        let lines = [line(0, 10, 14), line(1, 16, 18)]
        let windows = LyricMotion.displayWindows(lines)
        for time in [9.7, 10, 12, 14.1, 14.3] {
            let original = try XCTUnwrap(LyricMotion.parameters(for: lines[0], time: time, vocal: nil,
                beat: 0, beatPhase: 0, barPhase: 0))
            let coordinated = try XCTUnwrap(LyricMotion.parameters(for: lines[0], time: time, vocal: nil,
                beat: 0, beatPhase: 0, barPhase: 0, window: windows[0]))
            XCTAssertEqual(original, coordinated)
        }
    }

    @MainActor
    func testLocalFrameBoundaryUsesSameFadeWindowsAsUnframedLyrics() throws {
        let store = offscreenStore(source: "前の歌詞")
        defer { store.engine.stop() }
        var timeline = try XCTUnwrap(store.lyricTimeline)
        timeline.lines = [line(0, 1, 3), line(1, 3, 5)]
        for index in timeline.lines.indices {
            timeline.lines[index].characterTimings = timeline.lines[index].text.map { _ in
                LyricCharacterTiming(start: timeline.lines[index].start, end: timeline.lines[index].end)
            }
        }
        timeline.frames = [
            .init(start: 0, end: 3, section: 0, segment: 0, lineOrdinals: [0], support: .init()),
            .init(start: 3, end: 6, section: 1, segment: 0, lineOrdinals: [1], support: .init())
        ]
        store.lyricTimeline = timeline
        let windows = LyricMotion.displayWindows(timeline.lines)
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        for time in [2.8, 2.999, 3, 3.001, 3.2] {
            XCTAssertEqual(LyricMotion.visibleLines(timeline, at: time, windows: windows),
                           LyricMotion.visibleLines(timeline.lines, at: time, windows: windows))
            frame.time = time
            publish(frame, to: store)
            let image = try pixels(renderer(for: store))
            if time == 3 { XCTAssertGreaterThan(image.litPixels, 30, "空き時間がない境界では次の歌詞をすぐ読めること") }
            if time == 2.8 || time == 3.2 { XCTAssertGreaterThan(image.litPixels, 30) }
        }
        XCTAssertEqual(store.lyricTimeline, timeline, "表示の調整で歌詞や色の時刻を変更しないこと")
    }

    func testColourUsesEachSpeechIntervalAndWaitsThroughItsGap() {
        let first = LyricCharacterTiming(start: 10, end: 10.4)
        let next = LyricCharacterTiming(start: 12, end: 12.4)
        XCTAssertEqual(LyricMotion.emphasis(time: 9.9, timing: first), 0)
        XCTAssertEqual(LyricMotion.emphasis(time: 10.2, timing: first), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LyricMotion.emphasis(time: 11.9, timing: first), 1)
        XCTAssertEqual(LyricMotion.emphasis(time: 11.9, timing: next), 0)
        XCTAssertEqual(LyricMotion.emphasis(time: 12.2, timing: next), 0.5, accuracy: 1e-9)
        // Seeking back reads the same interval, without accumulated animation.
        XCTAssertEqual(LyricMotion.emphasis(time: 11.9, timing: next), 0)
        let punctuation = LyricCharacterTiming(start: 10.4, end: 10.4)
        XCTAssertEqual(LyricMotion.emphasis(time: 10.39, timing: punctuation), 0)
        XCTAssertEqual(LyricMotion.emphasis(time: 10.4, timing: punctuation), 1)
    }

    @MainActor
    func testSharedRendererColoursEstimatedRowsAndKeepsRecognizedTimesFirst() throws {
        _ = NSApplication.shared
        let line = TimedLyricLine(id: "estimated", ordinal: 0, text: "色の進行を確認する",
                                  start: 1, end: 5, textWeight: 9, confidence: 1)
        let motion = try XCTUnwrap(LyricMotion.parameters(for: line, time: 3, vocal: nil,
                                                         beat: 0, beatPhase: 0, barPhase: 0))
        func cyanCount(_ progress: Double, timings: [LyricCharacterTiming] = []) throws -> Int {
            let rendered = try pixels(ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: timings,
                motion: motion, time: 3, viewport: CGSize(width: 600, height: 220), font: .system,
                estimatedProgress: progress).background(.black)))
            return stride(from: 0, to: rendered.bytes.count, by: 4).filter { offset in
                Int(rendered.bytes[offset + 1]) > Int(rendered.bytes[offset]) + 50 && rendered.bytes[offset + 2] > 120
            }.count
        }
        let early = try cyanCount(0.25)
        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(try cyanCount(0.75), early + 100)
        XCTAssertEqual(try cyanCount(0), 0)
        XCTAssertEqual(try cyanCount(0.25), early)
        XCTAssertEqual(try cyanCount(1, timings: line.text.map { _ in LyricCharacterTiming(start: 4, end: 5) }), 0)
        XCTAssertTrue(line.characterTimings.isEmpty)
    }

    @MainActor
    func testSharedRendererDoesNotInventColourProgressWithoutCharacterTimestamps() throws {
        _ = NSApplication.shared
        let line = TimedLyricLine(id: "line-progress", ordinal: 0, text: "歌詞の色を確認します",
                                  start: 1, end: 5, textWeight: 10, confidence: 1)
        func cyanCount(at time: Double) throws -> Int {
            let motion = try XCTUnwrap(LyricMotion.parameters(for: line, time: time, vocal: nil,
                                                             beat: 0, beatPhase: 0, barPhase: 0))
            let rendered = try pixels(ImageRenderer(content: LyricMotionLineView(line: line, colourTimings: [],
                motion: motion, time: time, viewport: CGSize(width: 600, height: 220), font: .system).background(.black)))
            return stride(from: 0, to: rendered.bytes.count, by: 4).filter { offset in
                Int(rendered.bytes[offset + 1]) > Int(rendered.bytes[offset]) + 50 && rendered.bytes[offset + 2] > 120
            }.count
        }
        let start = try cyanCount(at: 1), middle = try cyanCount(at: 3), end = try cyanCount(at: 4.99)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(middle, 0, "時刻のない文字を行の時間で均等に塗らない")
        XCTAssertEqual(end, 0)
        XCTAssertEqual(try cyanCount(at: 1), 0)
        XCTAssertTrue(line.characterTimings.isEmpty, "表示のために文字時刻を捏造・保存しない")
    }

    @MainActor
    func testSharedLineRendererUsesCharacterTimesAndRestoresColourAfterSeek() throws {
        _ = NSApplication.shared
        let text = "歌詞の色を確認"
        let timings = text.enumerated().map { index, _ in
            LyricCharacterTiming(start: 1 + Double(index) * 0.2, end: 1.2 + Double(index) * 0.2)
        }
        let lyric = TimedLyricLine(id: "word-timed", ordinal: 0, text: text, start: 1, end: 3,
                                  textWeight: 7, confidence: 1, characterTimings: timings)
        let viewport = CGSize(width: 600, height: 220)
        func image(at time: Double) throws -> RenderedPixels {
            let motion = try XCTUnwrap(LyricMotion.parameters(for: lyric, time: time, vocal: nil,
                                                             beat: 0, beatPhase: 0, barPhase: 0))
            return try pixels(ImageRenderer(content: LyricMotionLineView(line: lyric, colourTimings: lyric.characterTimings,
                motion: motion, time: time, viewport: viewport, font: .system).background(.black)))
        }
        func cyanPixels(_ image: RenderedPixels) -> Int {
            stride(from: 0, to: image.bytes.count, by: 4).filter { offset in
                Int(image.bytes[offset + 1]) > Int(image.bytes[offset]) + 50 && image.bytes[offset + 2] > 120
            }.count
        }
        let initial = try image(at: 1)
        let progressed = try image(at: 2.9)
        XCTAssertGreaterThan(initial.litPixels, 100)
        XCTAssertGreaterThan(cyanPixels(progressed), cyanPixels(initial) + 100,
                             "共通描画が文字時刻に沿って青へ変化すること")
        XCTAssertEqual(initial.bytes, try image(at: 1).bytes, "シークで開始時の色に戻ること")
        XCTAssertEqual(lyric.characterTimings, timings, "描画で取得した文字時刻を変えないこと")
    }

    @MainActor
    func testSharedLineRendererKeepsMainBranchWhiteAndCyanInBothAppearances() throws {
        _ = NSApplication.shared
        let text = "歌詞の色を確認"
        let timings = text.enumerated().map { index, _ in
            LyricCharacterTiming(start: 1 + Double(index) * 0.2, end: 1.2 + Double(index) * 0.2)
        }
        let lyric = TimedLyricLine(id: "appearance-colours", ordinal: 0, text: text, start: 1, end: 3,
                                  textWeight: 7, confidence: 1, characterTimings: timings)
        let time = 1.7
        let motion = try XCTUnwrap(LyricMotion.parameters(for: lyric, time: time, vocal: nil,
                                                         beat: 0, beatPhase: 0, barPhase: 0))
        let viewport = CGSize(width: 600, height: 220)
        var images: [RenderedPixels] = []
        for appearance in [ColorScheme.light, .dark] {
            let image = try pixels(ImageRenderer(content: LyricMotionLineView(line: lyric, colourTimings: timings,
                motion: motion, time: time, viewport: viewport, font: .system)
                .environment(\.colorScheme, appearance).background(.black)))
            var whitePixels = 0, cyanPixels = 0
            for offset in stride(from: 0, to: image.bytes.count, by: 4) {
                let red = Int(image.bytes[offset]), green = Int(image.bytes[offset + 1]), blue = Int(image.bytes[offset + 2])
                if red >= 220 && green >= 220 && blue >= 220 { whitePixels += 1 }
                if red < 140 && green >= 170 && blue >= 200 && green > red + 80 { cyanPixels += 1 }
            }
            XCTAssertGreaterThan(whitePixels, 30, "未到達の文字は、外観に関係なくメインブランチと同じ白で描くこと")
            XCTAssertGreaterThan(cyanPixels, 30, "到達済みの文字は、外観に関係なくメインブランチと同じ明るいシアンで描くこと")
            images.append(image)
        }
        let maximumDifference = zip(images[0].bytes, images[1].bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, 1, "外観の切替で歌詞の文字色や着色範囲を変更しないこと")
    }

    @MainActor
    func testOffscreenRowIsReadableAtMusicalEntranceBeforeLateSpeechStart() throws {
        let store = offscreenStore(source: "歌い出し")
        defer { store.engine.stop() }
        var timeline = try XCTUnwrap(store.lyricTimeline)
        timeline.lines[0].start = 2.2
        timeline.lines[0].characterTimings = timeline.lines[0].text.map { _ in
            LyricCharacterTiming(start: 2.2, end: 3)
        }
        timeline.frames = [LyricStructureFrame(start: 1, end: 5, section: 0, segment: 0,
                                               lineOrdinals: [0], support: LyricFrameSupport())]
        store.lyricTimeline = timeline
        var analysis = MusicAnalysis(fingerprint: timeline.analysisFingerprint, duration: 10)
        analysis.bars = [1, 5]
        analysis.instrumentRanges.vocal = [TimeSpan(start: 1.15, duration: 3.85)]
        store.analysis = analysis
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        frame.time = 1.5
        publish(frame, to: store)
        XCTAssertGreaterThan(try pixels(renderer(for: store)).litPixels, 30,
                             "対応するフレーズ・小節・歌声が始まれば認識開始前にも本文を読めること")
        XCTAssertEqual(LyricMotion.emphasis(time: 1.5, timing: timeline.lines[0].characterTimings[0]), 0)
        XCTAssertEqual(store.lyricTimeline, timeline, "表示の前倒しで保存用の認識時刻を変えないこと")
        frame.time = 0.79
        publish(frame, to: store)
        XCTAssertEqual(try pixels(renderer(for: store)).litPixels, 0, "対応する表示開始のフェード窓より前には本文を出さないこと")
    }

    @MainActor
    func testOffscreenMissingLeadingSpellingColoursBeforeSpeechAndResetsOnSeek() throws {
        let store = offscreenStore(source: "ああ星の海")
        defer { store.engine.stop() }
        var timeline = try XCTUnwrap(store.lyricTimeline)
        timeline.lines[0].start = 2.2
        let first = LyricCharacterTiming(start: 2.2, end: 2.4)
        timeline.lines[0].characterTimings = [first, first, first,
            .init(start: 2.4, end: 2.6), .init(start: 2.6, end: 3)]
        timeline.frames = [.init(start: 1, end: 5, section: 0, segment: 0,
                                  lineOrdinals: [0], support: LyricFrameSupport())]
        store.lyricTimeline = timeline
        var analysis = MusicAnalysis(fingerprint: timeline.analysisFingerprint, duration: 10)
        analysis.bars = [1]
        analysis.instrumentRanges.vocal = [TimeSpan(start: 1.15, duration: 3.85)]
        store.analysis = analysis
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        frame.time = 1.8
        publish(frame, to: store)
        let white = try pixels(renderer(for: store))
        timeline.lines[0].unrecognizedLeadingCharacters = 2
        store.lyricTimeline = timeline
        let coloured = try pixels(renderer(for: store))
        XCTAssertGreaterThan(white.litPixels, 30)
        XCTAssertFalse(white.bytes == coloured.bytes, "認識から抜けた先頭文字も、行が出た後には色を進めること")
        let colours = LyricMotion.colourTimings(for: timeline.lines[0], displayStart: 1.15)
        XCTAssertGreaterThan(LyricMotion.emphasis(time: frame.time, timing: colours[0]), 0)
        XCTAssertEqual(LyricMotion.emphasis(time: frame.time, timing: colours[2]), 0)
        frame.time = 1.15
        publish(frame, to: store)
        let reset = try pixels(renderer(for: store))
        timeline.lines[0].unrecognizedLeadingCharacters = nil
        store.lyricTimeline = timeline
        XCTAssertEqual(reset.bytes, try pixels(renderer(for: store)).bytes,
                       "歌唱前へシークした文字は白へ戻ること")
    }

    @MainActor
    func testOffscreenUnicodeTextKeepsTheUnstyledGlyphLayout() throws {
        _ = NSApplication.shared
        for source in ["遠い夜の向こうから", "Cafe\u{301}", "家族 👨‍👩‍👧‍👦 と音楽 🎵", "office affinity ffi"] {
            let store = offscreenStore(source: source)
            defer { store.engine.stop() }
            let rendered = try pixels(renderer(for: store))
            let viewport = CGSize(width: 552, height: 208)
            let reference = ImageRenderer(content:
                Text(verbatim: source)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: viewport.width, height: viewport.height)
                    .shadow(color: Color(red: 0.24, green: 0.87, blue: 1).opacity(0.15), radius: 2)
                    .frame(width: 600, height: 240).background(.black))
            let expected = try pixels(reference)
            XCTAssertGreaterThan(rendered.litPixels, 30, source)
            // Compare glyph coverage rather than exact antialiasing bytes. The custom
            // renderer draws slices, while the ordinary Text renderer draws whole runs.
            XCTAssertEqual(Double(rendered.litPixels) / Double(expected.litPixels), 1,
                           accuracy: 0.20, source)
            let bounds = try XCTUnwrap(rendered.litBounds, source)
            let expectedBounds = try XCTUnwrap(expected.litBounds, source)
            XCTAssertEqual(bounds.width, expectedBounds.width, accuracy: 3, source)
            XCTAssertEqual(bounds.height, expectedBounds.height, accuracy: 3, source)
            XCTAssertEqual(store.lyricTimeline?.sourceText, source)
            XCTAssertEqual(store.lyricTimeline?.lines.first?.text, source)
        }
    }

    @MainActor
    func testOffscreenEntranceProgressAndExitRenderDifferentImages() throws {
        let store = offscreenStore(source: "君の声が聞こえる")
        defer { store.engine.stop() }
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        frame.time = 1 - 0.175
        publish(frame, to: store)
        let entrance = try pixels(renderer(for: store))
        frame.time = 2
        publish(frame, to: store)
        let singing = try pixels(renderer(for: store))
        frame.time = 3 + 0.20
        publish(frame, to: store)
        let exit = try pixels(renderer(for: store))
        XCTAssertGreaterThan(entrance.litPixels, 0)
        XCTAssertGreaterThan(singing.litPixels, 0)
        XCTAssertGreaterThan(exit.litPixels, 0)
        XCTAssertFalse(entrance.bytes == singing.bytes, "開始前と歌唱中は異なる画像になること")
        XCTAssertFalse(singing.bytes == exit.bytes, "歌唱中と終了後は異なる画像になること")
        XCTAssertFalse(entrance.bytes == exit.bytes, "開始前と終了後は異なる画像になること")
        XCTAssertLessThan(entrance.totalBrightness, singing.totalBrightness)
        XCTAssertLessThan(exit.totalBrightness, singing.totalBrightness)
    }

    @MainActor
    func testOffscreenSnapshotIdentityMismatchHidesLyrics() throws {
        let store = offscreenStore(source: "同じ曲をもう一度")
        defer { store.engine.stop() }
        let matching = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        XCTAssertGreaterThan(try pixels(renderer(for: store)).litPixels, 0)
        var wrongTrack = matching
        wrongTrack.trackID = UUID()
        var wrongGeneration = matching
        wrongGeneration.playbackGeneration += 1
        var wrongAudio = matching
        wrongAudio.audioFingerprint = String(repeating: "b", count: 64)
        for mismatch in [wrongTrack, wrongGeneration, wrongAudio] {
            publish(mismatch, to: store)
            XCTAssertEqual(try pixels(renderer(for: store)).litPixels, 0)
        }
        publish(matching, to: store)
        XCTAssertGreaterThan(try pixels(renderer(for: store)).litPixels, 0)
    }

    @MainActor
    func testOffscreenColourStaysWhiteUntilItsRecognizedInterval() async throws {
        let store = offscreenStore(source: "歌い出し")
        defer { store.engine.stop() }
        var timeline = try XCTUnwrap(store.lyricTimeline)
        timeline.lines[0].characterTimings = timeline.lines[0].text.map { _ in
            LyricCharacterTiming(start: 2, end: 3)
        }
        store.lyricTimeline = timeline
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        frame.time = 1.2
        publish(frame, to: store)
        let image = renderer(for: store)
        image.isObservationEnabled = true
        let waiting = try pixels(image)
        frame.time = 1.8
        try await expectRendererUpdate(image) { publish(frame, to: store) }
        XCTAssertTrue(waiting.bytes == (try pixels(image)).bytes,
                       "行の時間が進んでも、認識区間前の文字を青くしないこと")
        frame.time = 2.5
        try await expectRendererUpdate(image) { publish(frame, to: store) }
        XCTAssertFalse(waiting.bytes == (try pixels(image)).bytes)
        frame.time = 1.8
        try await expectRendererUpdate(image) { publish(frame, to: store) }
        let returned = try pixels(image)
        XCTAssertEqual(waiting.litPixels, returned.litPixels)
        // Allow one quantization step in an 8-bit raster after rebuilding the view.
        let maximumDifference = zip(waiting.bytes, returned.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, 1)
    }

    @MainActor
    func testOffscreenPausedRevisionRefreshesAnExistingViewAtPreviewTime() async throws {
        let audio = try silentAudioFixture()
        defer { try? FileManager.default.removeItem(at: audio) }
        let store = offscreenStore(source: "停止中でも歌詞の位置は変わる")
        try store.engine.load(url: audio)
        defer { store.engine.unload() }
        store.duration = store.engine.duration
        store.previewTime = 1
        let renderer = renderer(for: store)
        renderer.isObservationEnabled = true
        let initial = try pixels(renderer)
        XCTAssertFalse(store.isPlaying)
        let revision = store.lyricFrameRevision
        try await expectRendererUpdate(renderer) { store.previewTime = 2 }
        XCTAssertGreaterThan(store.lyricFrameRevision, revision)
        XCTAssertEqual(store.visualSource.snapshot().lyrics?.time, 2)
        let progressed = try pixels(renderer)
        XCTAssertGreaterThan(progressed.litPixels, 0)
        XCTAssertFalse(initial.bytes == progressed.bytes, "同じ停止中ビューへ通知後に進行した文字を描画すること")
        try await expectRendererUpdate(renderer) { store.previewTime = 4 }
        XCTAssertEqual(try pixels(renderer).litPixels, 0)
        try await expectRendererUpdate(renderer) { store.previewTime = 1 }
        XCTAssertGreaterThan(try pixels(renderer).litPixels, 0)
    }

    @MainActor
    func testOffscreenLongLineScrollsWithinItsViewportWithoutTruncatingSource() throws {
        let source = String(repeating: "遠い夜の向こうから ", count: 35)
        let store = offscreenStore(source: source)
        defer { store.engine.stop() }
        var frame = try XCTUnwrap(store.visualSource.snapshot().lyrics)
        let early = try pixels(renderer(for: store, size: CGSize(width: 300, height: 120)))
        frame.time = 2.95
        publish(frame, to: store)
        let late = try pixels(renderer(for: store, size: CGSize(width: 300, height: 120)))
        XCTAssertGreaterThan(early.litPixels, 50)
        XCTAssertGreaterThan(late.litPixels, 50)
        XCTAssertFalse(early.bytes == late.bytes, "長い行の開始付近と終了付近は異なる画像になること")
        for image in [early, late] {
            let bounds = try XCTUnwrap(image.litBounds)
            XCTAssertGreaterThanOrEqual(bounds.minX, 24)
            XCTAssertLessThanOrEqual(bounds.maxX, 276)
            XCTAssertGreaterThanOrEqual(bounds.minY, 16)
            XCTAssertLessThanOrEqual(bounds.maxY, 104)
        }
        XCTAssertEqual(store.lyricTimeline?.sourceText, source)
        XCTAssertEqual(store.lyricTimeline?.lines.first?.text, source)
    }

    @MainActor
    private func offscreenStore(source: String) -> PlayerStore {
        // Never select/load an audio file or call persistence. These tests use only
        // in-memory playback values and ImageRenderer, not the real app window.
        let store = PlayerStore(appleMusicAnalysisDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerAnalysisTests-" + UUID().uuidString))
        store.tracks = [Track(url: URL(fileURLWithPath: "/nonexistent/offscreen-lyrics.wav"))]
        store.playbackGeneration = 7
        store.duration = 10
        store.lyricFingerprint = String(repeating: "a", count: 64)
        let parsed = LyricParser.parse(source)[0]
        let timed = TimedLyricLine(id: "offscreen-line", ordinal: 0, text: parsed.text, start: 1, end: 3,
                                   textWeight: parsed.textWeight, confidence: 1,
                                   characterTimings: source.map { _ in LyricCharacterTiming(start: 1, end: 3) })
        store.lyricTimeline = LyricTimeline(version: LyricVersions.alignment,
                                            analysisVersion: MusicAnalyzer.cacheVersion,
                                            analysisFingerprint: store.lyricFingerprint!,
                                            analysisDigest: String(repeating: "d", count: 64),
                                            sourceText: source, sourceTextHash: LyricHash.text(source),
                                            mode: .speechRecognition, lines: [timed], confidence: 1,
                                            frames: [LyricStructureFrame(start: 0, end: 10, section: 0, segment: 0,
                                                lineOrdinals: [0], support: LyricFrameSupport())])
        // Layout fixtures represent preparation completed with no override.
        store.lyricReadings = LyricReadings(sourceTextHash: LyricHash.text(source), lines: [source: []])
        let frame = LyricPlaybackFrame(trackID: store.currentTrack?.id, playbackGeneration: 7,
                                       audioFingerprint: store.lyricFingerprint, time: 1, duration: 10,
                                       isPlaying: false, isPreviewing: false, vocal: nil, beat: 0,
                                       beatPhase: 0, barPhase: 0, phraseProgress: 0, sectionProgress: 0)
        publish(frame, to: store)
        return store
    }

    @MainActor
    private func publish(_ payload: LyricPlaybackFrame, to store: PlayerStore) {
        var frame = VisualFrame()
        frame.lyrics = payload
        store.visualSource.publish(frame)
        store.lyricFrameRevision += 1
    }

    @MainActor
    private func renderer(for store: PlayerStore, size: CGSize = CGSize(width: 600, height: 240))
        -> ImageRenderer<some View> {
        ImageRenderer(content: LyricMotionView(store: store)
            .frame(width: size.width, height: size.height).background(.black))
    }

    @MainActor
    private func expectRendererUpdate<Content: View>(_ renderer: ImageRenderer<Content>,
                                                    change: () -> Void) async throws {
        // Apple documents ImageRenderer's objectWillChange as the signal to obtain
        // its next rasterized image. Reading cgImage in the mutation's same stack
        // can instead return the previous cached image.
        let updated = expectation(description: "停止中のImageRendererが内容変更を通知")
        let subscription = renderer.objectWillChange.first().sink { _ in updated.fulfill() }
        defer { subscription.cancel() }
        change()
        await fulfillment(of: [updated], timeout: 0.5)
        await Task.yield()
    }

    private func silentAudioFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicPrayerOffscreen-\(UUID().uuidString).wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let frameCount: AVAudioFrameCount = 441_000
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<Int(frameCount) { channel[index] = 0 }
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            try writer.write(from: buffer)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @MainActor
    private func pixels<Content: View>(_ renderer: ImageRenderer<Content>) throws -> RenderedPixels {
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUIの画面外レンダリングが画像を返すこと")
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                                    CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var litPixels = 0, brightness = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                brightness += value
                if value > 36 {
                    litPixels += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let bounds = litPixels == 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return RenderedPixels(bytes: bytes, litPixels: litPixels, totalBrightness: brightness, litBounds: bounds)
    }
}

private struct RenderedPixels {
    var bytes: [UInt8]
    var litPixels: Int
    var totalBrightness: Int
    var litBounds: CGRect?
}
