import AppKit
import WebKit
import XCTest
@testable import MusicPrayer

final class AppleMusicPlaybackPolicyTests: XCTestCase {
    @MainActor
    func testOfficialBrowserSurfacesFollowLightAndDarkAppearanceWithoutChangingArtwork() async throws {
        _ = NSApplication.shared
        let store = AppleMusicStore(websiteDataStore: .nonPersistent(), usesAnalysisWorkers: false, isOfficialBrowser: true)
        let view = store.webViewForDisplay()
        view.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil); window.contentView = nil }
        view.loadHTMLString("""
        <html><head><style>
        html { --pageBG:#fff }
        .scrollable-page { background-color:var(--pageBG) }
        .navigation { background:#fafafa }
        .side-panel { background:rgb(90,80,70) }
        .library-track--header, .artist-detail-container { background:var(--pageBG) }
        .artist-selection { background:rgb(221,31,52); color:white }
        @media(prefers-color-scheme:dark) { html { --pageBG:#1f1f1f } }
        .artwork{background-color:rgb(200,100,50)}
        </style></head>
        <body><div class="app-container"><main class="scrollable-page"><div class="artwork">ジャケット</div><button>再生</button></main>
        <nav class="navigation">ライブラリ</nav><aside class="side-panel">右パネル</aside>
        <div class="library-track--header"><span role="columnheader">名前</span></div>
        <div class="artist-detail-container"><h2>Alisa</h2><img alt="ジャケット"></div>
        <div class="artist-selection">Alisa</div></div></body></html>
        """, baseURL: URL(string: "https://music.apple.com/"))
        for (appearance, expected) in [(NSAppearance.Name.aqua, 255), (.darkAqua, 31)] {
            window.appearance = NSAppearance(named: appearance)
            view.appearance = NSAppearance(named: appearance)
            var background: [Int]?
            for _ in 0..<100 {
                background = try? await backgroundRGBA(view)
                if background?.first == expected, background?.last == 204 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            for component in (background ?? []).prefix(3) { XCTAssertEqual(component, expected, accuracy: 1) }
            XCTAssertEqual(background?.count, 4)
            XCTAssertEqual(background?.last, 204)
            XCTAssertEqual(view.value(forKey: "drawsBackground") as? Bool, false)
            let filter = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.scrollable-page')).backdropFilter") as? String
            XCTAssertEqual(filter, "none")
            let navigation = try await backgroundRGBA(view, selector: ".navigation")
            XCTAssertEqual(navigation.count, 4)
            XCTAssertEqual(navigation, [250, 250, 250, 255], "左ナビゲーションも公式の背景を保つ")
            let sidePanel = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.side-panel')).backgroundColor") as? String
            XCTAssertEqual(sidePanel, "rgb(90, 80, 70)", "別要素である右パネルの配色は変更しない")
            for selector in [".library-track--header", ".artist-detail-container"] {
                let fill = try await backgroundRGBA(view, selector: selector)
                XCTAssertEqual(fill.last, 0, "ライブラリの見出しと詳細も共通の半透明背景を使う")
            }
            let selection = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.artist-selection')).backgroundColor") as? String
            XCTAssertEqual(selection, "rgb(221, 31, 52)", "選択中アーティストの赤い強調表示は維持する")
            let artwork = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('.artwork')).backgroundColor") as? String
            XCTAssertEqual(artwork, "rgb(200, 100, 50)")
            let button = try await view.evaluateJavaScript("document.querySelector('button').textContent") as? String
            XCTAssertEqual(button, "再生")
        }
    }

    @MainActor
    func testOfficialAlbumPaletteKeepsSongTextAndBackgroundTogetherAcrossSystemAppearances() async throws {
        _ = NSApplication.shared
        let store = AppleMusicStore(websiteDataStore: .nonPersistent(), usesAnalysisWorkers: false, isOfficialBrowser: true)
        let view = store.webViewForDisplay()
        view.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil); window.contentView = nil }
        // The official site pairs --joe-color with is-light-theme/is-dark-theme song text.
        view.loadHTMLString("""
        <html><head><style>
        .app-container.has-theme-override .scrollable-page { background:var(--joe-color) }
        .app-container.is-dark-theme .section { color:var(--systemPrimary-onDark) }
        .app-container.is-light-theme .section { color:var(--systemPrimary-onLight) }
        .artwork { background:rgb(200,100,50) }
        .unavailable { opacity:.4 }
        </style></head><body>
        <div class="app-container has-theme-override is-dark-theme"
          style="--joe-color:rgb(32,40,48);--systemPrimary-onDark:rgb(255,255,255);--systemPrimary-onLight:rgb(0,0,0)">
            <main class="scrollable-page"><div class="container-detail-header-wrapper"><span>Album</span></div><section class="section"><span id="song">曲名</span>
          <button class="unavailable" disabled>配信対象外</button></section><div class="artwork">ジャケット</div></main>
        </div></body></html>
        """, baseURL: URL(string: "https://music.apple.com/"))
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript("!!document.querySelector('#song')") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); view.appearance = NSAppearance(named: appearance)
            for darkAlbum in [true, false] {
                let background = darkAlbum ? "rgb(32, 40, 48)" : "rgb(240, 232, 220)"
                _ = try await view.evaluateJavaScript("""
                document.querySelector('.app-container').className='app-container has-theme-override \(darkAlbum ? "is-dark-theme" : "is-light-theme")';
                document.querySelector('.app-container').style.setProperty('--joe-color','\(background)'); true;
                """)
                let actualBackground = try await backgroundRGBA(view)
                let text = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('#song')).color") as? String
                let expected = darkAlbum ? [32, 40, 48, 204] : [240, 232, 220, 204]
                XCTAssertEqual(actualBackground.count, 4)
                for (actual, value) in zip(actualBackground, expected) {
                    XCTAssertEqual(actual, value, accuracy: 1)
                }
                let duplicateFill = try await view.evaluateJavaScript("""
                ['.scrollable-page', '.container-detail-header-wrapper'].map((selector, index) =>
                    getComputedStyle(document.querySelector(selector), index ? '::after' : null).backgroundColor)
                """) as? [String]
                XCTAssertEqual(duplicateFill, ["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)"], "背景を重ねて不透明に戻さない")
                XCTAssertEqual(text, darkAlbum ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)")
                let disabled = try await view.evaluateJavaScript("document.querySelector('.unavailable').disabled && getComputedStyle(document.querySelector('.unavailable')).opacity === '0.4'") as? Bool
                XCTAssertEqual(disabled, true, "公式の無効状態や透明度を一律に変更しない")
            }
        }
    }

    @MainActor
    private func backgroundRGBA(_ view: WKWebView, selector: String = ".app-container") async throws -> [Int] {
        let value = try await view.evaluateJavaScript("""
        (()=>{const canvas=document.createElement('canvas');canvas.width=canvas.height=1;
        const context=canvas.getContext('2d');
        context.fillStyle=getComputedStyle(document.querySelector('\(selector)')).backgroundColor;
        context.fillRect(0,0,1,1);return [...context.getImageData(0,0,1,1).data];})()
        """)
        return try XCTUnwrap(value as? [Int])
    }

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
        try await seed.saveLyricTiming(AppleMusicLyricTiming(songID: song.id, duration: song.duration,
            sourceText: "", timeline: nil, errorMessage: nil, hasLyrics: false), ticket: ticket)
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
        let previous = store.playback
        store.startPreanalysisIfReady()
        XCTAssertTrue(store.preanalysis.isWorking)
        for _ in 0..<100 {
            if !store.preanalysis.isWorking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.preanalysis.isWorking)
        XCTAssertTrue(store.preanalysis.errors.isEmpty)
        XCTAssertEqual(store.preanalysis.completions[song.id], .noLyrics)
        XCTAssertEqual(store.playback, previous)
        XCTAssertTrue(store.webViewForDisplay() === view)
        let calls = try await view.evaluateJavaScript("window.playCalls") as? Int
        XCTAssertEqual(calls, 0, "保存済みの結果がある曲は、公式画面の再生を変更せず、内部再生も始めない")
        let reused = await store.musicAnalysis.loadSavedAnalysis(for: song)
        XCTAssertTrue(reused)
        XCTAssertEqual(store.musicAnalysis.analysis?.beats, [1, 2])
        await store.finishStorageBeforeTermination()
    }

}
