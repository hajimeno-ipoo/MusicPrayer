import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class AnalysisTimelineTests: XCTestCase {
    func testAllStructureAndInstrumentResultsReachTheirDisplayRows() {
        var analysis = MusicAnalysis(duration: 12)
        analysis.sections = [TimeSpan(start: 0, duration: 12)]
        analysis.segments = [TimeSpan(start: 1, duration: 10)]
        analysis.phrases = [TimeSpan(start: 2, duration: 3)]
        analysis.beats = [1, 2, 3]
        analysis.bars = [1, 3]
        analysis.instrumentRanges = InstrumentRanges(vocal: [TimeSpan(start: 2, duration: 4)],
            drums: [TimeSpan(start: 3, duration: 3)], bass: [TimeSpan(start: 4, duration: 2)],
            other: [TimeSpan(start: 5, duration: 1)])
        analysis.keys = [KeySpan(range: TimeSpan(start: 2, duration: 3), label: "A minor", hue: 0, minor: true)]
        let rows = AnalysisTimelineRow.rows(for: analysis, at: 3)
        XCTAssertEqual(rows.map(\.name), ["大きな区間", "小さな区間", "フレーズ", "拍・小節",
            "歌声の区間", "ドラムの区間", "低音の区間", "その他の区間",
            "調性の区間"])
        let spans = [analysis.sections, analysis.segments, analysis.phrases,
                     analysis.instrumentRanges.vocal, analysis.instrumentRanges.drums,
                     analysis.instrumentRanges.bass, analysis.instrumentRanges.other]
        for (rowIndex, expected) in zip([0, 1, 2, 4, 5, 6, 7], spans) {
            guard case .spans(let actual) = rows[rowIndex].data else { return XCTFail("区間行の型が違う") }
            XCTAssertEqual(actual.map(\.start), expected.map(\.start))
            XCTAssertEqual(actual.map(\.duration), expected.map(\.duration))
        }
        guard case .rhythm(let beats, let bars) = rows[3].data,
              case .keys(let keys) = rows[8].data else { return XCTFail("拍・小節・調性の型が違う") }
        XCTAssertEqual(beats, analysis.beats)
        XCTAssertEqual(bars, analysis.bars)
        XCTAssertEqual(keys.map(\.label), ["A minor"])
        XCTAssertEqual(keys.first?.range.duration, 3)
        XCTAssertEqual(rows[8].currentValue(at: 6), "未取得")
        XCTAssertEqual(rows[4].currentValue(at: 7), "区間外")
        XCTAssertTrue(AnalysisTimelineRow.rows(for: MusicAnalysis(duration: 12), at: 3)
            .allSatisfy { $0.currentValue(at: 3) == "未取得" })
    }

    func testLoudnessShowsQuietSamplesAndFitsEachVisibleSeriesWithoutChangingObservations() throws {
        let values = [TimeValue(time: 0, value: -87.285934), TimeValue(time: 1, value: -65),
                      TimeValue(time: 100, value: -13.5), TimeValue(time: 101, value: -12.5),
                      TimeValue(time: 200, value: 20)]
        let scale = try XCTUnwrap(AnalysisLoudnessScale(values: values, window: 100...101))
        XCTAssertLessThanOrEqual(scale.range.lowerBound, -13.5)
        XCTAssertGreaterThanOrEqual(scale.range.upperBound, -12.5)
        XCTAssertLessThanOrEqual(scale.range.upperBound - scale.range.lowerBound, 4,
                                 "曲頭の静音や他区間の値で表示中の変化を潰さない")
        let quiet = try XCTUnwrap(AnalysisLoudnessScale(values: values, window: 0...1))
        XCTAssertLessThan(quiet.range.lowerBound, -87)
        XCTAssertNotEqual(quiet.y(-87.285934, height: 90), quiet.y(-65, height: 90))
        let labels = scale.tickLabels(height: 70)
        XCTAssertEqual(labels.first, scale.range.upperBound)
        XCTAssertEqual(labels.last, scale.range.lowerBound)
        for (upper, lower) in zip(labels, labels.dropFirst()) {
            XCTAssertGreaterThanOrEqual(scale.y(lower, height: 70) - scale.y(upper, height: 70), 12)
        }
        var vertices: [CGPoint] = []
        AnalysisTimelineRow.valuePath(values, range: scale.range, height: 90, clampToRange: false)
            .forEach { element in
                switch element { case .move(let point), .line(let point): vertices.append(point); default: break }
            }
        XCTAssertEqual(vertices.count, values.count)
        XCTAssertGreaterThan(vertices[0].y, 90, "画面外の値も原値の座標を保持し、描画時だけクリップする")
        XCTAssertGreaterThan(abs(vertices[2].y - vertices[3].y), 20)
        XCTAssertEqual(AnalysisTimelineRow.sample(values, at: 100.5), values[2])
        XCTAssertNil(AnalysisTimelineRow.sample(values, at: -1))
        XCTAssertNil(AnalysisLoudnessScale(values: []))
        XCTAssertNil(AnalysisLoudnessScale(values: values, window: 30...40),
                     "欠測区間の目盛りを他の時刻から作らない")
    }

    func testFollowHandlesBeginningEndAndBackwardSeekWithoutBlankTail() {
        let axis = AnalysisTimeAxis(duration: 320.8, viewportWidth: 1000)
        XCTAssertEqual(axis.offset(at: 2), 0)
        XCTAssertEqual(axis.offset(at: 150), 5500)
        XCTAssertEqual(axis.offset(at: 999), axis.contentWidth - 1000)
        _ = axis.offset(at: 300)
        XCTAssertEqual(axis.offset(at: 20), 300)
        XCTAssertEqual(axis.offset(at: -1), 0)
        let short = AnalysisTimeAxis(duration: 10, viewportWidth: 1000)
        XCTAssertEqual(short.contentWidth, 1000)
        XCTAssertEqual(short.offset(at: 10), 0)
        let resized = AnalysisTimeAxis(duration: 320.8, viewportWidth: 500)
        XCTAssertEqual(resized.offset(at: 150) + 250, axis.offset(at: 150) + 500)
    }

    func testClockRoundingCarriesIntoTheNextMinute() {
        XCTAssertEqual(AnalysisTimeAxis.preciseClock(59.96), "1:00.0")
        XCTAssertEqual(AnalysisTimeAxis.preciseClock(119.96), "2:00.0")
        XCTAssertEqual(AnalysisTimeAxis.preciseClock(7.24), "0:07.2")
    }

    @MainActor
    func testNativeScrollViewFollowsPlaybackAndSeekAndKeepsPausedManualPosition() async throws {
        try await checkNativeFollow(loudness: false)
    }

    @MainActor
    func testNativeLoudnessScrollFollowsPlaybackAndKeepsPeakAtSongEndInsideViewport() async throws {
        try await checkNativeFollow(loudness: true)
    }

    @MainActor
    private func checkNativeFollow(loudness: Bool) async throws {
        _ = NSApplication.shared
        let state = AnalysisPanelTestState()
        let hosting = NSHostingView(rootView: AnalysisPanelTestView(state: state, loudness: loudness))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1000, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func settle() async throws {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            hosting.layoutSubtreeIfNeeded()
        }
        func horizontal(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width + 100 {
                return scroll
            }
            return view.subviews.compactMap { horizontal(in: $0) }.first
        }
        try await settle()
        let scroll = try XCTUnwrap(horizontal(in: hosting), "実際の横スクロールビューを取得すること")
        let width = scroll.contentView.bounds.width
        XCTAssertGreaterThan(width, 500)
        XCTAssertEqual(scroll.contentView.bounds.minX, 6000 - width / 2, accuracy: 2)
        state.isPlaying = true
        state.time = 151
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minX, 6040 - width / 2, accuracy: 2)
        state.isPlaying = false
        try await settle()
        scroll.contentView.scroll(to: CGPoint(x: 1000, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minX, 1000, accuracy: 2)
        state.time = 20
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minX, 800 - width / 2, accuracy: 2)
        state.time = 319
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.maxX, loudness ? 12809 : 12801, accuracy: 2)
        if loudness {
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxX, 12804, "曲末のピーク時刻マーカーを切らない")
        }
    }

    @MainActor
    func testRenderedLoudnessKeepsBothCurvesAndPeakTimestampWithoutInventingPeakSeries() throws {
        _ = NSApplication.shared
        var analysis = MusicAnalysis(duration: 12)
        analysis.momentary = [TimeValue(time: 0, value: -87), TimeValue(time: 5, value: -10), TimeValue(time: 12, value: -20)]
        analysis.shortTerm = [TimeValue(time: 0, value: -80), TimeValue(time: 5, value: -30), TimeValue(time: 12, value: -40)]
        analysis.peak = TimeValue(time: 12, value: -0.8)
        let scales = [AnalysisLoudnessScale(values: analysis.momentary), AnalysisLoudnessScale(values: analysis.shortTerm)]
        let renderer = ImageRenderer(content: AnalysisLoudnessPlot(analysis: analysis, scales: scales, time: 6, duration: 12)
            .frame(width: 489, height: AnalysisLoudnessPlot.height(graphHeight: 120)).background(.black))
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try bytes(image)
        func containsColor(near point: CGPoint, matching: (UInt8, UInt8, UInt8) -> Bool) -> Bool {
            for y in max(0, Int(point.y) - 3)...min(image.height - 1, Int(point.y) + 3) {
                for x in max(0, Int(point.x) - 3)...min(image.width - 1, Int(point.x) + 3) {
                    let offset = (y * image.width + x) * 4
                    if matching(pixels[offset], pixels[offset + 1], pixels[offset + 2]) { return true }
                }
            }
            return false
        }
        let top: CGFloat = AnalysisTimelinePlot.axisHeight + 6
        XCTAssertTrue(containsColor(near: CGPoint(x: 200, y: top + scales[0]!.y(-10, height: 120))) { r,g,b in Int(g) > Int(r) + 30 && Int(b) > Int(r) + 30 })
        XCTAssertTrue(containsColor(near: CGPoint(x: 200, y: top + 144 + scales[1]!.y(-30, height: 120))) { r,g,b in Int(g) > Int(r) + 30 && Int(g) > Int(b) + 30 })
        XCTAssertTrue(containsColor(near: CGPoint(x: 480, y: top + 292)) { r,g,b in Int(r) > Int(b) + 50 && g > b }, "APIが返した曲末時刻の点が実画像に残る")
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @MainActor
    func testRenderedRhythmKeepsBlueBarAtItsOwnTimeAndDistinguishesOrdinaryBeats() throws {
        _ = NSApplication.shared
        // The first bar is deliberately between two beats, so snapping it to a beat fails.
        let rhythm = AnalysisTimelineRow(name: "拍・小節", color: .white,
            data: .rhythm(beats: [1, 2, 3], bars: [1.25, 3]))
        let raster = try raster(rows: [rhythm], duration: 5, time: 0)
        let rowTop = Int(AnalysisTimelinePlot.axisHeight + 4)
        func pixels(near column: Int, matching: (UInt8, UInt8, UInt8) -> Bool) -> Int {
            var count = 0
            for y in rowTop..<(rowTop + Int(AnalysisTimelinePlot.graphHeight)) {
                for x in (column - 3)...(column + 3) {
                    let offset = (y * raster.width + x) * 4
                    if matching(raster.bytes[offset], raster.bytes[offset + 1], raster.bytes[offset + 2]) { count += 1 }
                }
            }
            return count
        }
        let blue: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in Int(b) > Int(r) + 40 && Int(b) >= Int(g) - 10 }
        // A 0.7-opacity one-point stroke spreads across two pixels at this scale.
        // 50 catches its coverage while staying above the faint time grid.
        let white: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 50 && abs(Int(r) - Int(g)) < 15 && abs(Int(r) - Int(b)) < 15 }
        let barPixels = pixels(near: 50, matching: blue)
        let beatPixels = pixels(near: 80, matching: white)
        XCTAssertGreaterThan(barPixels, 0, "1.25秒の小節が本来の時刻の青線として残ること")
        XCTAssertGreaterThan(beatPixels, 0, "2秒の通常拍は小節と違う線として残ること")
        XCTAssertGreaterThan(barPixels, beatPixels, "小節は通常拍より太い線で識別できること")
        XCTAssertGreaterThan(pixels(near: 120, matching: blue), 0, "拍と小節が一致しても小節の色を保つこと")
        XCTAssertEqual(pixels(near: 40, matching: blue), 0, "小節を近くの拍へ移動しないこと")
        XCTAssertEqual(pixels(near: 160, matching: white), 0, "拍のない4秒の背景グリッドを通常拍として数えないこと")
    }

    @MainActor
    private func raster(rows: [AnalysisTimelineRow], duration: Double, time: Double)
        throws -> (bytes: [UInt8], width: Int, height: Int) {
        let renderer = ImageRenderer(content: AnalysisTimelinePlot(rows: rows, time: time, duration: duration)
            .frame(width: CGFloat(duration) * 40 + 1, height: AnalysisTimelinePlot.height(rowCount: rows.count))
            .background(.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (bytes, image.width, image.height)
    }

}

@MainActor @Observable
private final class AnalysisPanelTestState {
    var time = 150.0
    var isPlaying = false
}

private struct AnalysisPanelTestView: View {
    var state: AnalysisPanelTestState
    var loudness: Bool
    var body: some View {
        if loudness {
            AnalysisLoudnessView(analysis: analysis, time: state.time, duration: 320, isPlaying: state.isPlaying)
        } else {
        AnalysisPanel(analysis: MusicAnalysis(duration: 320), time: state.time, duration: 320,
                      isPlaying: state.isPlaying)
        }
    }
    private var analysis: MusicAnalysis {
        var result = MusicAnalysis(duration: 320)
        result.momentary = [TimeValue(time: 0, value: -30), TimeValue(time: 320, value: -10)]
        result.shortTerm = [TimeValue(time: 0, value: -25), TimeValue(time: 320, value: -15)]
        result.peak = TimeValue(time: 320, value: -0.8)
        return result
    }
}
