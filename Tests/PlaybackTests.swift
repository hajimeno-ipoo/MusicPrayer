import XCTest
import AVFoundation
@testable import MusicPrayer

final class PlaybackTests: XCTestCase {
    func testFFTMeasuresKnownToneAndTimestampsSnapshot() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        buffer.frameLength = 4_096
        for i in 0..<4_096 {
            let sample = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / 48_000))
            for channel in 0..<2 { buffer.floatChannelData![channel][i] = sample }
        }
        let analyzer = AudioFeatureAnalyzer(sampleRate: 48_000)
        let stamp = AVAudioTime.hostTime(forSeconds: 3)
        analyzer.process(buffer, at: AVAudioTime(hostTime: stamp))
        let features = analyzer.snapshot()
        XCTAssertEqual(features.rms, 0.35355, accuracy: 0.002)
        XCTAssertEqual(features.peak, 0.5, accuracy: 0.002)
        XCTAssertEqual(features.spectralCentroid, 1_000, accuracy: 10)
        XCTAssertGreaterThan(features.mid, features.bass * 20)
        XCTAssertGreaterThan(features.mid, features.treble * 20)
        XCTAssertEqual(features.spectrum.count, 64)
        XCTAssertGreaterThan(features.hostTime, stamp)
        XCTAssertEqual(analyzer.snapshot(atOrBefore: features.hostTime).hostTime, features.hostTime)
        XCTAssertEqual(analyzer.snapshot(atOrBefore: stamp).hostTime, 0)
        analyzer.reset()
        XCTAssertEqual(analyzer.snapshot().rms, 0)
        XCTAssertEqual(analyzer.snapshot(atOrBefore: features.hostTime).rms, 0)
    }

    func testStreamResamplesMonoAndSeeksWithoutReadingWholeTrack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerPlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.wav")
        let native = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 44_100)!
        samples.frameLength = 44_100
        for index in 0..<44_100 { samples.floatChannelData![0][index] = Float(0.5 * sin(2 * Double.pi * 440 * Double(index) / 44_100)) }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: native.settings)
            try writer.write(from: samples)
        }
        let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let stream = try AudioFileStream(url: url, format: output)
        let first = try stream.read(maxChunks: 1)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].frameLength, AudioFileStream.chunkFrames)
        XCTAssertFalse(stream.ended)
        let rest = try stream.read(maxChunks: 3)
        let frameCount = (first + rest).reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertEqual(frameCount, 48_000)
        XCTAssertTrue(stream.ended)
        XCTAssertEqual(first[0].format.channelCount, 2)
        XCTAssertEqual(first[0].format.sampleRate, 48_000)
        let seek = try AudioFileStream(url: url, offset: 0.75, format: output)
        let seekCount = try seek.read(maxChunks: 3).reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertEqual(seekCount, 12_000)
        XCTAssertEqual(seek.offset, 0.75, accuracy: 0.001)
    }
}

