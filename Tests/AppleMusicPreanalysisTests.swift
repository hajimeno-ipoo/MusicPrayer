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

    func testDoesNotStartUntilAllowedAndDeduplicatesRegistrations() async throws {
        let queue = AppleMusicPreanalysis()
        var started: [String] = []
        queue.operation = { started.append($0.id) }
        queue.setSongs([song("first"), song("first")])
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(started.isEmpty)
        XCTAssertFalse(queue.isWorking)
        queue.setAllowed(true)
        try await waitUntil("登録曲の解析が完了しませんでした") { started == ["first"] && !queue.isWorking }
        XCTAssertEqual(queue.status(for: song("first")), "解析済み")
        await queue.yieldToPlayback()
    }

    func testTwoSongsRunTogetherAndThirdWaitsForAFreeWorker() async throws {
        let queue = AppleMusicPreanalysis()
        let gates = ["first": Gate(), "second": Gate(), "third": Gate()]
        var starts: [String] = [], active = 0, maximumActive = 0
        queue.operation = { song in
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            starts.append(song.id)
            queue.update(songID: song.id, phase: .capturing, position: song.id == "second" ? 45 : 30)
            await gates[song.id]?.wait()
        }
        defer { gates.values.forEach { $0.open() }; queue.setAllowed(false) }
        queue.setSongs([song("first"), song("second"), song("third")]); queue.setAllowed(true)
        try await waitUntil("2曲の解析が同時に始まりませんでした") { starts.count == 2 }
        XCTAssertEqual(Set(starts), ["first", "second"])
        XCTAssertEqual(queue.progress(for: song("first")), 0.5)
        XCTAssertEqual(queue.progress(for: song("second")), 0.75)
        XCTAssertEqual(queue.status(for: song("third")), "解析待ち")
        XCTAssertNil(queue.progress(for: song("third")))
        queue.setSongs([song("first"), song("second"), song("third"), song("first")])
        gates["first"]?.open()
        try await waitUntil("空いたworkerで3曲目が始まりませんでした") { starts.count == 3 }
        XCTAssertEqual(queue.status(for: song("first")), "解析済み")
        XCTAssertEqual(queue.progress(for: song("second")), 0.75, "別曲の完了で進行中の曲をリセットしない")
        XCTAssertEqual(maximumActive, 2)
        gates.values.forEach { $0.open() }
        try await waitUntil("全曲の解析が完了しませんでした") { !queue.isWorking }
        XCTAssertTrue(queue.errors.isEmpty)
    }

    func testRegisteringAnotherSongKeepsTheFirstJobAndItsProgress() async throws {
        let queue = AppleMusicPreanalysis(), gate = Gate()
        var starts: [String] = [], cancelled: [String] = []
        queue.operation = { song in
            starts.append(song.id)
            queue.update(songID: song.id, phase: .capturing, position: 20)
            await gate.wait()
            if Task.isCancelled { cancelled.append(song.id) }
        }
        defer { gate.open(); queue.setAllowed(false) }
        queue.setSongs([song("first")]); queue.setAllowed(true)
        try await waitUntil("最初の解析が始まりませんでした") { starts == ["first"] }
        queue.setSongs([song("first"), song("second")])
        try await waitUntil("追加した曲が並行して解析されませんでした") { starts == ["first", "second"] }
        XCTAssertEqual(queue.progress(for: song("first")) ?? -1, 1.0 / 3, accuracy: 0.000001)
        queue.setSongs([song("first"), song("second"), song("second")])
        for _ in 0..<5 { queue.setAllowed(true); await Task.yield() }
        XCTAssertEqual(starts, ["first", "second"])
        gate.open()
        try await waitUntil("解析が完了しませんでした") { !queue.isWorking }
        XCTAssertTrue(cancelled.isEmpty)
    }

    func testRemovingOneSongWaitsForItsCleanupWithoutCancellingTheOtherSong() async throws {
        let queue = AppleMusicPreanalysis(), keptGate = Gate(), cleanupGate = Gate()
        var starts: [String] = [], cleaning = false, keptCancelled = false
        queue.operation = { song in
            starts.append(song.id)
            if song.id == "removed" {
                do { try await self.remainUntilCancelled() }
                catch { cleaning = true; await cleanupGate.wait(); throw error }
            } else if song.id == "kept" {
                queue.update(songID: song.id, phase: .capturing, position: 36)
                await keptGate.wait()
                keptCancelled = Task.isCancelled
            }
        }
        defer { keptGate.open(); cleanupGate.open(); queue.setAllowed(false) }
        queue.setSongs([song("removed"), song("kept")]); queue.setAllowed(true)
        try await waitUntil("2曲が始まりませんでした") { starts.count == 2 }
        queue.setSongs([song("kept"), song("new")])
        try await waitUntil("削除曲の後片付けが始まりませんでした") { cleaning }
        XCTAssertEqual(starts.count, 2, "後片付け中のworkerも同時実行数へ数える")
        XCTAssertEqual(queue.progress(for: song("kept")), 0.6)
        cleanupGate.open()
        try await waitUntil("削除曲の片付け後に新しい曲が始まりませんでした") { starts.contains("new") }
        keptGate.open()
        try await waitUntil("残した曲が完了しませんでした") { !queue.isWorking }
        XCTAssertFalse(keptCancelled)
        XCTAssertNil(queue.errors["removed"])
        XCTAssertEqual(queue.status(for: song("kept")), "解析済み")
    }

    func testRemovedAndReaddedSongRejectsOldCompletionAndLateProgress() async throws {
        let queue = AppleMusicPreanalysis(), cleanupGate = Gate(), newGate = Gate(), lateGate = Gate()
        var attempts = 0, cleaning = false
        var lateUpdate: Task<Void, Never>?
        queue.operation = { song in
            attempts += 1
            if attempts == 1 {
                lateUpdate = Task { @MainActor in
                    await lateGate.wait()
                    queue.update(songID: song.id, phase: .capturing, position: 59)
                }
                do { try await self.remainUntilCancelled() }
                catch {
                    cleaning = true
                    await cleanupGate.wait()
                    queue.update(songID: song.id, phase: .analyzing, position: 60)
                }
            } else {
                queue.update(songID: song.id, phase: .capturing, position: 15)
                await newGate.wait()
            }
        }
        defer { cleanupGate.open(); newGate.open(); lateGate.open(); queue.setAllowed(false) }
        queue.setSongs([song("same")]); queue.setAllowed(true)
        try await waitUntil("最初の解析が始まりませんでした") { attempts == 1 }
        queue.setSongs([])
        queue.setSongs([song("same")])
        try await waitUntil("削除した解析の後片付けが始まりませんでした") { cleaning }
        XCTAssertEqual(queue.status(for: song("same")), "解析待ち")
        cleanupGate.open()
        try await waitUntil("再追加した曲が新しいjobで始まりませんでした") { attempts == 2 }
        XCTAssertEqual(queue.status(for: song("same")), "解析中")
        XCTAssertEqual(queue.progress(for: song("same")), 0.25)
        lateGate.open()
        await lateUpdate?.value
        XCTAssertEqual(queue.progress(for: song("same")), 0.25, "古いworkerの通知が新しい進捗を上書きしない")
        XCTAssertTrue(queue.errors.isEmpty)
        newGate.open()
        try await waitUntil("新しいjobが完了しませんでした") { !queue.isWorking }
        XCTAssertEqual(queue.status(for: song("same")), "解析済み")
    }

    func testProgressPhasesStayPerSongAndUnrelatedCallbacksAreIgnored() async throws {
        let queue = AppleMusicPreanalysis(), gate = Gate(), phaseGate = Gate()
        queue.operation = { song in
            queue.update(songID: song.id, phase: .capturing, position: song.id == "first" ? 30 : 12)
            queue.update(songID: song.id == "first" ? "second" : "first", phase: .capturing, position: 59)
            await phaseGate.wait()
            if song.id == "first" { queue.update(songID: song.id, phase: .analyzing, position: 60) }
            await gate.wait()
        }
        defer { gate.open(); phaseGate.open(); queue.setAllowed(false) }
        queue.setSongs([song("first"), song("second")]); queue.setAllowed(true)
        try await waitUntil("曲ごとの進捗が届きませんでした") { queue.progress(for: self.song("first")) == 0.5 && queue.progress(for: self.song("second")) == 0.2 }
        queue.update(songID: "first", phase: .capturing, position: 59)
        XCTAssertEqual(queue.progress(for: song("first")), 0.5, "workerの実行文脈を持たない通知を受理しない")
        phaseGate.open()
        try await waitUntil("仕上げ状態へ進みませんでした") { queue.status(for: self.song("first")) == "解析を仕上げています" }
        XCTAssertNil(queue.progress(for: song("first")))
        XCTAssertEqual(queue.status(for: song("second")), "解析中")
        XCTAssertEqual(queue.progress(for: song("second")), 0.2)
        gate.open()
        try await waitUntil("解析が完了しませんでした") { !queue.isWorking }
    }

    func testShutdownCancelsAllJobsAndWaitsForAllCleanup() async throws {
        let queue = AppleMusicPreanalysis()
        let cleanupGates = ["first": Gate(), "second": Gate()]
        var starts: [String] = [], cleaning: Set<String> = [], stopped = false
        queue.operation = { song in
            starts.append(song.id)
            do { try await self.remainUntilCancelled() }
            catch {
                cleaning.insert(song.id)
                await cleanupGates[song.id]?.wait()
                throw error
            }
        }
        defer { cleanupGates.values.forEach { $0.open() }; queue.setAllowed(false) }
        queue.setSongs([song("first"), song("second"), song("third")]); queue.setAllowed(true)
        try await waitUntil("2曲の解析が始まりませんでした") { starts.count == 2 }
        let shutdown = Task { @MainActor in await queue.yieldToPlayback(); stopped = true }
        try await waitUntil("両方の後片付けが始まりませんでした") { cleaning.count == 2 }
        XCTAssertFalse(stopped)
        queue.setAllowed(true)
        cleanupGates["first"]?.open()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(stopped, "もう一方の後片付けも待つ")
        XCTAssertTrue(queue.isWorking)
        cleanupGates["second"]?.open()
        await shutdown.value
        XCTAssertFalse(queue.isWorking)
        XCTAssertEqual(Set(starts), ["first", "second"], "終了待機中に新しいjobを開始しない")
        XCTAssertTrue(queue.errors.isEmpty)
        XCTAssertEqual(queue.status(for: song("first")), "解析待ち")
    }

    func testCompletedAndFailedSongsAreNotRetriedUntilRemovedAndReadded() async throws {
        let queue = AppleMusicPreanalysis()
        var attempts: [String] = []
        queue.operation = { song in
            attempts.append(song.id)
            if song.id == "failed" { throw TestFailure.analysis }
        }
        queue.setSongs([song("failed"), song("completed")]); queue.setAllowed(true)
        try await waitUntil("解析結果が確定しませんでした") { attempts.count == 2 && !queue.isWorking }
        XCTAssertNotNil(queue.errors["failed"])
        XCTAssertEqual(queue.status(for: song("failed")), "事前解析に失敗しました")
        XCTAssertEqual(queue.status(for: song("completed")), "解析済み")
        for _ in 0..<60 {
            queue.setAllowed(true)
            queue.setSongs([song("failed"), song("completed"), song("failed")])
            await Task.yield()
        }
        XCTAssertEqual(attempts.count, 2)
        queue.setSongs([song("completed")])
        XCTAssertNil(queue.errors["failed"])
        queue.setSongs([song("completed"), song("failed")])
        try await waitUntil("再追加した曲の新しい解析が始まりませんでした") { attempts.count == 3 && !queue.isWorking }
        XCTAssertEqual(attempts.filter { $0 == "failed" }.count, 2)
        XCTAssertEqual(attempts.filter { $0 == "completed" }.count, 1)
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
