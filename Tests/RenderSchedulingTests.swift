import AppKit
import MetalKit
import Observation
import XCTest
@testable import MusicPrayer

final class RenderSchedulingTests: XCTestCase {
    @MainActor
    func testPausedStoreDoesNotInvalidateUnchangedAnalysisDisplay() async throws {
        let manager = FileManager.default
        let saved = manager.fileExists(atPath: QueuePersistence.file.path) ? try Data(contentsOf: QueuePersistence.file) : nil
        let store = PlayerStore()
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