extension PlaybackTests {
    @MainActor
    func testMutedAudioKeepsAnalysisAndClockAcrossOutputSwitches() async throws {
        let directory = try makePlaybackTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tone = try writeTone(in: directory, name: "muted", sampleRate: 48_000, channels: 2, duration: 3)
        let output = try XCTUnwrap(AudioOutputs.defaultDevice())
        let player = PlayerEngine()
        player.volume = 0
        defer { player.onError = nil; player.unload() }
        var failure: Error?
        player.onError = { failure = $0 }
        try player.load(url: tone)
        try player.play()

        let clock = ContinuousClock()
        func waitForNewAnalysis(after stamp: UInt64, position: Double) async throws {
            let start = clock.now
            while start.duration(to: clock.now).playbackTestSeconds < 1.5 {
                let features = player.features()
                if player.currentTime > position + 0.1, features.hostTime > stamp, features.rms > 0.1 { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("音量0でも、新しい音響解析と音声時計が続くこと")
        }

        try await waitForNewAnalysis(after: 0, position: 0)
        XCTAssertEqual(player.features().rms, 0.1414, accuracy: 0.01)
        for device in [Optional(output), nil] {
            let position = player.currentTime
            let stamp = player.features().hostTime
            // Select the existing default device, then the default-output option.
            // This changes only this engine; the Mac's output setting is untouched.
            try player.setOutputDevice(device)
            try await waitForNewAnalysis(after: stamp, position: position)
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(player.volume, 0)
        }
        XCTAssertNil(failure)
    }

    @MainActor
    func testRealAudioNodeTransitionsBetweenDifferentFormatsOnItsClock() async throws {
        let directory = try makePlaybackTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeTone(in: directory, name: "first", sampleRate: 44_100, channels: 1, duration: 0.65)
        let second = try writeTone(in: directory, name: "second", sampleRate: 48_000, channels: 2, duration: 0.45)
        let player = PlayerEngine()
        player.volume = 0
        defer { player.onEnd = nil; player.onTrackTransition = nil; player.stop() }
        var transitions: [URL] = []
        var transitionSeconds: Double?
        var ended = false
        var endCount = 0
        var failure: Error?
        let clock = ContinuousClock()
        var start = clock.now
        player.onTrackTransition = { url in
            transitions.append(url)
            transitionSeconds = start.duration(to: clock.now).playbackTestSeconds
        }
        player.onEnd = { ended = true; endCount += 1 }
        player.onError = { failure = $0 }
        try player.load(url: first)
        try player.prepareNext(url: second)
        start = clock.now
        try player.play()
        var firstLatestTime = 0.0
        var secondLatestTime = 0.0
        while !ended, start.duration(to: clock.now).playbackTestSeconds < 4 {
            let wasFirstTrack = transitions.isEmpty
            let position = player.currentTime
            if wasFirstTrack, transitions.isEmpty { firstLatestTime = max(firstLatestTime, position) }
            if !transitions.isEmpty { secondLatestTime = max(secondLatestTime, position) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(failure)
        XCTAssertTrue(ended, "実AVAudioPlayerNodeの最終曲完了が届くこと")
        XCTAssertEqual(transitions, [second], "別sample rate/channel countの次曲へ一度だけ切り替わること")
        XCTAssertEqual(endCount, 1)
        XCTAssertGreaterThan(firstLatestTime, 0.50, "最初の曲の音声時計が末尾近くまで進むこと")
        XCTAssertGreaterThan(secondLatestTime, 0.30, "次曲の音声時計が新しい曲位置として進むこと")
        XCTAssertEqual(player.currentTime, 0.45, accuracy: 0.002)
        XCTAssertFalse(player.isPlaying)
        if let transitionSeconds {
            XCTAssertEqual(transitionSeconds, 0.65, accuracy: 0.20, "曲境界で通知し、先読み完了時には通知しないこと")
        }
        XCTAssertEqual(start.duration(to: clock.now).playbackTestSeconds, 1.10, accuracy: 0.25)
    }

    @MainActor
    func testRealAudioPauseSeekAndCanceledNextIgnoreOldCompletions() async throws {
        let directory = try makePlaybackTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeTone(in: directory, name: "first", sampleRate: 44_100, channels: 1, duration: 1.2)
        let second = try writeTone(in: directory, name: "second", sampleRate: 48_000, channels: 2, duration: 0.3)
        let player = PlayerEngine()
        player.volume = 0
        defer { player.onEnd = nil; player.onTrackTransition = nil; player.stop() }
        var transitions: [URL] = []
        var endCount = 0
        var failure: Error?
        player.onTrackTransition = { transitions.append($0) }
        player.onEnd = { endCount += 1 }
        player.onError = { failure = $0 }
        try player.load(url: first)
        try player.prepareNext(url: second)
        try player.play()
        let clock = ContinuousClock()
        let start = clock.now
        while player.currentTime < 0.10, start.duration(to: clock.now).playbackTestSeconds < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(player.currentTime, 0.09)
        player.pause()
        let pausedTime = player.currentTime
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.currentTime, pausedTime, accuracy: 0.002)
        XCTAssertFalse(player.isPlaying)
        try player.seek(to: 1.0)
        XCTAssertEqual(player.currentTime, 1.0, accuracy: 0.002)
        // A short remaining first track lets the decoder reserve the successor while paused.
        // Canceling it invalidates those already-enqueued callbacks and buffers.
        try await Task.sleep(for: .milliseconds(50))
        try player.prepareNext(url: nil)
        try player.play()
        let resume = clock.now
        while endCount == 0, resume.duration(to: clock.now).playbackTestSeconds < 2 {
            _ = player.currentTime
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(failure)
        XCTAssertEqual(endCount, 1, "seek前の古いcompletionが追加の終了通知を発生させないこと")
        XCTAssertTrue(transitions.isEmpty, "取り消した次曲のcallbackが後から発生しないこと")
        XCTAssertEqual(player.currentTime, 1.2, accuracy: 0.002)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testUnloadClearsTrackAndInvalidatesScheduledSuccessor() async throws {
        let directory = try makePlaybackTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeTone(in: directory, name: "first", sampleRate: 44_100, channels: 1, duration: 0.45)
        let second = try writeTone(in: directory, name: "second", sampleRate: 48_000, channels: 2, duration: 0.25)
        let player = PlayerEngine()
        player.volume = 0
        defer { player.onEnd = nil; player.onTrackTransition = nil; player.unload() }
        var transitions: [URL] = []
        var endCount = 0
        player.onTrackTransition = { transitions.append($0) }
        player.onEnd = { endCount += 1 }
        try player.load(url: first)
        try player.prepareNext(url: second)
        try player.play()
        try await Task.sleep(for: .milliseconds(60))
        player.unload()
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertFalse(player.isPlaying)
        try player.play()
        XCTAssertFalse(player.isPlaying, "unload後のplayで削除した曲が復活しないこと")
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(transitions.isEmpty, "削除前に予約した次曲通知が後から届かないこと")
        XCTAssertEqual(endCount, 0, "削除前のcompletionが終了通知として届かないこと")
        XCTAssertEqual(player.currentTime, 0)
    }

    private func makePlaybackTestDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicPrayerPlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeTone(in directory: URL, name: String, sampleRate: Double, channels: AVAudioChannelCount, duration: Double) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount((sampleRate * duration).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) { buffer.floatChannelData![channel][frame] = value }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private extension Duration {
    var playbackTestSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
