import AppKit
import MetalKit
import Observation
import XCTest
@testable import MusicPrayer

final class RenderSchedulingTests: XCTestCase {
    @MainActor
    func testBackgroundTransparencyChangeWakesPausedVisualizer() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let source = VisualFrameSource()
        var frame = VisualFrame()
        frame.style = .cassette
        source.publish(frame)
        let host = VisualizerHostView(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 256),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let view = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        let renderer = try XCTUnwrap(view.delegate as? MetalRenderer)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (renderer.submittedFrameCount == 0 || !view.isPaused), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(view.isPaused)
        let before = renderer.submittedFrameCount
        host.setBackgroundOpacity(0.18)
        let redrawDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (renderer.submittedFrameCount == before || !view.isPaused), ContinuousClock.now < redrawDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(renderer.submittedFrameCount, before)
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.alphaValue, 1, "The native view must never fade the entire visualization.")
        XCTAssertFalse(try XCTUnwrap(view.layer).isOpaque)
    }

    @MainActor
    func testPausedStoreDoesNotInvalidateUnchangedAnalysisDisplay() async throws {
        let manager = FileManager.default
        let saved = manager.fileExists(atPath: QueuePersistence.file.path) ? try Data(contentsOf: QueuePersistence.file) : nil
        let store = PlayerStore(appleMusicAnalysisDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerAnalysisTests-" + UUID().uuidString))
        defer {
            store.shutdown()
            do {
                if let saved { try saved.write(to: QueuePersistence.file, options: .atomic) }
                else if manager.fileExists(atPath: QueuePersistence.file.path) { try manager.removeItem(at: QueuePersistence.file) }
            } catch { XCTFail("再生状態の復元に失敗しました：\(error.localizedDescription)") }
        }
        let unchanged = expectation(description: "Identical paused analysis must not trigger UI layout")
        unchanged.isInverted = true
        withObservationTracking { _ = store.moment } onChange: { unchanged.fulfill() }
        await fulfillment(of: [unchanged], timeout: 0.15)
    }

    func testStaticInputsSuppressSmoothingTailButAccumulateChanges() {
        var frame = VisualFrame()
        let size = CGSize(width: 640, height: 360)
        let presented = RenderInputs(frame: frame, size: size)
        frame.rms = 0.000005
        frame.spectrum[63] = 0.000005
        XCTAssertTrue(RenderInputs(frame: frame, size: size).matches(presented))
        frame.spectrum[63] = 0.00002
        XCTAssertFalse(RenderInputs(frame: frame, size: size).matches(presented))
    }

    func testSeekTrackCameraAnalysisAndResizeRequireDrawing() {
        let frame = VisualFrame()
        let size = CGSize(width: 640, height: 360)
        let presented = RenderInputs(frame: frame, size: size)
        let changes: [(inout VisualFrame) -> Void] = [
            { $0.time = 0.000001 },
            { $0.trackID = UUID() },
            { $0.camera.eye.x += 0.1 },
            { $0.hasAnalysis = 1 },
            { $0.presence = 0.5 },
            { $0.sectionWater = 0.8 },
            { $0.spectrum[0] = 0.1 }
        ]
        for change in changes {
            var updated = frame
            change(&updated)
            XCTAssertFalse(RenderInputs(frame: updated, size: size).matches(presented))
        }
        XCTAssertFalse(RenderInputs(frame: frame, size: CGSize(width: 641, height: 360)).matches(presented))
    }

    func testWaterWaitsForGPUAndIgnoresOlderCompletion() {
        let activity = WaterRenderActivity()
        XCTAssertEqual(activity.state, .active)
        activity.submitted()
        activity.submitted()
        activity.completed(frame: 1, maximumHeight: 0)
        XCTAssertEqual(activity.state, .pending)
        activity.completed(frame: 0, maximumHeight: 1)
        XCTAssertEqual(activity.state, .idle)
        activity.submitted()
        activity.completed(frame: 2, maximumHeight: 0.1)
        XCTAssertEqual(activity.state, .active)
        activity.submitted()
        activity.completed(frame: 3, maximumHeight: .infinity)
        XCTAssertEqual(activity.state, .active)
    }

    @MainActor
    func testStoppedCityStoreSettlesAnalysisTailAndWakesForAnalysisAndPreviewSeek() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let manager = FileManager.default
        let saved = manager.fileExists(atPath: QueuePersistence.file.path) ? try Data(contentsOf: QueuePersistence.file) : nil
        let store = PlayerStore(appleMusicAnalysisDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerAnalysisTests-" + UUID().uuidString))
        defer {
            store.shutdown()
            do {
                if let saved { try saved.write(to: QueuePersistence.file, options: .atomic) }
                else if manager.fileExists(atPath: QueuePersistence.file.path) { try manager.removeItem(at: QueuePersistence.file) }
            } catch { XCTFail("再生状態の復元に失敗しました：\(error.localizedDescription)") }
        }
        let analysis = MusicAnalysis(duration: 12, beats: [0, 1, 2, 3, 4, 5],
                                     sections: [TimeSpan(start: 0, duration: 12)],
                                     vocal: [TimeValue(time: 0, value: 0.8), TimeValue(time: 12, value: 0.8)])
        store.visualizerStyle = .cassette
        store.previewTime = 1.25
        store.analysis = analysis
        try await Task.sleep(for: .milliseconds(120))
        let unsettled = store.visualSource.snapshot()
        XCTAssertGreaterThan(unsettled.vocal, 0)
        XCTAssertLessThan(unsettled.vocal, 0.8, "The setup must include an unfinished smoothing tail.")

        let host = VisualizerHostView(source: store.visualSource)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 256),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let view = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        let renderer = try XCTUnwrap(view.delegate as? MetalRenderer)
        var error: String?
        renderer.onError = { error = $0 }
        func waitForDrawAndSleep(after count: Int, time: Float, vocal: Float) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while (renderer.submittedFrameCount == count || !view.isPaused ||
                   store.visualSource.snapshot().time != time || abs(store.visualSource.snapshot().vocal - vocal) > 0.000005),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(renderer.submittedFrameCount, count)
            XCTAssertTrue(view.isPaused)
            XCTAssertEqual(store.visualSource.snapshot().time, time)
            XCTAssertEqual(store.visualSource.snapshot().vocal, vocal, accuracy: 0.000005)
            XCTAssertNil(error)
        }

        let beforeCity = renderer.submittedFrameCount
        store.visualizerStyle = .spectrumCity
        try await waitForDrawAndSleep(after: beforeCity, time: 1.25, vocal: 0.8)
        let paused = renderer.submittedFrameCount
        let presented = RenderInputs(frame: store.visualSource.snapshot(), size: view.drawableSize)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(renderer.submittedFrameCount, paused, "After the existing smoothing tail settles, the real store's repeated ticks must submit no GPU work.")
        XCTAssertTrue(RenderInputs(frame: store.visualSource.snapshot(), size: view.drawableSize).matches(presented))

        store.analysis = nil
        try await waitForDrawAndSleep(after: paused, time: 1.25, vocal: 0)
        let beforeAnalysis = renderer.submittedFrameCount
        store.analysis = analysis
        try await waitForDrawAndSleep(after: beforeAnalysis, time: 1.25, vocal: 0.8)
        let analyzed = store.visualSource.snapshot()
        XCTAssertEqual(analyzed.hasAnalysis, 1)
        XCTAssertEqual(analyzed.beatPhase, 0.25)

        let beforeSeek = renderer.submittedFrameCount
        store.previewTime = 4.5
        try await waitForDrawAndSleep(after: beforeSeek, time: 4.5, vocal: 0.8)
        XCTAssertEqual(store.visualSource.snapshot().beatPhase, 0.5)
        XCTAssertEqual(store.visualSource.snapshot().sectionProgress, 4.5 / 12)
        let beforeResize = renderer.submittedFrameCount
        view.drawableSize = CGSize(width: 512, height: 320)
        try await waitForDrawAndSleep(after: beforeResize, time: 4.5, vocal: 0.8)
        let beforeStop = renderer.submittedFrameCount
        store.stop()
        try await waitForDrawAndSleep(after: beforeStop, time: 0, vocal: 0.8)
        let stopped = renderer.submittedFrameCount
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(renderer.submittedFrameCount, stopped)
        for style in [VisualizerStyle.cassette, .ribbons, .spectrumCity] {
            let beforeSwitch = renderer.submittedFrameCount
            store.visualizerStyle = style
            try await waitForDrawAndSleep(after: beforeSwitch, time: 0, vocal: 0.8)
            XCTAssertEqual(view.toolTip != nil, style == .ribbons)
        }
    }

    @MainActor
    func testPausedHostSwitchesCassetteAndBackWithoutWaterKeepingItAwake() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let source = VisualFrameSource()
        let host = VisualizerHostView(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 256),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let view = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        let renderer = try XCTUnwrap(view.delegate as? MetalRenderer)
        var frame = VisualFrame()
        frame.style = .cassette
        frame.title = "静止中の切替"
        frame.duration = 180
        XCTAssertTrue(source.waterInteractions.enqueue(screenUV: SIMD2(0.5, 0.9)))
        source.publish(frame)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (renderer.submittedFrameCount == 0 || !view.isPaused), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(renderer.submittedFrameCount, 0)
        XCTAssertTrue(view.isPaused)
        XCTAssertFalse(source.waterInteractions.hasPendingPulses)
        XCTAssertNil(view.toolTip)
        let cassetteFrames = renderer.submittedFrameCount
        frame.style = .ribbons
        source.publish(frame)
        let ribbonDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (renderer.submittedFrameCount == cassetteFrames || !view.isPaused), ContinuousClock.now < ribbonDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(renderer.submittedFrameCount, cassetteFrames)
        XCTAssertTrue(view.isPaused)
        XCTAssertNotNil(view.toolTip)
    }

    @MainActor
    func testCitySleepsWakesForSeekAndResizeAndSwitchesToExistingStyles() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let source = VisualFrameSource()
        let host = VisualizerHostView(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 256),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let view = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        let renderer = try XCTUnwrap(view.delegate as? MetalRenderer)
        var error: String?
        renderer.onError = { error = $0 }
        var frame = VisualFrame()
        frame.style = .spectrumCity
        frame.spectrum = Array(repeating: 0.5, count: 64)
        XCTAssertTrue(source.waterInteractions.enqueue(screenUV: SIMD2(0.5, 0.9)))

        func waitForDrawAndSleep(after count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while (renderer.submittedFrameCount == count || !view.isPaused), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(renderer.submittedFrameCount, count)
            XCTAssertTrue(view.isPaused)
            XCTAssertNil(error)
        }

        let before = renderer.submittedFrameCount
        source.publish(frame)
        try await waitForDrawAndSleep(after: before)
        XCTAssertFalse(source.waterInteractions.hasPendingPulses)
        XCTAssertNil(view.toolTip)
        let paused = renderer.submittedFrameCount
        source.publish(frame)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(renderer.submittedFrameCount, paused, "The paused city must submit no unchanged GPU frames.")

        frame.time = 24
        source.publish(frame)
        try await waitForDrawAndSleep(after: paused)
        let beforeResize = renderer.submittedFrameCount
        view.drawableSize = CGSize(width: 512, height: 320)
        try await waitForDrawAndSleep(after: beforeResize)

        for style in [VisualizerStyle.cassette, .ribbons, .spectrumCity] {
            let previous = renderer.submittedFrameCount
            frame.style = style
            source.publish(frame)
            try await waitForDrawAndSleep(after: previous)
            XCTAssertEqual(view.toolTip != nil, style == .ribbons)
        }
    }

    @MainActor
    func testHostSleepsAndAutomaticallyWakesForPublishedFramesAndResize() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let source = VisualFrameSource()
        let host = VisualizerHostView(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 192, height: 128),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let view = try XCTUnwrap(host.subviews.compactMap { $0 as? MTKView }.first)
        let renderer = try XCTUnwrap(view.delegate as? MetalRenderer)
        XCTAssertEqual(view.preferredFramesPerSecond, 60)
        var frame = VisualFrame()
        let before = renderer.submittedFrameCount
        source.publish(frame)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (renderer.submittedFrameCount == before || !view.isPaused), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(renderer.submittedFrameCount, before)
        XCTAssertTrue(view.isPaused, "The actual display loop must sleep when inputs and water are static.")
        let paused = renderer.submittedFrameCount
        source.publish(frame)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(renderer.submittedFrameCount, paused)
        let beforeSeek = renderer.submittedFrameCount
        frame.time = 2
        source.publish(frame)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(renderer.submittedFrameCount, beforeSeek)
        XCTAssertTrue(view.isPaused)
        let beforeResize = renderer.submittedFrameCount
        view.drawableSize = CGSize(width: 256, height: 128)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(renderer.submittedFrameCount, beforeResize)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(source.waterInteractions.enqueue(screenUV: SIMD2(0.5, 0.9)))
        source.publish(frame)
        let beforeClick = renderer.submittedFrameCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(renderer.submittedFrameCount, beforeClick)
        XCTAssertFalse(view.isPaused, "The sleeping display loop must wake and keep propagating a click's wave.")
    }

    @MainActor
    func testRealRendererStopsSubmittingStaticFramesAndWakesForChanges() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        _ = NSApplication.shared
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 192, height: 128), device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let source = VisualFrameSource()
        let renderer = try MetalRenderer(device: device, source: source)
        view.delegate = renderer
        var error: String?
        renderer.onError = { error = $0 }
        var frame = VisualFrame()
        source.publish(frame)
        let before = renderer.submittedFrameCount
        renderer.draw(in: view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(error)
        XCTAssertGreaterThan(renderer.submittedFrameCount, before, "The changed scene must acquire a real drawable.")
        let paused = renderer.submittedFrameCount
        for _ in 0..<60 { renderer.draw(in: view) }
        XCTAssertEqual(renderer.submittedFrameCount, paused, "Static frames must submit no GPU work.")
        frame.time += 1
        source.publish(frame)
        renderer.draw(in: view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(renderer.submittedFrameCount, paused, "Seeking must redraw.")
        let beforeClick = renderer.submittedFrameCount
        XCTAssertTrue(source.waterInteractions.enqueue(screenUV: SIMD2(0.5, 0.9)))
        renderer.draw(in: view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(renderer.submittedFrameCount, beforeClick, "A click must wake the paused scene.")
        let afterClick = renderer.submittedFrameCount
        renderer.draw(in: view)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(renderer.submittedFrameCount, afterClick, "Existing waves must continue after the pulse was consumed.")
        view.drawableSize = CGSize(width: 256, height: 128)
        let beforeResize = renderer.submittedFrameCount
        renderer.draw(in: view)
        XCTAssertGreaterThan(renderer.submittedFrameCount, beforeResize)
        XCTAssertNil(error)
    }
}
