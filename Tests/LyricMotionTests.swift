import AppKit
import AVFoundation
import Combine
import SwiftUI
import XCTest
@testable import MusicPrayer

final class LyricMotionTests: XCTestCase {
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

    func testShortAdjacentLinesKeepSingingLineAndOnlyStrongestNeighbour() {
        let lines = [line(0, 10, 10.3), line(1, 10.3, 10.6), line(2, 10.6, 10.9)]
        XCTAssertEqual(LyricMotion.visibleLines(lines, at: 10.5).map(\.ordinal), [1, 2])
        XCTAssertEqual(LyricMotion.visibleLines(lines, at: 30).count, 0)
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
        let store = PlayerStore()
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
