import AppKit
import AVFoundation
import XCTest
@testable import MusicPrayer

final class VisualizerSelectionTests: XCTestCase {
    @MainActor
    func testChangingVisualizerKeepsAudioClockTrackAndMuteSetting() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MusicPrayerVisualizer-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let queueFile = QueuePersistence.file
        let saved = manager.fileExists(atPath: queueFile.path) ? try Data(contentsOf: queueFile) : nil
        let store = PlayerStore()
        defer {
            store.shutdown()
            do {
                if let saved { try saved.write(to: queueFile, options: .atomic) }
                else if manager.fileExists(atPath: queueFile.path) { try manager.removeItem(at: queueFile) }
            } catch { XCTFail("再生状態の復元に失敗しました：\(error.localizedDescription)") }
            try? manager.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("clock.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][index] = 0.2 * sin(Float(index) * 2 * .pi * 220 / 48_000)
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let track = Track(url: url)
        store.tracks = [track]
        store.volume = 0.41
        store.isMuted = true
        // Load the real audio node directly; this verification needs no temporary Music Understanding cache.
        try store.engine.load(url: url)
        try store.engine.seek(to: 1)
        try store.engine.play()
        var lastTime = store.engine.currentTime
        for style in [VisualizerStyle.ink, .ribbons, .ink] {
            store.visualizerStyle = style
            try await Task.sleep(for: .milliseconds(120))
            let frame = store.visualSource.snapshot()
            XCTAssertEqual(frame.visualizerStyle, style)
            XCTAssertEqual(frame.trackID, track.id)
            XCTAssertTrue(store.engine.isPlaying)
            XCTAssertGreaterThan(store.engine.currentTime, lastTime)
            XCTAssertEqual(Double(frame.time), store.engine.currentTime, accuracy: 0.08)
            XCTAssertEqual(store.currentTrack?.id, track.id)
            XCTAssertEqual(store.volume, 0.41, accuracy: 0.001)
            XCTAssertTrue(store.isMuted)
            XCTAssertEqual(store.engine.volume, 0)
            lastTime = store.engine.currentTime
        }
        store.previewTime = 2.8
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(store.visualSource.snapshot().time, 2.8, accuracy: 0.001)
        XCTAssertTrue(store.engine.isPlaying)
    }
}
