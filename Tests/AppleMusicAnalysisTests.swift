import AppKit
import AVFoundation
import XCTest
@testable import MusicPrayer

final class AppleMusicAnalysisTests: XCTestCase {
    func testInputCopiesGainAndExcludesPausedBuffers() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<480 { samples[frame * 2] = 0.1; samples[frame * 2 + 1] = -0.2 }
        let input = AppleMusicAnalysisInput()
        input.update(position: 10, volume: 0.2)
        input.append(buffer.audioBufferList, sampleRate: 48_000)
        input.update(position: nil, volume: 0.2)
        for _ in 0..<5 { input.append(buffer.audioBufferList, sampleRate: 48_000) }
        input.update(position: 10.01, volume: 0.2)
        input.append(buffer.audioBufferList, sampleRate: 48_000)
        input.finish()
        // Mutating CoreAudio's original storage must not change the queued copy.
        samples[0] = 0
        var received = 0
        for await value in input.stream {
            XCTAssertEqual(value.frameLength, 480)
            let copied = AVAudioPCMBuffer(copying: value)
            XCTAssertEqual(copied.floatChannelData![0][0], 0.5, accuracy: 0.000001)
            XCTAssertEqual(copied.floatChannelData![1][0], -1, accuracy: 0.000001)
            received += 1
        }
        XCTAssertEqual(received, 2)
        let coverage = input.snapshot()
        XCTAssertTrue(coverage.valid)
        XCTAssertEqual(coverage.origin, 10)
        XCTAssertEqual(coverage.seconds, 0.02, accuracy: 0.000001)
    }

    func testDroppedInputCannotBeConsideredCompleteCoverage() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48))
        buffer.frameLength = 48
        buffer.floatChannelData![0].initialize(repeating: 0, count: 48)
        let input = AppleMusicAnalysisInput()
        input.update(position: 0, volume: 1)
        for _ in 0..<65 { input.append(buffer.audioBufferList, sampleRate: 48_000) }
        XCTAssertFalse(input.snapshot().valid)
        input.finish()
    }

    func testExcerptTimesReachExistingSamplerAndComposer() {
        var analysis = MusicAnalysis(duration: 60, beats: [0, 0.5, 1], bars: [0, 2], bpm: 120,
                                     sections: [TimeSpan(start: 0, duration: 5)],
                                     segments: [TimeSpan(start: 0, duration: 2)],
                                     phrases: [TimeSpan(start: 0, duration: 1)],
                                     pace: [PaceSpan(range: TimeSpan(start: 0, duration: 5), value: 120)],
                                     vocal: [TimeValue(time: 0, value: 0.8), TimeValue(time: 1, value: 0.6)],
                                     momentary: [TimeValue(time: 0, value: -12), TimeValue(time: 1, value: -10)],
                                     integrated: -14,
                                     keys: [KeySpan(range: TimeSpan(start: 0, duration: 5), label: "E major", hue: 0.1, minor: false)])
        analysis.shiftTimes(by: 10)
        XCTAssertNil(TimelineSampler.sample(analysis, at: 1).vocal)
        let moment = TimelineSampler.sample(analysis, at: 10.05)
        XCTAssertEqual(moment.key, "E major")
        XCTAssertEqual(moment.bpm, 120)
        XCTAssertGreaterThan(moment.beat, 0.5)
        XCTAssertEqual(moment.section, 1)
        XCTAssertGreaterThan(moment.vocal ?? 0, 0.6)
        var composer = VisualComposer()
        let scene = SectionScenes.make(analysis).first
        let frame = composer.compose(time: 10.05, audio: AudioFeatures(), moment: moment, scene: scene, analyzed: true, presence: 1, dt: 1 / 60)
        XCTAssertEqual(frame.hasAnalysis, 1)
        XCTAssertGreaterThan(frame.beat, 0.5)
        XCTAssertGreaterThan(frame.vocal, 0)
        XCTAssertGreaterThan(frame.hue, 0)
        XCTAssertGreaterThan(frame.loudness, 0)
        XCTAssertEqual(analysis.duration, 60)
    }

    @MainActor
    func testNaturalEndCanCompleteAfterImmediateRepeatSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let service = AppleMusicAnalysis(cache: cache)
        let song = AppleMusicSong(id: "synthetic-repeat", title: "Synthetic", artist: "", album: "", duration: 12.01)
        service.setQueueSongs([song])
        service.select(song, force: true)
        let input = try XCTUnwrap(service.update(position: 0.01, isPlaying: true, volume: 1))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for second in 0..<12 {
            for frame in 0..<48_000 {
                let t = Double(second) + Double(frame) / 48_000
                buffer.floatChannelData![0][frame] = Float(sin(2 * .pi * 220 * t) * 0.15)
            }
            input.append(buffer.audioBufferList, sampleRate: 48_000)
        }
        service.finish()
        service.select(song) // Auto-repeat selects before the framework returns its final result.
        for _ in 0..<400 {
            if service.analysis != nil && !service.analyzing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(service.analysis?.fingerprint, "appleMusic:" + song.id)
        XCTAssertFalse(service.analyzing)
        XCTAssertNil(service.update(position: 2, isPlaying: true, volume: 1))
        let saved = await cache.load(id: song.id, duration: song.duration)
        XCTAssertNotNil(saved)
        service.interrupt()
    }

    @MainActor
    func testCacheReuseAndSelectionClearThePreviousSong() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let song = AppleMusicSong(id: "test-first", title: "First", artist: "", album: "", duration: 60)
        let saved = MusicAnalysis(fingerprint: "appleMusic:test-first", duration: 60, beats: [0, 0.5], bpm: 120)
        try await cache.retainSongs([song.id, "test-second"])
        let issuedTicket = await cache.ticket(for: song.id)
        let ticket = try XCTUnwrap(issuedTicket)
        try await cache.save(saved, id: song.id, ticket: ticket)
        let service = AppleMusicAnalysis(cache: cache)
        service.setQueueSongs([song, AppleMusicSong(id: "test-second", title: "Second", artist: "", album: "", duration: 60)])
        service.select(song)
        for _ in 0..<100 {
            if service.analysis?.bpm != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(service.analysis?.bpm, 120)
        XCTAssertNil(service.update(position: 2, isPlaying: true, volume: 1), "Cached analysis does not start another audio session")
        service.select(AppleMusicSong(id: "test-second", title: "Second", artist: "", album: "", duration: 60))
        XCTAssertNil(service.analysis)
        XCTAssertFalse(service.analyzing)
        let differentDuration = await cache.load(id: song.id, duration: 80)
        XCTAssertNil(differentDuration)
        var oldVersion = saved; oldVersion.version = 0
        try await cache.save(oldVersion, id: song.id, ticket: ticket)
        let stale = await cache.load(id: song.id, duration: 60)
        XCTAssertNil(stale)
        service.interrupt()
    }
    @MainActor
    private func feedTone(_ service: AppleMusicAnalysis, song: AppleMusicSong, origin: Double) throws {
        service.setQueueSongs([song])
        service.select(song, force: true)
        let input = try XCTUnwrap(service.update(position: origin, isPlaying: true, volume: 1))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for second in 0..<12 {
            for frame in 0..<48_000 {
                let t = Double(second) + Double(frame) / 48_000
                buffer.floatChannelData![0][frame] = Float(sin(2 * .pi * 220 * t) * 0.15)
            }
            input.append(buffer.audioBufferList, sampleRate: 48_000)
        }
    }

    @MainActor
    private func waitForAnalysis(_ service: AppleMusicAnalysis) async throws {
        for _ in 0..<400 {
            if service.analysis != nil && !service.analyzing { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("確定した解析結果を読み込めませんでした：" + (service.error ?? ""))
    }

    @MainActor
    private func withPlayer(directory: URL, operation: (PlayerStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let queue = QueuePersistence.file
        let original = try? Data(contentsOf: queue)
        let store = PlayerStore(appleMusicAnalysisDirectory: directory)
        var failure: Error?
        do { try await operation(store) } catch { failure = error }
        store.shutdown()
        await store.appleMusic.musicAnalysis.finishStorageBeforeTermination()
        if let original { try original.write(to: queue, options: .atomic) }
        else if FileManager.default.fileExists(atPath: queue.path) { try FileManager.default.removeItem(at: queue) }
        if let failure { throw failure }
    }

    @MainActor
    func testDelayedInputIsSavedAndReusedAfterRestartStopAndReselection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = AppleMusicSong(id: "delayed-input", title: "Late input", artist: "", album: "", duration: 15.2)
        let cache = AppleMusicAnalysisCache(directory: directory)
        let service = AppleMusicAnalysis(cache: cache)
        // Covers both old silent-discard conditions: origin >= 0.5 and end difference >= 1 second.
        try feedTone(service, song: song, origin: 2)
        service.finish()
        await service.finishStorageBeforeTermination()
        XCTAssertNil(service.error)
        XCTAssertFalse(service.needsStorageBeforeTermination)
        let measured = try XCTUnwrap(service.analysis)
        XCTAssertGreaterThan(measured.vocal.count, 0)
        XCTAssertGreaterThanOrEqual(measured.vocal.first?.time ?? 0, 2)
        XCTAssertNil(TimelineSampler.sample(measured, at: 1).vocal)
        let persisted = await cache.load(id: song.id, duration: song.duration)
        XCTAssertNotNil(persisted)
        // A fresh controller and fresh cache actor represent a later app launch.
        try await withPlayer(directory: directory) { store in
            store.tracks = [Track(appleMusicSong: song)]
            store.select(0, autoplay: false)
            try await waitForAnalysis(store.appleMusic.musicAnalysis)
            for _ in 0..<100 {
                if store.analysis != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(store.analysis)
            let fingerprint = store.analysis?.fingerprint
            let beatCount = store.analysis?.beats.count
            store.stop()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.analysis?.fingerprint, fingerprint)
            XCTAssertEqual(store.analysis?.beats.count, beatCount)
            XCTAssertFalse(store.analyzing)
            XCTAssertFalse(store.isPlaying)
            store.select(0, autoplay: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.analysis?.fingerprint, fingerprint)
            XCTAssertFalse(store.analyzing)
            XCTAssertNil(store.appleMusic.musicAnalysis.update(position: 4, isPlaying: true, volume: 1))
            let loaded = try XCTUnwrap(store.appleMusic.musicAnalysis.analysis)
            XCTAssertEqual(loaded.vocal, measured.vocal)
            XCTAssertEqual(loaded.beats, measured.beats)
        }
    }

    @MainActor
    func testRemovalWhileFinalizingCannotResurrectFileAfterReaddition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = AppleMusicSong(id: "removed-while-finishing", title: "Remove", artist: "", album: "", duration: 12.01)
        let cache = AppleMusicAnalysisCache(directory: directory)
        let service = AppleMusicAnalysis(cache: cache)
        try feedTone(service, song: song, origin: 0.01)
        service.finish()
        service.setQueueSongs([])
        service.setQueueSongs([song])
        await service.finishStorageBeforeTermination()
        let result = await cache.load(id: song.id, duration: song.duration)
        XCTAssertNil(result)
        XCTAssertNil(service.analysis)
        XCTAssertFalse(service.needsStorageBeforeTermination)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(files.isEmpty)
        // Even a token obtained before deletion cannot save into the re-added entry.
        let oldTicket = try await awaitTicket(cache, id: song.id)
        try await cache.retainSongs([])
        try await cache.retainSongs([song.id])
        let saved = try await cache.save(MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: song.duration), id: song.id, ticket: oldTicket)
        XCTAssertFalse(saved)
    }

    private func awaitTicket(_ cache: AppleMusicAnalysisCache, id: String) async throws -> UUID {
        let ticket = await cache.ticket(for: id)
        return try XCTUnwrap(ticket)
    }

    @MainActor
    func testQueuePrunesOrphansAndDeletesOnlyTheLastRegistration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let song = AppleMusicSong(id: "kept", title: "Keep", artist: "", album: "", duration: 60)
        try await cache.retainSongs([song.id, "orphan"])
        for id in [song.id, "orphan"] {
            let ticket = try await awaitTicket(cache, id: id)
            try await cache.save(MusicAnalysis(fingerprint: "appleMusic:" + id, duration: 60, beats: [1, 1.5], bpm: 120), id: id, ticket: ticket)
        }
        try await withPlayer(directory: directory) { store in
            store.tracks = [Track(appleMusicSong: song), Track(appleMusicSong: song)]
            await store.appleMusic.musicAnalysis.finishStorageBeforeTermination()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
            store.remove(store.tracks[1].id)
            await store.appleMusic.musicAnalysis.finishStorageBeforeTermination()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
            store.remove(store.tracks[0].id)
            await store.appleMusic.musicAnalysis.finishStorageBeforeTermination()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @MainActor
    func testStoppingMidSongDoesNotCacheAnUnfinishedPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let service = AppleMusicAnalysis(cache: cache)
        let song = AppleMusicSong(id: "interrupted", title: "Partial", artist: "", album: "", duration: 60)
        try feedTone(service, song: song, origin: 0.01)
        service.stopUnfinishedAnalysis()
        await service.finishStorageBeforeTermination()
        let saved = await cache.load(id: song.id, duration: song.duration)
        XCTAssertNil(saved)
        XCTAssertFalse(service.analyzing)
        XCTAssertNotNil(service.update(position: 0.01, isPlaying: true, volume: 1))
        service.interrupt()
    }

    @MainActor
    func testSilentAndForegroundAnalysisShareOneQueueRegistrationAndCachedResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let foreground = AppleMusicAnalysis(cache: cache)
        let background = AppleMusicAnalysis(cache: cache, managesQueueCache: false)
        let song = AppleMusicSong(id: "shared-registration", title: "Song", artist: "", album: "", duration: 60)
        for songs in [[song], [], [song]] {
            foreground.setQueueSongs(songs)
            background.setQueueSongs(songs, after: foreground.queueRegistration)
        }
        await foreground.finishStorageBeforeTermination()
        await background.finishStorageBeforeTermination()
        let ticket = try await awaitTicket(cache, id: song.id)
        let value = MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: 60, beats: [1, 2], bpm: 120)
        try await cache.save(value, id: song.id, ticket: ticket)
        let reused = await background.loadSavedAnalysis(for: song)
        XCTAssertTrue(reused)
        XCTAssertNil(background.update(position: 1, isPlaying: true, volume: 0.12))
        _ = await foreground.loadSavedAnalysis(for: song)
        XCTAssertEqual(foreground.analysis?.beats, [1, 2])
        let replacement = MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: 60, beats: [1, 1.5, 2], bpm: 120)
        try await cache.save(replacement, id: song.id, ticket: ticket)
        foreground.refreshSavedAnalysis(for: song)
        _ = await foreground.loadSavedAnalysis(for: song)
        XCTAssertEqual(foreground.analysis?.beats, replacement.beats)
        foreground.setQueueSongs([])
        background.setQueueSongs([], after: foreground.queueRegistration)
        await foreground.finishStorageBeforeTermination()
        await background.finishStorageBeforeTermination()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPreparedAudioIsPulledWithoutRealtimeBufferDrops() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 12 + 17))
        source.frameLength = source.frameCapacity
        for channel in 0..<2 { source.floatChannelData![channel].initialize(repeating: channel == 0 ? 0.25 : -0.5, count: Int(source.frameLength)) }
        let input = AppleMusicAnalysisInput(prepared: source, origin: 0.02)
        input.finish()
        var frames = 0, chunks = 0
        for await item in input.stream {
            let buffer = AVAudioPCMBuffer(copying: item)
            XCTAssertEqual(buffer.format.sampleRate, 48_000)
            XCTAssertEqual(buffer.floatChannelData![0][0], 0.25)
            XCTAssertEqual(buffer.floatChannelData![1][0], -0.5)
            frames += Int(buffer.frameLength); chunks += 1
        }
        XCTAssertGreaterThan(chunks, 64, "事前取得済みの音をリアルタイム用64バッファ制限で欠落させない")
        XCTAssertEqual(frames, Int(source.frameLength))
        XCTAssertTrue(input.snapshot().valid)
        XCTAssertEqual(input.snapshot().origin, 0.02)
    }

    func testFastRecordingCopiesOnlyAdvancingMediaAndKeepsNativeRate() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        source.frameLength = 480
        source.floatChannelData![0].initialize(repeating: 0.1, count: 480)
        let recording = AppleMusicPCMRecording(volume: 0.2)
        recording.update(position: 0)
        recording.append(source.audioBufferList, sampleRate: 48_000)
        recording.update(position: 0.02)
        recording.append(source.audioBufferList, sampleRate: 48_000)
        recording.update(position: nil)
        recording.append(source.audioBufferList, sampleRate: 48_000)
        source.floatChannelData![0][0] = 0
        let captured = try recording.takeAudio(endingAt: 100)
        XCTAssertEqual(captured.origin, 0.02)
        XCTAssertEqual(captured.buffer.frameLength, 480)
        XCTAssertEqual(captured.buffer.format.sampleRate, 48_000, "半分のレートへ読み替えない")
        XCTAssertEqual(captured.buffer.floatChannelData![0][0], 0.5, accuracy: 0.000001)
    }

    func testFastRecordingRemovesOnlyStartupFramesBeyondTheMediaInterval() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        source.frameLength = 240
        source.floatChannelData![0].initialize(repeating: 0, count: 240)
        let recording = AppleMusicPCMRecording(volume: 1)
        recording.update(position: 1)
        recording.append(source.audioBufferList, sampleRate: 48_000)
        source.floatChannelData![0].initialize(repeating: 0.25, count: 240)
        recording.append(source.audioBufferList, sampleRate: 48_000)
        // 0.01 seconds of source time takes 0.005 seconds (240 frames) at 2x.
        let captured = try recording.takeAudio(endingAt: 1.01)
        XCTAssertEqual(captured.origin, 1)
        XCTAssertEqual(captured.buffer.frameLength, 240)
        XCTAssertEqual(captured.buffer.floatChannelData![0][0], 0.25)
        XCTAssertEqual(captured.buffer.floatChannelData![0][239], 0.25)
    }

    func testFastRecordingKeepsLegitimateLeadingSilenceInsideTheMediaInterval() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        source.frameLength = 480
        source.floatChannelData![0].initialize(repeating: 0, count: 240)
        (source.floatChannelData![0] + 240).initialize(repeating: 0.25, count: 240)
        let recording = AppleMusicPCMRecording(volume: 1)
        recording.update(position: 1)
        recording.append(source.audioBufferList, sampleRate: 48_000)
        let captured = try recording.takeAudio(endingAt: 1.02)
        XCTAssertEqual(captured.buffer.frameLength, 480)
        XCTAssertEqual(captured.buffer.floatChannelData![0][0], 0)
        XCTAssertEqual(captured.buffer.floatChannelData![0][239], 0)
        XCTAssertEqual(captured.buffer.floatChannelData![0][240], 0.25)
    }

    @MainActor
    func testPreparedFastInputUsesExistingAnalyzerAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AppleMusicAnalysisCache(directory: directory)
        let service = AppleMusicAnalysis(cache: cache)
        let song = AppleMusicSong(id: "prepared-2x", title: "Prepared", artist: "", album: "", duration: 12.01)
        service.setQueueSongs([song]); service.select(song, force: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 12))
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 220 * Double(i) / 48_000) * 0.15) }
        await service.analyzePreparedAudio(buffer, origin: 0.01)
        XCTAssertNil(service.error)
        XCTAssertNotNil(service.analysis)
        XCTAssertFalse(service.analyzing)
        let stored = await cache.load(id: song.id, duration: song.duration)
        XCTAssertEqual(stored?.fingerprint, "appleMusic:" + song.id)
        XCTAssertGreaterThan(stored?.vocal.count ?? 0, 0)
        XCTAssertNil(service.update(position: 2, isPlaying: true, volume: 1))
    }

}
