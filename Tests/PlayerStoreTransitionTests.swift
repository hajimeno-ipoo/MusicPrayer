import AVFoundation
import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import MusicPrayer

final class PlayerStoreTransitionTests: XCTestCase {
    @MainActor
    func testVisualizerUpdatesWhileRunLoopTracksControls() throws {
        _ = NSApplication.shared
        let backup = try FileBackup(QueuePersistence.file)
        let store = PlayerStore()
        defer {
            store.shutdown()
            do { try backup.restore() }
            catch { XCTFail("テスト前の保存内容を戻せませんでした: \(error.localizedDescription)") }
        }
        // Keep the tracking loop active just as a native slider or menu does.
        let tracking = Timer(timeInterval: 0.01, repeats: true) { _ in }
        RunLoop.main.add(tracking, forMode: .eventTracking)
        defer { tracking.invalidate() }
        store.volume = 0.42
        store.toggleMute()
        XCTAssertTrue(store.isMuted)
        XCTAssertEqual(store.volume, 0.42, accuracy: 0.001, "ミュートは設定音量を消さないこと")
        XCTAssertEqual(store.engine.volume, 0)
        for position in [10.0, 20.0] {
            store.previewTime = position
            let deadline = Date().addingTimeInterval(0.1)
            while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
            XCTAssertEqual(store.visualSource.snapshot().time, Float(position), accuracy: 0.001,
                           "メニューやスライダーの操作中にも新しい映像frameを公開すること")
        }
        store.volume = 0.25
        XCTAssertEqual(store.engine.volume, 0, "ミュート中に設定音量を動かしても消音を維持すること")
        store.toggleMute()
        XCTAssertFalse(store.isMuted)
        XCTAssertEqual(store.engine.volume, 0.25, accuracy: 0.001, "解除後は設定した音量に戻ること")
    }

    @MainActor
    func testManualSelectionStartsNewAudioWhilePreviousVisualStillFades() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MusicPrayerStoreTransition-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let first = try writeTone(to: directory.appendingPathComponent("first.wav"), sampleRate: 44_100, channels: 1)
        let second = try writeTone(to: directory.appendingPathComponent("second.wav"), sampleRate: 48_000, channels: 2)
        let cacheDirectory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/Analysis")
        let cacheFiles = try [first, second].map { url in
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            return cacheDirectory.appendingPathComponent("\(hash).json")
        }
        // Run with the app closed: normal select/shutdown persist to the real queue location.
        // Preserve exact prior bytes without changing production persistence for the test.
        let backups = try ([QueuePersistence.file] + cacheFiles).map(FileBackup.init)
        let store = PlayerStore()
        defer {
            store.shutdown()
            for backup in backups {
                do { try backup.restore() }
                catch { XCTFail("テスト前の保存内容を戻せませんでした: \(error.localizedDescription)") }
            }
        }
        store.volume = 0
        store.tracks = [Track(url: first), Track(url: second)]
        store.select(0)
        let clock = ContinuousClock()
        let firstStart = clock.now
        while store.engine.currentTime < 0.6, firstStart.duration(to: clock.now).secondsValue < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.playbackError)
        XCTAssertTrue(store.engine.isPlaying)
        let previousVisual = store.visualSource.snapshot()
        XCTAssertGreaterThan(previousVisual.time, 0.45, "旧曲の実際に公開された映像frameを保持すること")
        XCTAssertGreaterThan(previousVisual.presence, 0.95)

        let selectedAt = clock.now
        store.select(1)
        let selectionSeconds = selectedAt.duration(to: clock.now).secondsValue
        XCTAssertEqual(store.currentTrack?.url, second)
        XCTAssertNil(store.playbackError)
        XCTAssertTrue(store.engine.isPlaying, "映像フェードを待たずに新曲のnodeを再生すること")
        XCTAssertLessThan(selectionSeconds, TrackVisualTransition.halfDuration, "手動切替に映像用の待機時間を入れないこと")
        while store.engine.currentTime < 0.10, selectedAt.duration(to: clock.now).secondsValue < 0.30 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let newAudioTime = store.engine.currentTime
        let fadingVisual = store.visualSource.snapshot()
        XCTAssertGreaterThan(newAudioTime, 0.09)
        XCTAssertLessThan(selectedAt.duration(to: clock.now).secondsValue, TrackVisualTransition.halfDuration)
        XCTAssertGreaterThan(fadingVisual.time, Float(newAudioTime + 0.30), "旧曲の映像を残す間にも新曲の音声時計が進むこと")
        XCTAssertGreaterThan(fadingVisual.presence, 0)
        XCTAssertLessThan(fadingVisual.presence, previousVisual.presence, "旧曲が即座に置き換わらずフェードすること")

        while selectedAt.duration(to: clock.now).secondsValue < 0.9 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let newVisual = store.visualSource.snapshot()
        XCTAssertEqual(Double(newVisual.time), store.engine.currentTime, accuracy: 0.06)
        XCTAssertGreaterThan(newVisual.presence, 0.99, "0.8秒の映像遷移後は新曲を通常表示すること")
        XCTAssertEqual(store.currentTrack?.url, second)
        XCTAssertTrue(store.engine.isPlaying)
        // The outcome of Music Understanding is deliberately not an acceptance condition.
        store.shutdown()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func writeTone(to url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let frequency = Double.random(in: 420...470)
        for frame in 0..<Int(frames) {
            let value = Float(0.2 * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) { buffer.floatChannelData![channel][frame] = value }
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
        return url
    }
}

private struct FileBackup {
    let url: URL
    let bytes: Data?

    init(_ url: URL) throws {
        self.url = url
        bytes = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    func restore() throws {
        if let bytes { try bytes.write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

private extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
