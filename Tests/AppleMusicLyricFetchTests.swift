import AppKit
import WebKit
import XCTest
@testable import MusicPrayer

@MainActor
final class AppleMusicLyricFetchTests: XCTestCase {
    func testConfirmedUnavailableLyricsShowsMessageInsteadOfAnEmptySuccess() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        _ = try await fixture.view.evaluateJavaScript("window.responseMode='unavailable'")

        let selected = await fixture.store.playSong(fixture.songs[0], autoplay: false)
        XCTAssertTrue(selected)
        try await waitUntil("未配信の説明が表示状態へ届きませんでした") {
            fixture.store.lyricTimingStatus == "この曲の歌詞はApple Musicで配信されていません。"
        }
        try await waitUntil("確認済みの配信なし結果が保存されませんでした") {
            await fixture.cache.loadLyricTiming(for: fixture.songs[0])?.completion == .noLyrics
        }

        XCTAssertNil(fixture.store.lyrics)
        XCTAssertNil(fixture.store.lyricTimingError)
        XCTAssertFalse(fixture.store.playback.isPlaying)
        let requests = try await fixture.view.evaluateJavaScript("window.lyricRequests") as? [String]
        XCTAssertEqual(requests, [fixture.songs[0].id])
    }

    func testMissingDocumentCanBeFetchedAgainWithoutMovingPlaybackOrDiscardingMusic() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        _ = try await fixture.view.evaluateJavaScript("window.responseMode='missing'")

        let selected = await fixture.store.playSong(fixture.songs[0], autoplay: false)
        XCTAssertTrue(selected)
        try await waitUntil("本文の取得失敗が表示エラーへ届きませんでした") {
            fixture.store.lyricTimingError != nil
        }
        XCTAssertNil(fixture.store.lyrics)
        XCTAssertEqual(fixture.store.lyricRetryTitle, "歌詞を再取得")
        XCTAssertTrue(fixture.store.lyricTimingError?.contains("歌詞データを取得できませんでした") == true)

        _ = try await fixture.view.evaluateJavaScript("window.player.currentPlaybackTime=17.25;window.responseMode='native'")
        try await waitUntil("再生位置が読み取れませんでした") {
            fixture.store.pollPlayback()
            return fixture.store.playback.time == 17.25
        }
        fixture.store.retryLyricTiming()
        try await waitUntil("再取得した歌詞が表示状態へ届きませんでした") {
            fixture.store.lyrics?.songID == fixture.songs[0].id &&
                fixture.store.lyrics?.lines.first?.hasValidCharacterTimings == true &&
                fixture.store.lyricTimingError == nil
        }
        try await waitUntil("再取得した公式の文字時刻が完了結果として保存されませんでした") {
            await fixture.cache.loadLyricTiming(for: fixture.songs[0])?.completion == .complete
        }

        XCTAssertEqual(fixture.store.lyrics?.text, "取得した歌詞")
        XCTAssertNil(fixture.store.lyricTimingStatus)
        XCTAssertEqual(fixture.store.playback.time, 17.25)
        XCTAssertFalse(fixture.store.playback.isPlaying)
        let requests = try await fixture.view.evaluateJavaScript("window.lyricRequests") as? [String]
        XCTAssertEqual(requests, [fixture.songs[0].id, fixture.songs[0].id], "再取得ボタン一回で一回だけ取得する")
        let pageTime = try await fixture.view.evaluateJavaScript("window.player.currentPlaybackTime") as? Double
        XCTAssertEqual(pageTime, 17.25)
        let music = await fixture.cache.load(id: fixture.songs[0].id, duration: 60)
        XCTAssertEqual(music?.fingerprint, "appleMusic:" + fixture.songs[0].id)
        XCTAssertEqual(music?.beats, [1, 2])
        XCTAssertEqual(music?.bpm, 120)
    }

    func testPreviousSongsDelayedFailureDoesNotReplaceNewSongsLyrics() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        _ = try await fixture.view.evaluateJavaScript("window.responseMode='delayed'")
        let firstSelected = await fixture.store.playSong(fixture.songs[0], autoplay: false)
        XCTAssertTrue(firstSelected)
        try await waitUntil("古い曲のリクエストが始まりませんでした") {
            (try await fixture.view.evaluateJavaScript("typeof window.rejectFirstLyrics==='function'")) as? Bool == true
        }

        let nextSelected = await fixture.store.playSong(fixture.songs[1], autoplay: false)
        XCTAssertTrue(nextSelected)
        try await waitUntil("新しい曲の歌詞が取得されませんでした") {
            fixture.store.lyrics?.songID == fixture.songs[1].id
        }
        _ = try await fixture.view.callAsyncJavaScript("""
        window.rejectFirstLyrics(new Error('old request failed'));
        await window.firstRequestSettled;
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        await Task.yield()

        XCTAssertEqual(fixture.store.lyrics?.songID, fixture.songs[1].id)
        XCTAssertEqual(fixture.store.lyrics?.text, "取得した歌詞")
        XCTAssertNil(fixture.store.lyricTimingError)
        XCTAssertNil(fixture.store.lyricTimingStatus)
        XCTAssertEqual(fixture.store.playback.id, fixture.songs[1].id)
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let songs: [AppleMusicSong]
        let cache: AppleMusicAnalysisCache
        let store: AppleMusicStore
        let view: WKWebView
        let window: NSWindow

        func close() {
            store.stop()
            window.orderOut(nil)
            window.contentView = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let songs = ["101", "202"].map {
            AppleMusicSong(id: $0, title: "Test " + $0, artist: "", album: "", duration: 60)
        }
        let cache = AppleMusicAnalysisCache(directory: directory)
        try await cache.retainSongs(Set(songs.map(\.id)))
        for song in songs {
            let issued = await cache.ticket(for: song.id)
            let ticket = try XCTUnwrap(issued)
            try await cache.save(MusicAnalysis(fingerprint: "appleMusic:" + song.id, duration: 60,
                beats: [1, 2], bpm: 120), id: song.id, ticket: ticket)
        }
        let store = AppleMusicStore(analysisDirectory: directory, websiteDataStore: .nonPersistent(), usesAnalysisWorkers: false)
        store.setQueueSongs(songs)
        await store.musicAnalysis.queueRegistration?.value
        let view = store.webViewForDisplay()
        view.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        let fixture = Fixture(directory: directory, songs: songs, cache: cache, store: store, view: view, window: window)
        view.loadHTMLString("""
        <script>
        window.lyricRequests=[];
        window.responseMode='native';
        window.nativeTTML='<tt xml:lang="ja"><body><p begin="1s" end="5s"><span begin="1s" end="4s">取得した歌詞</span></p></body></tt>';
        window.player={
            storefrontId:'jp',isAuthorized:true,isPlaying:false,volume:0.4,
            currentPlaybackTime:0,currentPlaybackDuration:60,
            nowPlayingItem:null,queue:{nextPlayableItem:null,previousPlayableItem:null},
            setQueue:async function(value){this.nowPlayingItem={id:value.song,title:'Test '+value.song};this.currentPlaybackTime=0;},
            play:async function(){throw new Error('Tests must stay paused');},
            pause:async function(){this.isPlaying=false;},
            stop:async function(){this.isPlaying=false;},
            seekToTime:async function(value){this.currentPlaybackTime=value;},
            api:{music:async function(path){
                const id=path.split('/').pop();
                window.lyricRequests.push(id);
                if(window.responseMode==='delayed' && id==='101'){
                    const request=new Promise((resolve,reject)=>{window.rejectFirstLyrics=reject;});
                    window.firstRequestSettled=request.then(()=>true,()=>true);
                    return request;
                }
                const hasLyrics=window.responseMode!=='unavailable';
                const lyricData=(window.responseMode==='native' || window.responseMode==='delayed')
                    ? [{id:id,type:'lyrics',attributes:{ttml:window.nativeTTML}}] : [];
                return {data:{data:[{id:id,type:'songs',attributes:{hasLyrics:hasLyrics},relationships:{lyrics:{data:lyricData}}}]}};
            }}
        };
        window.MusicKit={getInstance:()=>window.player};
        window.fixtureReady=true;
        </script>
        """, baseURL: URL(string: "https://music.apple.com/"))
        do {
            try await waitUntil("ローカルの歌詞取得テストページが準備されませんでした") {
                (try? await view.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true
            }
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private func waitUntil(_ message: String, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
        throw FixtureError.timeout
    }

    private enum FixtureError: Error { case timeout }
}
