import AVFoundation
import AppKit
import CryptoKit
import Darwin
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
        XCTAssertEqual(previousVisual.trackID, store.tracks[0].id)

        let selectedAt = clock.now
        store.select(1)
        store.visualizerStyle = .cassette
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
        XCTAssertEqual(fadingVisual.trackID, previousVisual.trackID, "旧曲の映像はフェードアウトが終わるまで保持すること")
        XCTAssertEqual(fadingVisual.style, .cassette, "旧曲がフェード中でも現在の選択を描画へ渡すこと")
        XCTAssertEqual(fadingVisual.title, previousVisual.title, "旧曲のカセットには旧曲のラベルを保持すること")
        XCTAssertEqual(fadingVisual.duration, previousVisual.duration)

        while selectedAt.duration(to: clock.now).secondsValue < 0.9 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let newVisual = store.visualSource.snapshot()
        XCTAssertEqual(Double(newVisual.time), store.engine.currentTime, accuracy: 0.06)
        XCTAssertGreaterThan(newVisual.presence, 0.99, "0.8秒の映像遷移後は新曲を通常表示すること")
        XCTAssertEqual(newVisual.trackID, store.tracks[1].id, "新曲のフェードインから新曲の映像を公開すること")
        XCTAssertEqual(newVisual.style, .cassette)
        XCTAssertEqual(newVisual.title, store.tracks[1].title)
        XCTAssertEqual(newVisual.duration, store.engine.duration, accuracy: 0.001)
        XCTAssertEqual(store.currentTrack?.url, second)
        XCTAssertTrue(store.engine.isPlaying)
        // The outcome of Music Understanding is deliberately not an acceptance condition.
        store.shutdown()
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor
    func testLyricsUseIncomingTrackClockDuringOutgoingMetalFade() async throws {
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("最初の曲の解析と音源確認が完了すること") {
                store.analysis?.fingerprint == fixture.fingerprints[0] &&
                store.lyricFingerprint == fixture.fingerprints[0]
            }
            store.seek(0.8)
            try await self.waitUntil("旧曲のMetal用frameがシーク位置を保持すること") {
                store.visualSource.snapshot().trackID == store.tracks[0].id &&
                abs(Double(store.visualSource.snapshot().time) - 0.8) < 0.001
            }
            let previousGeneration = store.playbackGeneration
            let previousVisual = store.visualSource.snapshot()
            store.select(1, autoplay: false)
            let switched = store.visualSource.snapshot()
            let switchedLyrics = try XCTUnwrap(switched.lyrics)
            XCTAssertEqual(switched.trackID, previousVisual.trackID)
            XCTAssertEqual(switchedLyrics.trackID, store.tracks[1].id)
            XCTAssertGreaterThan(switchedLyrics.playbackGeneration, previousGeneration)
            XCTAssertEqual(switchedLyrics.playbackGeneration, store.playbackGeneration)
            XCTAssertEqual(switchedLyrics.time, 0, accuracy: 0.001)
            XCTAssertGreaterThan(Double(switched.time), switchedLyrics.time + 0.5)
            XCTAssertNotEqual(switchedLyrics.audioFingerprint, fixture.fingerprints[0])

            try await self.waitUntil("旧曲の映像フェード中にも新曲のfingerprintを公開すること", timeout: .milliseconds(350)) {
                let frame = store.visualSource.snapshot()
                return frame.trackID == previousVisual.trackID &&
                    frame.lyrics?.audioFingerprint == fixture.fingerprints[1]
            }
            let fading = store.visualSource.snapshot()
            XCTAssertEqual(fading.lyrics?.trackID, store.currentTrack?.id)
            XCTAssertEqual(fading.lyrics?.playbackGeneration, store.playbackGeneration)
            XCTAssertEqual(try XCTUnwrap(fading.lyrics).time, store.engine.currentTime, accuracy: 0.001)
            XCTAssertGreaterThan(Double(fading.time), try XCTUnwrap(fading.lyrics).time + 0.5)
        }
    }

    @MainActor
    func testSelectingSameTrackAgainStartsNewLyricGenerationAndRestoresSavedText() async throws {
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("同曲再選択テストの音源確認が完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            store.applyLyrics("同じ歌詞")
            try await self.waitUntil("元のタイムラインを保存し終えること") {
                let saved = try fixture.saved(index: 0)
                return store.lyricTimeline != nil && saved?.timeline != nil
            }
            let firstGeneration = store.playbackGeneration
            let originalTimeline = try XCTUnwrap(store.lyricTimeline)
            let trackID = store.currentTrack?.id
            store.select(0, autoplay: false)
            XCTAssertEqual(store.currentTrack?.id, trackID)
            XCTAssertGreaterThan(store.playbackGeneration, firstGeneration)
            XCTAssertEqual(store.visualSource.snapshot().lyrics?.playbackGeneration, store.playbackGeneration)
            XCTAssertNil(store.lyricTimeline, "旧再生世代の結果を選択直後に残さないこと")
            try await self.waitUntil("同じ曲の本文と有効なタイムラインを復元すること") {
                store.lyricText == "同じ歌詞" && store.lyricTimeline == originalTimeline
            }
            XCTAssertEqual(store.visualSource.snapshot().lyrics?.audioFingerprint, fixture.fingerprints[0])
            XCTAssertEqual(store.visualSource.snapshot().lyrics?.playbackGeneration, store.playbackGeneration)
            XCTAssertNotEqual(store.visualSource.snapshot().lyrics?.playbackGeneration, firstGeneration)
        }
    }

    @MainActor
    func testValidSavedSpeechTimelineRestoresWithoutStartingRecognition() async throws {
        let transcriber = FixtureLyricTranscriber()
        try await withLyricFixture(lyricTranscriber: transcriber) { store, fixture in
            let source = "保存した歌詞"
            let analysis = try JSONDecoder().decode(MusicAnalysis.self,
                                                    from: Data(contentsOf: fixture.analysisFile(index: 0)))
            let timeline = try LyricAligner.align(sourceText: source, analysis: analysis,
                                                  transcription: FixtureLyricTranscriber.tokens(for: source))
            let savedStore = LyricStore(directory: fixture.lyrics)
            _ = try await savedStore.saveText(url: fixture.audio[0], text: source, request: 1)
            try await savedStore.saveTimeline(timeline, request: 1)

            store.select(0, autoplay: false)
            XCTAssertNil(store.lyricTimeline)
            try await self.waitUntil("有効な認識済みキャッシュを復元すること") {
                store.lyricTimeline == timeline && store.lyricTimingState == .generated(.speechRecognition)
            }
            let calls = await transcriber.callCount
            XCTAssertEqual(calls, 0, "有効な保存結果の復元では認識もモデル準備も開始しないこと")
            XCTAssertEqual(store.lyricText, source)
        }
    }

    @MainActor
    func testCancelledRecognitionCannotPublishOldProgressOrResultsAfterSelectionAndReapply() async throws {
        let oldTrackText = "前の曲の歌詞"
        let currentTrackText = "選んだ曲の歌詞"
        let oldAppliedText = "再適用前の歌詞"
        let currentAppliedText = "再適用後の歌詞"
        let transcriber = FixtureLyricTranscriber(heldSources: [oldTrackText, currentTrackText,
                                                               oldAppliedText, currentAppliedText])
        try await withLyricFixture(lyricTranscriber: transcriber) { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("最初の曲の確認を完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            store.applyLyrics(oldTrackText)
            try await self.waitUntilAsync("前の曲の認識を実行中のまま保留すること") {
                await transcriber.isHeld(oldTrackText)
            }
            XCTAssertEqual(store.lyricTimingState, .recognizing)

            store.select(1, autoplay: false)
            try await self.waitUntil("曲を切り替えて現在曲の確認を完了すること") {
                store.lyricFingerprint == fixture.fingerprints[1] && store.analysis != nil
            }
            store.applyLyrics(currentTrackText)
            try await self.waitUntilAsync("現在曲の認識を保留すること") {
                await transcriber.isHeld(currentTrackText)
            }
            await transcriber.release(oldTrackText)
            try await self.waitUntilAsync("キャンセルされた前の曲の遅延通知を実際に送ること") {
                await transcriber.hasCompleted(oldTrackText)
            }
            XCTAssertEqual(store.lyricTimingState, .recognizing,
                           "前の曲の遅延progressで現在曲の状態を上書きしないこと")
            XCTAssertEqual(store.lyricText, currentTrackText)
            XCTAssertNil(store.lyricTimeline)
            await transcriber.release(currentTrackText)
            try await self.waitUntil("現在曲の結果だけを生成・保存すること") {
                let saved = try fixture.saved(index: 1)
                return store.lyricTimeline?.sourceText == currentTrackText &&
                    saved?.timeline?.sourceText == currentTrackText
            }

            store.applyLyrics(oldAppliedText)
            try await self.waitUntilAsync("同じ曲の古い適用を認識中に保留すること") {
                await transcriber.isHeld(oldAppliedText)
            }
            store.applyLyrics(currentAppliedText)
            try await self.waitUntilAsync("新しい適用の認識を保留すること") {
                await transcriber.isHeld(currentAppliedText)
            }
            await transcriber.release(oldAppliedText)
            try await self.waitUntilAsync("再適用前の遅延通知を実際に送ること") {
                await transcriber.hasCompleted(oldAppliedText)
            }
            XCTAssertEqual(store.lyricTimingState, .recognizing,
                           "再適用前の遅延progressで新しい適用の状態を上書きしないこと")
            XCTAssertEqual(store.lyricText, currentAppliedText)
            XCTAssertNil(store.lyricTimeline)
            await transcriber.release(currentAppliedText)
            try await self.waitUntil("新しい適用の結果だけを生成・保存すること") {
                let saved = try fixture.saved(index: 1)
                return store.lyricTimeline?.sourceText == currentAppliedText &&
                    saved?.timeline?.sourceText == currentAppliedText
            }
            XCTAssertEqual(store.lyricTimingState, .generated(.speechRecognition))
            let calls = await transcriber.callCount
            XCTAssertEqual(calls, 4, "本文保存完了が実行中の認識を重複起動しないこと")
        }
    }

    @MainActor
    func testTerminationSavesConfirmedTextWithoutWaitingForRecognition() async throws {
        let source = "認識待ちでも保存する本文"
        let transcriber = FixtureLyricTranscriber(heldSources: [source])
        try await withLyricFixture(lyricTranscriber: transcriber) { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("終了テストの音源確認を完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            store.applyLyrics(source)
            try await self.waitUntilAsync("認識が未完了のまま保留されること") {
                await transcriber.isHeld(source)
            }
            try await self.waitUntil("認識結果を待たずに確定本文だけを保存すること") {
                (try fixture.saved(index: 0))?.sourceText == source && !store.needsLyricSaveBeforeTermination
            }
            XCTAssertNil(store.lyricTimeline)
            var completed: Bool?
            let termination = Task { @MainActor in completed = await store.finishLyricsBeforeTermination() }
            defer { termination.cancel() }
            try await self.waitUntil("認識gateを解放する前に終了の保存処理が返ること", timeout: .seconds(1)) {
                completed != nil
            }
            XCTAssertEqual(completed, true)
            let recognitionStillHeld = await transcriber.isHeld(source)
            XCTAssertTrue(recognitionStillHeld, "認識完了を終了条件に含めないこと")
            XCTAssertFalse(store.lyricsAcceptingRequests)
            XCTAssertEqual(try fixture.saved(index: 0)?.sourceText, source)
            XCTAssertNil(try fixture.saved(index: 0)?.timeline)
            await transcriber.release(source)
            try await self.waitUntilAsync("終了後に届くキャンセル済み認識の通知を消費すること") {
                await transcriber.hasCompleted(source)
            }
            XCTAssertNil(store.lyricTimeline)
        }
    }

    @MainActor
    func testStoppedSeekPreviewAndStopPublishLyricRevisionWithoutPeriodicRevisionUpdates() async throws {
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("停止中の操作テストの音源確認が完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            store.applyLyrics("停止中の歌詞")
            try await self.waitUntil("停止中の歌詞タイムライン生成と保存が完了すること") {
                let saved = try fixture.saved(index: 0)
                return store.lyricTimeline != nil && saved?.timeline != nil
            }
            var revision = store.lyricFrameRevision
            store.seek(1.2)
            XCTAssertGreaterThan(store.lyricFrameRevision, revision)
            var payload = try XCTUnwrap(store.visualSource.snapshot().lyrics)
            XCTAssertEqual(payload.time, 1.2, accuracy: 0.001)
            XCTAssertFalse(payload.isPlaying)
            XCTAssertFalse(payload.isPreviewing)

            revision = store.lyricFrameRevision
            store.previewTime = 0.4
            XCTAssertGreaterThan(store.lyricFrameRevision, revision)
            payload = try XCTUnwrap(store.visualSource.snapshot().lyrics)
            XCTAssertEqual(payload.time, 0.4, accuracy: 0.001)
            XCTAssertTrue(payload.isPreviewing)
            XCTAssertFalse(payload.isPlaying)

            revision = store.lyricFrameRevision
            store.previewTime = nil
            XCTAssertGreaterThan(store.lyricFrameRevision, revision)
            XCTAssertEqual(try XCTUnwrap(store.visualSource.snapshot().lyrics).time, 1.2, accuracy: 0.001)
            revision = store.lyricFrameRevision
            store.stop()
            XCTAssertGreaterThan(store.lyricFrameRevision, revision)
            XCTAssertEqual(try XCTUnwrap(store.visualSource.snapshot().lyrics).time, 0, accuracy: 0.001)
            XCTAssertFalse(try XCTUnwrap(store.visualSource.snapshot().lyrics).isPlaying)

            let stoppedRevision = store.lyricFrameRevision
            var publishedFrames = 0
            store.visualSource.observeFrames { publishedFrames += 1 }
            try await self.waitUntil("停止後も既存Metal用tickが3回以上発行されること") { publishedFrames >= 3 }
            XCTAssertEqual(store.lyricFrameRevision, stoppedRevision,
                           "通常tickで歌詞のObservable revisionを60Hz更新しないこと")
        }
    }

    @MainActor
    func testAppliedTextDuringFingerprintWaitPersistsAfterTrackChanges() async throws {
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            XCTAssertNil(store.lyricFingerprint)
            XCTAssertEqual(store.lyricTimingState, .checkingAudio)
            let committedText = "  元の曲の本文\r\n残す行  "
            store.applyLyrics(committedText)
            store.select(1, autoplay: false)
            XCTAssertEqual(store.currentTrack?.url, fixture.audio[1])
            try await self.waitUntil("曲変更後も元の音源への確定本文保存を完了すること") {
                (try fixture.saved(index: 0))?.sourceText == committedText &&
                store.lyricFingerprint == fixture.fingerprints[1] && !store.needsLyricSaveBeforeTermination
            }
            let saved = try XCTUnwrap(fixture.saved(index: 0))
            XCTAssertEqual(saved.audioFingerprint, fixture.fingerprints[0])
            XCTAssertEqual(saved.sourceTextHash, LyricHash.text(committedText))
            XCTAssertEqual(store.lyricText, "")
            XCTAssertNil(store.lyricTimeline)
            XCTAssertEqual(store.visualSource.snapshot().lyrics?.audioFingerprint, fixture.fingerprints[1])
            XCTAssertEqual(store.visualSource.snapshot().lyrics?.trackID, store.tracks[1].id)
            let completed = await store.finishLyricsBeforeTermination()
            XCTAssertTrue(completed)
        }
    }

    @MainActor
    func testTerminationRetryOfFailedAliasNeverReplacesNewerSavedText() async throws {
        try await withLyricFixture(sameAudio: true) { store, fixture in
            XCTAssertEqual(fixture.fingerprints[0], fixture.fingerprints[1])
            store.select(0, autoplay: false)
            try await self.waitUntil("別URL競合テストの最初の音源確認が完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            try Data("保存先を塞ぐ通常ファイル".utf8).write(to: fixture.lyrics)
            store.applyLyrics("古い本文")
            try await self.waitUntil("元URLの保存失敗が記録されること") { store.hasPendingLyricSaveFailure }
            try FileManager.default.removeItem(at: fixture.lyrics)
            store.select(1, autoplay: false)
            try await self.waitUntil("同じ音源の別URL側を選択し終えること") {
                store.lyricFingerprint == fixture.fingerprints[1] && store.analysis != nil
            }
            let latestText = "新しい本文"
            store.applyLyrics(latestText)
            try await self.waitUntil("別URLの新しい本文とタイムライン保存を完了すること") {
                let saved = try fixture.saved(index: 1)
                return saved?.sourceText == latestText && saved?.timeline != nil && store.lyricTimeline != nil
            }
            XCTAssertTrue(store.hasPendingLyricSaveFailure, "別URLの旧失敗要求を終了時に棄却する経路を検査すること")
            let completed = await store.finishLyricsBeforeTermination()
            XCTAssertTrue(completed)
            XCTAssertFalse(store.hasPendingLyricSaveFailure)
            XCTAssertNil(store.lyricSaveError)
            XCTAssertFalse(store.needsLyricSaveBeforeTermination)
            XCTAssertEqual(try fixture.saved(index: 1)?.sourceText, latestText,
                           "再試行を新しい適用として扱い、旧本文で上書きしないこと")
        }
    }

    @MainActor
    func testTerminationSaveFailureReopensRequestsAndRetryCanFinish() async throws {
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("終了失敗テストの音源確認が完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            try Data("保存先を塞ぐ通常ファイル".utf8).write(to: fixture.lyrics)
            store.applyLyrics("終了前の確定本文")
            try await self.waitUntil("生成結果を保持し、保存失敗だけを表示すること") {
                store.hasPendingLyricSaveFailure && store.lyricTimeline != nil
            }
            let cancelled = await store.finishLyricsBeforeTermination()
            XCTAssertFalse(cancelled, "未保存の確定本文が残ると終了をキャンセルすること")
            XCTAssertTrue(store.lyricsAcceptingRequests)
            XCTAssertTrue(store.hasPendingLyricSaveFailure)
            XCTAssertNotNil(store.lyricSaveError)
            XCTAssertEqual(store.lyricText, "終了前の確定本文")
            try FileManager.default.removeItem(at: fixture.lyrics)
            store.retryLyricSave()
            try await self.waitUntil("失敗した確定本文の保存再試行を完了すること") {
                (try fixture.saved(index: 0))?.sourceText == "終了前の確定本文" &&
                !store.needsLyricSaveBeforeTermination
            }
            XCTAssertNil(store.lyricSaveError)
            let completed = await store.finishLyricsBeforeTermination()
            XCTAssertTrue(completed)
            XCTAssertFalse(store.lyricsAcceptingRequests)
            XCTAssertEqual(try fixture.saved(index: 0)?.sourceText, "終了前の確定本文")
        }
    }

    @MainActor
    func testRestoredTimelineStaysHiddenUntilAnalysisValidationAndOldDigestRegenerates() async throws {
        try await withLyricFixture { store, fixture in
            let fingerprint = fixture.fingerprints[0]
            let source = "復元した本文"
            var oldAnalysis = MusicAnalysis(version: MusicAnalyzer.cacheVersion, fingerprint: fingerprint, duration: 1.9)
            oldAnalysis.vocal = (0...40).map { TimeValue(time: Double($0) * 1.9 / 40, value: 0.6) }
            oldAnalysis.phrases = [TimeSpan(start: 0, duration: 1.9)]
            oldAnalysis.sections = oldAnalysis.phrases; oldAnalysis.segments = oldAnalysis.phrases
            let oldTimeline = try LyricAligner.align(sourceText: source, analysis: oldAnalysis,
                                                    transcription: FixtureLyricTranscriber.tokens(for: source))
            let savedStore = LyricStore(directory: fixture.lyrics)
            _ = try await savedStore.saveText(url: fixture.audio[0], text: source, request: 1)
            try await savedStore.saveTimeline(oldTimeline, request: 1)

            var currentAnalysis = MusicAnalysis(version: MusicAnalyzer.cacheVersion, fingerprint: fingerprint, duration: 2)
            // Dense valid samples keep cache decoding in progress while the small lyric body restores.
            // The audio remains two seconds, and the cache remains a real MusicAnalysis value.
            currentAnalysis.vocal = (0...150_000).map { TimeValue(time: Double($0) * 2 / 150_000, value: 0.8) }
            currentAnalysis.phrases = [TimeSpan(start: 0, duration: 1), TimeSpan(start: 1, duration: 1)]
            currentAnalysis.sections = [TimeSpan(start: 0, duration: 2)]
            currentAnalysis.segments = currentAnalysis.sections
            currentAnalysis.bars = [0, 1]
            currentAnalysis.beats = (0...7).map { Double($0) / 4 }
            let expectedDigest = try LyricAligner.analysisDigest(currentAnalysis)
            XCTAssertNotEqual(oldTimeline.analysisDigest, expectedDigest)
            try JSONEncoder().encode(currentAnalysis).write(to: fixture.analysisFile(index: 0), options: .atomic)

            var observedBodyBeforeAnalysis = false
            var displayedOldDigest = false
            store.visualSource.observeFrames {
                if store.lyricText == source, store.analysis == nil {
                    observedBodyBeforeAnalysis = true
                    XCTAssertNil(store.lyricTimeline, "解析未到着の保存候補を描画用timelineへ公開しないこと")
                }
                if store.lyricTimeline?.analysisDigest == oldTimeline.analysisDigest { displayedOldDigest = true }
            }
            defer { store.visualSource.observeFrames {} }
            store.select(0, autoplay: false)
            XCTAssertNil(store.analysis)
            XCTAssertNil(store.lyricTimeline)
            try await self.waitUntil("本文が解析到着前に復元された状態を実際に観測すること") {
                observedBodyBeforeAnalysis
            }
            try await self.waitUntil("古いdigestを破棄し、本文を保持して現解析のtimelineを生成・保存すること", timeout: .seconds(8)) {
                let saved = try fixture.saved(index: 0)
                return store.lyricText == source && store.lyricTimeline?.analysisDigest == expectedDigest &&
                    saved?.sourceText == source && saved?.timeline?.analysisDigest == expectedDigest
            }
            XCTAssertFalse(displayedOldDigest, "保存結果を現解析のdigest検査前に一度も表示しないこと")
            XCTAssertEqual(store.lyricTimeline?.sourceText, source)
            XCTAssertEqual(store.lyricTimeline?.analysisVersion, MusicAnalyzer.cacheVersion)
        }
    }

    @MainActor
    func testFailedDeleteStaysClearedWhenTrackIsSelectedAgainAndRetryDeletesFile() async throws {
        guard geteuid() != 0 else { throw XCTSkip("管理者特権では削除権限の失敗を検証できません") }
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("削除再選択テストの音源確認が完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            store.applyLyrics("削除前の本文")
            try await self.waitUntil("削除前の本文とtimelineを保存し終えること") {
                (try fixture.saved(index: 0))?.timeline != nil
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.lyrics.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lyrics.path) }
            store.clearLyrics()
            try await self.waitUntil("削除失敗の確定要求を保持すること") { store.hasPendingLyricSaveFailure }
            XCTAssertEqual(store.lyricText, "")
            store.select(1, autoplay: false)
            try await self.waitUntil("削除要求を保持したまま別曲の確認を終えること") {
                store.lyricFingerprint == fixture.fingerprints[1]
            }
            store.select(0, autoplay: false)
            try await self.waitUntil("元曲を再選択しても削除済みの画面状態を保持すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.lyricTimingState == .unset
            }
            XCTAssertEqual(store.lyricText, "")
            XCTAssertNil(store.lyricTimeline)
            XCTAssertTrue(store.hasPendingLyricSaveFailure)
            XCTAssertEqual(try fixture.saved(index: 0)?.sourceText, "削除前の本文",
                           "ディスクの旧本文が残っていても確定削除を画面へ優先すること")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lyrics.path)
            store.retryLyricSave()
            try await self.waitUntil("削除の再試行と現在曲への反映を完了すること") {
                (try fixture.saved(index: 0)) == nil && !store.needsLyricSaveBeforeTermination
            }
            XCTAssertEqual(store.lyricText, "")
            XCTAssertNil(store.lyricTimeline)
            XCTAssertEqual(store.lyricTimingState, .unset)
            XCTAssertNil(store.lyricSaveError)
        }
    }

    @MainActor
    func testUnwrittenConfirmedTextSurvivesTrackReselectionAndRetry() async throws {
        guard geteuid() != 0 else { throw XCTSkip("管理者特権では保存権限の失敗を検証できません") }
        try await withLyricFixture { store, fixture in
            store.select(0, autoplay: false)
            try await self.waitUntil("未保存本文の再選択テストの音源確認が完了すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.analysis != nil
            }
            store.applyLyrics("保存済みの旧本文")
            try await self.waitUntil("旧本文とtimelineを保存し終えること") {
                (try fixture.saved(index: 0))?.timeline != nil
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.lyrics.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lyrics.path) }
            let committedText = "未保存の確定本文"
            store.applyLyrics(committedText)
            try await self.waitUntil("新しい確定本文の保存失敗と生成結果を保持すること") {
                store.hasPendingLyricSaveFailure && store.lyricTimeline?.sourceText == committedText
            }
            XCTAssertEqual(try fixture.saved(index: 0)?.sourceText, "保存済みの旧本文")
            store.select(1, autoplay: false)
            try await self.waitUntil("本文保存要求を保持したまま別曲へ切り替えること") {
                store.lyricFingerprint == fixture.fingerprints[1]
            }
            store.select(0, autoplay: false)
            try await self.waitUntil("再選択した元曲へ未保存の確定本文を復元すること") {
                store.lyricFingerprint == fixture.fingerprints[0] && store.lyricText == committedText &&
                    store.lyricTimeline?.sourceText == committedText
            }
            XCTAssertTrue(store.hasPendingLyricSaveFailure)
            XCTAssertEqual(try fixture.saved(index: 0)?.sourceText, "保存済みの旧本文")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.lyrics.path)
            store.retryLyricSave()
            try await self.waitUntil("確定本文の再試行後も同じ本文を表示し、ディスク保存を完了すること") {
                (try fixture.saved(index: 0))?.sourceText == committedText && !store.needsLyricSaveBeforeTermination
            }
            XCTAssertEqual(store.lyricText, committedText)
            XCTAssertEqual(store.lyricTimeline?.sourceText, committedText)
            XCTAssertNil(store.lyricSaveError)
        }
    }

    @MainActor
    private func withLyricFixture(sameAudio: Bool = false,
                                  lyricTranscriber: any LyricTranscribing = FixtureLyricTranscriber(),
                                  operation: (PlayerStore, LyricTransitionFixture) async throws -> Void) async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MusicPrayerLyricTransition-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let first = try writeTone(to: directory.appendingPathComponent("first.wav"), sampleRate: 44_100, channels: 1)
        let second: URL
        if sameAudio {
            second = directory.appendingPathComponent("same-audio.wav")
            try manager.copyItem(at: first, to: second)
        } else {
            second = try writeTone(to: directory.appendingPathComponent("second.wav"), sampleRate: 48_000, channels: 2)
        }
        let fixture = try LyricTransitionFixture(directory: directory, audio: [first, second])
        let store = PlayerStore(lyricDirectory: fixture.lyrics, lyricTranscriber: lyricTranscriber)
        store.volume = 0
        store.tracks = [Track(url: first), Track(url: second)]
        var operationError: Error?
        do { try await operation(store, fixture) }
        catch { operationError = error }
        // No current track means a late body-save callback cannot start recognition during cleanup.
        store.tracks = []
        store.shutdown()
        if let fixtureTranscriber = lyricTranscriber as? FixtureLyricTranscriber {
            await fixtureTranscriber.releaseAll()
        }
        _ = await store.finishLyricsBeforeTermination()
        do { try fixture.restore() }
        catch {
            XCTFail("歌詞テスト前の保存内容を戻せませんでした: \(error.localizedDescription)")
            if operationError == nil { operationError = error }
        }
        if let operationError { throw operationError }
    }

    @MainActor
    private func waitUntil(_ message: String, timeout: Duration = .seconds(3),
                           condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(try condition()) {
            guard clock.now < deadline else {
                XCTFail(message)
                throw LyricTransitionWaitError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func waitUntilAsync(_ message: String, timeout: Duration = .seconds(3),
                               condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(try await condition()) {
            guard clock.now < deadline else {
                XCTFail(message)
                throw LyricTransitionWaitError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
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

/// Lifecycle fixtures supply exact text ranges rather than asking Speech to
/// recognize arbitrary lyrics from the pure tone used by the playback tests.
private actor FixtureLyricTranscriber: LyricTranscribing {
    private let heldSources: Set<String>
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var completedSources: Set<String> = []
    private var stoppedHolding = false
    private(set) var callCount = 0

    init(heldSources: Set<String> = []) { self.heldSources = heldSources }

    func transcribe(audioURL: URL, sourceText: String,
                    status: @escaping @Sendable (LyricTimingState) async -> Void) async throws -> [RecognizedLyricToken] {
        callCount += 1
        await status(.preparingRecognition)
        await status(.recognizing)
        if heldSources.contains(sourceText), !stoppedHolding {
            await withCheckedContinuation { continuation in
                waiting[sourceText, default: []].append(continuation)
            }
        }
        // Deliberately send a late notification after cancellation, then return
        // a usable old result. PlayerStore must reject both of these itself.
        if Task.isCancelled { await status(.failed) }
        completedSources.insert(sourceText)
        return Self.tokens(for: sourceText)
    }

    func isHeld(_ source: String) -> Bool { !(waiting[source]?.isEmpty ?? true) }
    func hasCompleted(_ source: String) -> Bool { completedSources.contains(source) }

    func release(_ source: String) {
        let continuations = waiting.removeValue(forKey: source) ?? []
        for continuation in continuations { continuation.resume() }
    }

    func releaseAll() {
        stoppedHolding = true
        let continuations = waiting.values.flatMap { $0 }
        waiting.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    static func tokens(for source: String) -> [RecognizedLyricToken] {
        let lines = LyricParser.parse(source)
        guard !lines.isEmpty else { return [] }
        let lineDuration = 1.8 / Double(lines.count)
        return lines.flatMap { line in
            let characters = line.text.filter { LyricParser.characterWeight($0) > 0 }
            guard !characters.isEmpty else { return [RecognizedLyricToken]() }
            let characterDuration = lineDuration / Double(characters.count)
            let lineStart = 0.1 + Double(line.ordinal) * lineDuration
            return characters.enumerated().map { index, character in
                RecognizedLyricToken(text: String(character),
                                     start: lineStart + Double(index) * characterDuration,
                                     end: min(1.9, lineStart + Double(index + 1) * characterDuration),
                                     confidence: 1)
            }
        }
    }
}

private enum LyricTransitionWaitError: Error { case timeout }

private struct LyricTransitionFixture {
    let directory: URL
    let lyrics: URL
    let audio: [URL]
    let fingerprints: [String]
    private let backups: [FileBackup]

    init(directory: URL, audio: [URL]) throws {
        self.directory = directory
        self.audio = audio
        lyrics = directory.appendingPathComponent("Lyrics", isDirectory: true)
        fingerprints = try audio.map { url in
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/Analysis", isDirectory: true)
        let uniqueHashes = Array(Set(fingerprints)).sorted()
        let cacheFiles = uniqueHashes.map { cacheDirectory.appendingPathComponent("\($0).json") }
        backups = try ([QueuePersistence.file] + cacheFiles).map(FileBackup.init)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            for (fingerprint, file) in zip(uniqueHashes, cacheFiles) {
                var analysis = MusicAnalysis(version: MusicAnalyzer.cacheVersion, fingerprint: fingerprint, duration: 2)
                analysis.vocal = (0...40).map { TimeValue(time: Double($0) / 20, value: 0.8) }
                analysis.phrases = [TimeSpan(start: 0, duration: 1), TimeSpan(start: 1, duration: 1)]
                analysis.segments = [TimeSpan(start: 0, duration: 2)]
                analysis.sections = [TimeSpan(start: 0, duration: 2)]
                analysis.bars = [0, 1]
                analysis.beats = (0...7).map { Double($0) / 4 }
                try JSONEncoder().encode(analysis).write(to: file, options: .atomic)
            }
        } catch {
            for backup in backups { try? backup.restore() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func saved(index: Int) throws -> SavedLyrics? {
        let file = lyrics.appendingPathComponent("\(fingerprints[index]).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(SavedLyrics.self, from: Data(contentsOf: file))
    }

    func analysisFile(index: Int) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/Analysis", isDirectory: true)
            .appendingPathComponent("\(fingerprints[index]).json")
    }

    func restore() throws {
        var failure: Error?
        for backup in backups {
            do { try backup.restore() }
            catch { failure = error }
        }
        do { try FileManager.default.removeItem(at: directory) }
        catch { failure = error }
        if let failure { throw failure }
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
