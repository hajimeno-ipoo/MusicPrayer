import AppKit
import WebKit
import XCTest
@testable import MusicPrayer

final class AppleMusicPlaybackPolicyTests: XCTestCase {
    @MainActor
    func testNativePlayerConnectionCanStartAudioWithoutClickingWebPage() async throws {
        _ = NSApplication.shared
        let store = AppleMusicStore()
        let view = store.webViewForDisplay()
        view.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil); window.contentView = nil }
        // Local selection pauses the connection; the old Apple selection path paused it again.
        await store.suspendPlayback()
        await store.suspendPlayback()
        await store.allowPlayback()
        // A real silent WAV keeps this test inaudible without using muted-media autoplay exemptions.
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
        }
        let bytes: UInt32 = 16_000
        text("RIFF"); number(bytes + 36); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(8_000)); number(UInt32(16_000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(bytes)
        wav.append(Data(repeating: 0, count: Int(bytes)))
        view.loadHTMLString("""
        <audio id="audio" src="data:audio/wav;base64,\(wav.base64EncodedString())"></audio>
        <script>
        window.playResult = 'waiting';
        setTimeout(() => document.getElementById('audio').play().then(
            () => window.playResult = 'playing', error => window.playResult = error.name), 100);
        </script>
        """, baseURL: nil)
        var result = "waiting"
        for _ in 0..<100 {
            result = (try? await view.evaluateJavaScript("window.playResult") as? String) ?? "waiting"
            if result != "waiting" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(result, "playing", "ネイティブの再生操作と曲末移動にはWebページ内のクリックを要求しない")
    }
    @MainActor
    func testCachedPreanalysisUsesExistingConnectionWithoutStartingMedia() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = AppleMusicSong(id: "123", title: "Cached", artist: "", album: "", duration: 60)
        let seed = AppleMusicAnalysisCache(directory: directory)
        try await seed.retainSongs([song.id])
        let ticketValue = await seed.ticket(for: song.id)
        let ticket = try XCTUnwrap(ticketValue)
        try await seed.save(MusicAnalysis(fingerprint: "appleMusic:123", duration: 60, beats: [1, 2], bpm: 120), id: song.id, ticket: ticket)
        let store = AppleMusicStore(analysisDirectory: directory)
        store.setQueueSongs([song])
        let view = store.webViewForDisplay()
        view.stopLoading()
        defer { store.stop() }
        view.loadHTMLString("""
        <script>
        window.playCalls=0;
        window.MusicKit={getInstance:()=>window.player};
        window.player={isAuthorized:true,isPlaying:false,volume:0.75,currentPlaybackTime:8,
            currentPlaybackDuration:60,nowPlayingItem:{id:'999',title:'Selected'},
            setQueue:async()=>{window.playCalls++},play:async()=>{window.playCalls++}};
        </script>
        """, baseURL: URL(string: "https://music.apple.com/"))
        for _ in 0..<100 {
            store.pollPlayback()
            if store.playback.isReady { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.playback.isReady)
        _ = try await view.evaluateJavaScript("window.player.isPlaying=true")
        for _ in 0..<100 {
            store.pollPlayback()
            if store.playback.isPlaying { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.playback.isPlaying)
        store.setPreanalysisAllowed(true)
        XCTAssertFalse(store.preanalysis.isWorking, "UIの再生表示の更新前でも、実際のApple Musicが再生中なら事前解析を始めない")
        _ = try await view.evaluateJavaScript("window.player.isPlaying=false")
        for _ in 0..<100 {
            store.pollPlayback()
            if !store.playback.isPlaying { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.playback.isPlaying)
        let previous = store.playback
        store.setPreanalysisAllowed(true)
        XCTAssertTrue(store.preanalysis.isWorking)
        for _ in 0..<100 {
            if !store.preanalysis.isWorking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.preanalysis.isWorking)
        XCTAssertTrue(store.preanalysis.errors.isEmpty)
        XCTAssertEqual(store.playback, previous)
        XCTAssertTrue(store.webViewForDisplay() === view)
        let calls = try await view.evaluateJavaScript("window.playCalls") as? Int
        XCTAssertEqual(calls, 0, "保存済みの結果がある曲は、接続を使い回し、内部再生も始めない")
        let reused = await store.musicAnalysis.loadSavedAnalysis(for: song)
        XCTAssertTrue(reused)
        XCTAssertEqual(store.musicAnalysis.analysis?.beats, [1, 2])
        await store.finishStorageBeforeTermination()
    }

}
