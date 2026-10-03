import AppKit
import SwiftUI
import XCTest
@testable import MusicPrayer

final class AnalysisActivityTests: XCTestCase {
    func testAllActivityRowsKeepOriginalValuesAndEverySampleIncludingBriefSpike() throws {
        var analysis = MusicAnalysis(duration: 320.8)
        analysis.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 320.8), value: 315)]
        var values = (0..<6416).map { TimeValue(time: Double($0) * 0.05, value: 0) }
        values[1977].value = 1
        analysis.vocal = values
        analysis.drums = [TimeValue(time: 2, value: 0.143), TimeValue(time: 4, value: 0.659)]
        analysis.bass = [TimeValue(time: 1, value: 0.326), TimeValue(time: 5, value: 0.752)]
        analysis.other = [TimeValue(time: 3, value: 0.419), TimeValue(time: 6, value: 0.987)]
        let rows = AnalysisActivityRow.rows(for: analysis)
        XCTAssertEqual(rows.map(\.name), ["活動量", "歌声", "ドラム", "低音", "その他"])
        guard case .pace(let pace) = rows[0].data else { return XCTFail("活動量の区間が必要") }
        XCTAssertEqual(pace.map(\.value), analysis.pace.map(\.value))
        XCTAssertEqual(pace.first?.range.duration, 320.8)
        for (row, expected) in zip(rows.dropFirst(), [analysis.vocal, analysis.drums, analysis.bass, analysis.other]) {
            guard case .values(let original) = row.data else { return XCTFail("楽器の実測系列が必要") }
            XCTAssertEqual(original, expected, "強度・時刻を変えずに表示へ渡すこと")
            let vertices = points(row.path(height: 80)).vertices
            XCTAssertEqual(vertices.count, expected.count, "間引かず、全測定点を描くこと")
            for (vertex, sample) in zip(vertices, expected) {
                XCTAssertEqual(vertex.x, CGFloat(sample.time) * 40, accuracy: 0.00001)
                XCTAssertEqual(vertex.y, CGFloat(1 - sample.value) * 80, accuracy: 0.00001)
            }
        }
        let vertices = points(rows[1].path(height: 80)).vertices
        XCTAssertEqual(vertices[1977].x, 3954, accuracy: 0.00001)
        XCTAssertEqual(vertices[1977].y, 0)
        XCTAssertEqual(vertices[1976].y, 80)
        XCTAssertEqual(vertices[1978].y, 80)
        XCTAssertEqual(vertices.last?.x, 12830)
    }

    func testPaceFitsVisibleObservationsAndKeepsRealStepsAndGaps() throws {
        let spans = [PaceSpan(range: TimeSpan(start: 0, duration: 2), value: 320),
                     PaceSpan(range: TimeSpan(start: 2, duration: 2), value: 421),
                     PaceSpan(range: TimeSpan(start: 8, duration: 2), value: 360)]
        let row = AnalysisActivityRow(name: "活動量", color: .cyan, data: .pace(spans))
        let scale = try XCTUnwrap(row.scale)
        XCTAssertGreaterThan(scale.range.lowerBound, 0, "活動量の尺度に0を強制しないこと")
        XCTAssertLessThanOrEqual(scale.range.lowerBound, 320)
        XCTAssertGreaterThanOrEqual(scale.range.upperBound, 421)
        XCTAssertLessThanOrEqual(scale.range.upperBound, 421 + scale.tickStep,
                                 "実測最大値から一目盛り以内に収めること")
        XCTAssertGreaterThan(scale.tickStep, 0)
        XCTAssertEqual(scale.ticks.first, scale.range.upperBound)
        XCTAssertEqual(scale.ticks.last, scale.range.lowerBound)
        XCTAssertNotEqual(scale.y(320, height: 80), scale.y(421, height: 80),
                          "200を超える別々の観測値を同じ高さへ潰さないこと")
        let path = points(row.path(height: 80))
        XCTAssertEqual(path.moves, 2, "欠測をまたいで線をつながないこと")
        XCTAssertEqual(path.vertices.map(\.x), [0, 80, 80, 160, 320, 400],
                       "隣接区間は共通時刻に縦の段差を描き、離れた区間は別の線にすること")
        XCTAssertEqual(path.vertices[0].y, scale.y(320, height: 80), accuracy: 0.00001)
        XCTAssertEqual(path.vertices[2].y, scale.y(421, height: 80), accuracy: 0.00001)
        XCTAssertEqual(path.vertices[4].y, scale.y(360, height: 80), accuracy: 0.00001)
        XCTAssertEqual(row.currentReading(at: 1).value, "320.00回/分")
        XCTAssertEqual(row.currentReading(at: 1).time, "0:00.0〜0:02.0")
        XCTAssertEqual(row.currentReading(at: 2).value, "421.00回/分")
        XCTAssertEqual(row.currentReading(at: 4).value, "未取得")
        XCTAssertNil(row.currentReading(at: 5).time)
        XCTAssertEqual(row.currentReading(at: 8).value, "360.00回/分")
        let missing = AnalysisActivityRow(name: "活動量", color: .cyan, data: .pace([]))
        XCTAssertNil(missing.scale)
        XCTAssertTrue(missing.path(height: 80).isEmpty)
        XCTAssertEqual(missing.currentReading(at: 1).value, "未取得")

        let observed = AnalysisActivityRow(name: "活動量", color: .cyan, data: .pace([
            PaceSpan(range: TimeSpan(start: 0, duration: 2), value: 5.87),
            PaceSpan(range: TimeSpan(start: 2, duration: 2), value: 24.24)]))
        let observedScale = try XCTUnwrap(observed.scale)
        XCTAssertLessThanOrEqual(observedScale.range.upperBound, 50,
                                 "実測5.87〜24.24を上限200の尺度へ押し込めないこと")
        XCTAssertGreaterThanOrEqual(observedScale.y(5.87, height: 80) - observedScale.y(24.24, height: 80), 25,
                                    "実曲の活動量の変化が80ptのグラフで読めること")

        let visibleSpans = [PaceSpan(range: TimeSpan(start: 0, duration: 40), value: 9.38),
                            PaceSpan(range: TimeSpan(start: 57, duration: 13), value: 36.28),
                            PaceSpan(range: TimeSpan(start: 70, duration: 30), value: 36.99)]
        let visibleScale = try XCTUnwrap(AnalysisActivityScale.pace(visibleSpans, window: 59...84))
        XCTAssertGreaterThan(visibleScale.range.lowerBound, 30,
                             "画面外の9.38で表示中の尺度を広げないこと")
        XCTAssertLessThanOrEqual(visibleScale.range.lowerBound, 36.28)
        XCTAssertGreaterThanOrEqual(visibleScale.range.upperBound, 36.99)
        XCTAssertGreaterThanOrEqual(visibleScale.y(36.28, height: 80) - visibleScale.y(36.99, height: 80), 25,
                                    "表示範囲59〜84秒の36.28→36.99を80ptのグラフで読めること")
        XCTAssertNil(AnalysisActivityScale.pace(visibleSpans, window: 45...50),
                     "空の表示範囲へ画面外の活動量を持ち込まないこと")

        let constantSpans = [PaceSpan(range: TimeSpan(start: 60, duration: 10), value: 36.28)]
        let constantScale = try XCTUnwrap(AnalysisActivityScale.pace(constantSpans, window: 60...70))
        XCTAssertTrue(constantScale.range.lowerBound.isFinite && constantScale.range.upperBound.isFinite)
        XCTAssertLessThan(constantScale.range.lowerBound, 36.28)
        XCTAssertGreaterThan(constantScale.range.upperBound, 36.28)
        XCTAssertTrue(constantScale.y(36.28, height: 80).isFinite)
        let constant = AnalysisActivityRow(name: "活動量", color: .cyan, data: .pace(constantSpans))
        let constantPoints = points(constant.path(height: 80))
        XCTAssertEqual(constantPoints.moves, 1)
        XCTAssertEqual(constantPoints.vertices.count, 2)
        XCTAssertEqual(constantPoints.vertices[0].y, constantPoints.vertices[1].y, accuracy: 0.00001,
                       "一定36.28は有限の高さの水平線として残すこと")
    }

    func testStrengthUsesFixedUnitScaleAndLatestRealObservationInsteadOfInterpolation() throws {
        let samples = [TimeValue(time: 2, value: 0.2), TimeValue(time: 4, value: 0.4)]
        let row = AnalysisActivityRow(name: "歌声", color: .pink, data: .values(samples))
        let scale = try XCTUnwrap(row.scale)
        XCTAssertEqual(scale.range, 0...1)
        XCTAssertEqual(scale.y(1, height: 80), 0)
        XCTAssertEqual(scale.y(0, height: 80), 80)
        XCTAssertEqual(scale.ticks.first, 1)
        XCTAssertEqual(scale.ticks.last, 0)
        XCTAssertEqual(scale.label(0.5), "0.5")
        XCTAssertEqual(row.currentReading(at: 3.7).value, "0.200 / 1")
        XCTAssertEqual(row.currentReading(at: 3.7).time, "0:02.0",
                       "補間時刻ではなく、その値を観測した時刻を示すこと")
        XCTAssertEqual(row.currentReading(at: 4).value, "0.400 / 1")
        XCTAssertEqual(row.currentReading(at: 4).time, "0:04.0")
        XCTAssertEqual(row.currentReading(at: 1).value, "未取得")
        XCTAssertNil(row.currentReading(at: 1).time)
        let missing = AnalysisActivityRow(name: "歌声", color: .pink, data: .values([]))
        XCTAssertNil(missing.scale)
        XCTAssertTrue(missing.path(height: 80).isEmpty)
        XCTAssertEqual(missing.currentReading(at: 3).value, "未取得")
    }

    @MainActor
    func testRenderedActivityRetainsBriefSpikeAndDoesNotFillPaceGaps() throws {
        _ = NSApplication.shared
        var values = (0..<4000).map { TimeValue(time: Double($0) * 0.05, value: 0) }
        values[1977].value = 1
        let signal = AnalysisActivityRow(name: "歌声", color: .cyan, data: .values(values))
        let spike = try raster(rows: [signal], duration: 200, time: 0)
        let baseline = cyanPixels(spike, near: 3930)
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertGreaterThan(cyanPixels(spike, near: 3954), baseline * 2,
                             "短い観測の変化も80ptのグラフに残ること")
        let pace = AnalysisActivityRow(name: "活動量", color: .cyan, data: .pace([
            PaceSpan(range: TimeSpan(start: 0, duration: 2), value: 320),
            PaceSpan(range: TimeSpan(start: 8, duration: 2), value: 421)]))
        let gaps = try raster(rows: [pace], duration: 12, time: 5)
        XCTAssertGreaterThan(cyanPixels(gaps, near: 40), 0)
        XCTAssertEqual(cyanPixels(gaps, near: 200), 0, "未取得区間へ活動量の線を足さないこと")

        let visible = AnalysisActivityRow(name: "活動量", color: .cyan, data: .pace([
            PaceSpan(range: TimeSpan(start: 0, duration: 40), value: 9.38),
            PaceSpan(range: TimeSpan(start: 57, duration: 13), value: 36.28),
            PaceSpan(range: TimeSpan(start: 70, duration: 30), value: 36.99)]))
        let focused = try raster(rows: [visible], duration: 100, time: 0, scaleWindow: 59...84)
        let before = try XCTUnwrap(cyanTop(focused, near: 2440), "61秒の36.28が画像に残ること")
        let after = try XCTUnwrap(cyanTop(focused, near: 3240), "81秒の36.99が画像に残ること")
        XCTAssertGreaterThanOrEqual(before - after, 25,
                                    "画面外9.38を含む曲でも、表示中の36.28→36.99が実画像で読めること")
    }

    @MainActor
    func testNativeActivityScrollFollowsPlaybackSeekAndResizeAndKeepsPausedManualPosition() async throws {
        _ = NSApplication.shared
        let state = AnalysisActivityTestState()
        let hosting = NSHostingView(rootView: AnalysisActivityTestView(state: state))
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
        let scroll = try XCTUnwrap(horizontal(in: hosting), "実際の活動量の横スクロールビューが必要")
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
        window.setContentSize(CGSize(width: 900, height: 300))
        try await settle()
        XCTAssertLessThan(scroll.contentView.bounds.width, width)
        XCTAssertEqual(scroll.contentView.bounds.minX + scroll.contentView.bounds.width / 2, 800, accuracy: 2)
        scroll.contentView.scroll(to: CGPoint(x: 1000, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        state.fingerprint = "next-track"
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minX + scroll.contentView.bounds.width / 2, 800, accuracy: 2)
        state.time = 319
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.maxX, 12801, accuracy: 2)
    }

    private func points(_ path: Path) -> (vertices: [CGPoint], moves: Int) {
        var vertices: [CGPoint] = []
        var moves = 0
        path.forEach { element in
            switch element {
            case .move(let point): vertices.append(point); moves += 1
            case .line(let point): vertices.append(point)
            default: XCTFail("観測値は直線の頂点として描くこと")
            }
        }
        return (vertices, moves)
    }

    @MainActor
    private func raster(rows: [AnalysisActivityRow], duration: Double, time: Double,
                        scaleWindow: ClosedRange<Double>? = nil)
        throws -> (bytes: [UInt8], width: Int, height: Int) {
        let renderer = ImageRenderer(content: AnalysisActivityPlot(rows: rows, time: time, duration: duration,
                                                                   graphHeight: 80, scaleWindow: scaleWindow)
            .frame(width: CGFloat(duration) * 40 + 1,
                   height: AnalysisActivityPlot.height(graphHeight: 80, rowCount: rows.count)).background(.black))
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

    private func cyanPixels(_ raster: (bytes: [UInt8], width: Int, height: Int), near column: Int) -> Int {
        var count = 0
        for y in 0..<raster.height {
            for x in max(0, column - 3)...min(raster.width - 1, column + 3) {
                let offset = (y * raster.width + x) * 4
                if Int(raster.bytes[offset + 1]) > Int(raster.bytes[offset]) + 40 &&
                   Int(raster.bytes[offset + 2]) > Int(raster.bytes[offset]) + 40 { count += 1 }
            }
        }
        return count
    }

    private func cyanTop(_ raster: (bytes: [UInt8], width: Int, height: Int), near column: Int) -> Int? {
        for y in 0..<raster.height {
            for x in max(0, column - 3)...min(raster.width - 1, column + 3) {
                let offset = (y * raster.width + x) * 4
                if Int(raster.bytes[offset + 1]) > Int(raster.bytes[offset]) + 40 &&
                   Int(raster.bytes[offset + 2]) > Int(raster.bytes[offset]) + 40 { return y }
            }
        }
        return nil
    }
}

@MainActor @Observable
private final class AnalysisActivityTestState {
    var time = 150.0
    var isPlaying = false
    var fingerprint = "first-track"
}

private struct AnalysisActivityTestView: View {
    var state: AnalysisActivityTestState
    var body: some View {
        AnalysisActivityView(analysis: analysis, time: state.time, duration: 320, isPlaying: state.isPlaying)
    }
    private var analysis: MusicAnalysis {
        var result = MusicAnalysis(duration: 320)
        result.fingerprint = state.fingerprint
        result.pace = [PaceSpan(range: TimeSpan(start: 0, duration: 320), value: 320)]
        let values = [TimeValue(time: 0, value: 0.1), TimeValue(time: 320, value: 0.9)]
        result.vocal = values; result.drums = values; result.bass = values; result.other = values
        return result
    }
}
