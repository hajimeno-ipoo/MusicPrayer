import XCTest
@testable import MusicPrayer

@MainActor
final class AppleMusicPreanalysisTests: XCTestCase {
    private func song(_ id: String) -> AppleMusicSong {
        AppleMusicSong(id: id, title: id, artist: "", album: "", duration: 60)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
        throw TestFailure.timeout
    }

    private func remainUntilCancelled() async throws {
        while true { try await Task.sleep(for: .seconds(30)) }
    }

    func testDoesNotStartUntilBackgroundWorkIsAllowed() async throws {
        let queue = AppleMusicPreanalysis()
        var started: [String] = []
        queue.operation = { started.append($0.id) }
        queue.setSongs([song("first")])
        // Let a mistakenly scheduled task run before checking the idle-work boundary.
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(started.isEmpty)
        XCTAssertFalse(queue.isWorking)
        queue.setAllowed(true)
        try await waitUntil("許可後に事前解析が完了しませんでした") { started == ["first"] && !queue.isWorking }
        await queue.yieldToPlayback()
    }

    func testSelectingTheSongBeingAnalyzedDoesNotCancelOrRestartIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppleMusicStore(analysisDirectory: directory)
        let target = song("123456"), gate = Gate()
        var starts = 0, cancelled = false
        store.preanalysis.operation = { _ in
            starts += 1
            await gate.wait()
            cancelled = Task.isCancelled
        }
        store.setQueueSongs([target])
        store.preanalysis.setAllowed(true)
        defer { gate.open(); store.preanalysis.setAllowed(false) }
        try await waitUntil("事前解析が始まりませんでした") { store.preanalysis.songID == target.id }
        store.preanalysis.position = 45
        XCTAssertTrue(store.selectDuringPreanalysis(target))
        XCTAssertEqual(store.preanalysis.position, 45, "選曲だけで取得位置を先頭へ戻さない")
        XCTAssertEqual(store.playback.id, target.id)
        XCTAssertFalse(store.playback.isPlaying)
        XCTAssertFalse(store.selectDuringPreanalysis(song("different")))
        gate.open()
        try await waitUntil("進行中の解析が完了しませんでした") { !store.preanalysis.isWorking }
        XCTAssertFalse(cancelled)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(store.preanalysis.status(for: target), "解析済み")
        await store.finishStorageBeforeTermination()
    }

    func testActiveStatusFollowsPreparationCaptureAndFinalAnalysisWithoutMovingOtherSongs() async throws {
        let queue = AppleMusicPreanalysis(), gate = Gate()
        let active = song("active"), waiting = song("waiting")
        queue.operation = { _ in await gate.wait() }
        queue.setSongs([active, waiting]); queue.setAllowed(true)
        defer { gate.open(); queue.setAllowed(false) }
        try await waitUntil("準備中の曲が表示対象になりませんでした") { queue.songID == active.id }
        XCTAssertEqual(queue.status(for: active), "解析の準備中")
        XCTAssertNil(queue.progress(for: active))
        queue.phase = .capturing; queue.position = 30
        XCTAssertEqual(queue.progress(for: active), 0.5)
        XCTAssertEqual(queue.status(for: active), "解析中")
        XCTAssertNil(queue.progress(for: waiting), "別の曲へ進捗を表示しない")
        queue.phase = .analyzing
        XCTAssertEqual(queue.status(for: active), "解析を仕上げています")
        XCTAssertNil(queue.progress(for: active), "音声取得後の解析に架空の進捗率を表示しない")
        gate.open()
        try await waitUntil("完了状態へ変わりませんでした") { !queue.isWorking }
        XCTAssertEqual(queue.status(for: active), "解析済み")
    }

    func testSongsRunSeriallyAndDuplicateRegistrationsDoNotRunTwice() async throws {
        let queue = AppleMusicPreanalysis()
        let firstGate = Gate()
        var active = 0, maximumActive = 0
        var events: [String] = []
        queue.operation = { song in
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            events.append("start:" + song.id)
            if song.id == "first" { await firstGate.wait() }
            events.append("end:" + song.id)
        }
        defer { firstGate.open(); queue.setAllowed(false) }
        queue.setSongs([song("first"), song("second"), song("first"), song("third")])
        queue.setAllowed(true)
        try await waitUntil("最初の曲が始まりませんでした") { events == ["start:first"] }
        queue.setSongs([song("first"), song("second"), song("third"), song("second")])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(events, ["start:first"], "前の曲の完了前に次の曲を開始しない")
        firstGate.open()
        try await waitUntil("曲の列が完了しませんでした") { !queue.isWorking }
        XCTAssertEqual(events, ["start:first", "end:first", "start:second", "end:second", "start:third", "end:third"])
        XCTAssertEqual(maximumActive, 1)
        await queue.yieldToPlayback()
    }

    func testYieldWaitsForCleanupBeforeForegroundPlaybackAndCanResumeLater() async throws {
        let queue = AppleMusicPreanalysis()
        let cleanupGate = Gate()
        var events: [String] = []
        var starts = 0, foregroundReturned = false
        queue.operation = { _ in
            starts += 1
            events.append("analysis-start")
            do { try await self.remainUntilCancelled() }
            catch {
                events.append("cleanup-start")
                await cleanupGate.wait()
                events.append("cleanup-end")
                throw error
            }
        }
        defer { cleanupGate.open(); queue.setAllowed(false) }
        queue.setSongs([song("first")]); queue.setAllowed(true)
        try await waitUntil("解析が始まりませんでした") { starts == 1 }
        let foreground = Task { @MainActor in
            await queue.yieldToPlayback()
            events.append("foreground-playback")
            foregroundReturned = true
        }
        try await waitUntil("キャンセル後の片付けが始まりませんでした") { events.contains("cleanup-start") }
        XCTAssertFalse(foregroundReturned, "無音化解除などの片付けを終えるまで通常再生へ渡さない")
        XCTAssertTrue(queue.isWorking)
        cleanupGate.open()
        await foreground.value
        XCTAssertFalse(queue.isWorking)
        XCTAssertNil(queue.songID)
        XCTAssertTrue(queue.status(for: song("first")).contains("待ち"), "通常再生による中断を完了や失敗として表示しない")
        XCTAssertEqual(events, ["analysis-start", "cleanup-start", "cleanup-end", "foreground-playback"])
        // Interrupted work remains eligible when the player is idle again.
        queue.setAllowed(true)
        try await waitUntil("中断した曲を再開できませんでした") { starts == 2 }
        await queue.yieldToPlayback()
        XCTAssertTrue(queue.errors.isEmpty, "ユーザーの再生操作による中断を解析エラーにしない")
    }

    func testRemovingActiveSongCancelsItAndMovesToNextRetainedSong() async throws {
        let queue = AppleMusicPreanalysis()
        var events: [String] = []
        queue.operation = { song in
            events.append("start:" + song.id)
            if song.id == "removed" {
                do { try await self.remainUntilCancelled() }
                catch { events.append("cancel:" + song.id); throw error }
            }
            events.append("saved:" + song.id)
        }
        defer { queue.setAllowed(false) }
        queue.setSongs([song("removed"), song("kept")]); queue.setAllowed(true)
        try await waitUntil("削除対象の解析が始まりませんでした") { queue.songID == "removed" && events.contains("start:removed") }
        queue.setSongs([song("kept")])
        try await waitUntil("削除後に次の曲へ進みませんでした") { events.contains("saved:kept") && !queue.isWorking }
        XCTAssertEqual(events, ["start:removed", "cancel:removed", "start:kept", "saved:kept"])
        XCTAssertNil(queue.errors["removed"])
        await queue.yieldToPlayback()
    }

    func testFailedSongIsNotRetriedEveryTickAndRemovalAllowsFreshAttempt() async throws {
        let queue = AppleMusicPreanalysis()
        var attempts: [String] = []
        queue.operation = { song in
            attempts.append(song.id)
            if song.id == "failed" { throw TestFailure.analysis }
        }
        queue.setSongs([song("failed"), song("other")]); queue.setAllowed(true)
        try await waitUntil("失敗した曲の後に次の曲を処理できませんでした") { attempts.count == 2 && !queue.isWorking }
        XCTAssertNotNil(queue.errors["failed"])
        XCTAssertEqual(queue.status(for: song("failed")), "事前解析に失敗しました")
        XCTAssertEqual(queue.status(for: song("other")), "解析済み")
        for _ in 0..<60 {
            queue.setAllowed(true)
            queue.setSongs([song("failed"), song("other")])
            await Task.yield()
        }
        XCTAssertEqual(attempts, ["failed", "other"], "定期更新だけで同じ失敗を繰り返さない")
        queue.setSongs([song("other")])
        XCTAssertNil(queue.errors["failed"], "一覧から外した曲のエラーも破棄する")
        XCTAssertTrue(queue.status(for: song("failed")).contains("待ち"))
        queue.setSongs([song("other"), song("failed")])
        try await waitUntil("再追加した曲を処理しませんでした") { attempts.count == 3 && !queue.isWorking }
        XCTAssertEqual(attempts, ["failed", "other", "failed"])
        await queue.yieldToPlayback()
    }

    func testSuccessfulSongsRemainCompletedAcrossQueueRefreshAndIdleEligibilityChanges() async throws {
        let queue = AppleMusicPreanalysis()
        var starts: [String] = []
        queue.operation = { starts.append($0.id) }
        queue.setSongs([song("completed")]); queue.setAllowed(true)
        try await waitUntil("最初の解析が完了しませんでした") { starts == ["completed"] && !queue.isWorking }
        XCTAssertEqual(queue.status(for: song("completed")), "解析済み")
        await queue.yieldToPlayback()
        queue.setSongs([song("completed")]); queue.setAllowed(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(starts, ["completed"], "同じ一覧と再開操作で完了済みの曲を再解析しない")
        queue.setSongs([song("completed"), song("new")])
        try await waitUntil("追加した未解析曲が始まりませんでした") { starts == ["completed", "new"] && !queue.isWorking }
        queue.setSongs([song("new")]); queue.setSongs([song("new"), song("completed")])
        try await waitUntil("完了済みでも削除して再追加した曲は新しい対象になります") { starts.count == 3 && !queue.isWorking }
        XCTAssertEqual(starts, ["completed", "new", "completed"])
        await queue.yieldToPlayback()
    }
}

@MainActor
private final class Gate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        let waiting = continuations; continuations = []
        waiting.forEach { $0.resume() }
    }
}

private enum TestFailure: Error { case timeout, analysis }
