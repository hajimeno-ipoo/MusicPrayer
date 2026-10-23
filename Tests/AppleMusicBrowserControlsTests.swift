import AppKit
import WebKit
import XCTest
@testable import MusicPrayer

final class AppleMusicBrowserControlsTests: XCTestCase {
    @MainActor
    func testBackTracksSameDocumentHistoryAndReturnsToPreviousPage() async throws {
        _ = NSApplication.shared
        let store = AppleMusicStore(websiteDataStore: .nonPersistent(), usesAnalysisWorkers: false, isOfficialBrowser: true)
        let view = store.webViewForDisplay()
        view.stopLoading()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("index.html")
        try "<html><body><p id='ready'>Home</p></body></html>".write(to: page, atomically: true, encoding: .utf8)
        defer { store.stop(); try? FileManager.default.removeItem(at: directory) }
        view.loadFileURL(page, allowingReadAccessTo: directory)
        try await waitFor(view, "!!document.querySelector('#ready')")
        XCTAssertFalse(store.canGoBack)
        _ = try await view.evaluateJavaScript("history.pushState({page:'album'},'', '?page=album'); true")
        for _ in 0..<100 {
            if store.canGoBack { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.canGoBack, "SPAの履歴追加でも戻る操作を有効にする")
        store.goBack()
        try await waitFor(view, "location.search === ''")
        for _ in 0..<100 {
            if !store.canGoBack { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.canGoBack)
    }

    @MainActor
    func testControlsShareOfficialMaterialAndRemainBesidePlayerAcrossThemeAndPageChanges() async throws {
        _ = NSApplication.shared
        let store = AppleMusicStore(websiteDataStore: .nonPersistent(), usesAnalysisWorkers: false, isOfficialBrowser: true)
        let view = store.webViewForDisplay()
        view.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil); window.contentView = nil }
        // The material belongs to the official player class, including its scoped CSS class.
        view.loadHTMLString("""
        <html><head><style>
        .app-container { --systemPrimary:rgb(0,0,0); --pageBG:#fff;
            --glassMaterialBackground:rgba(245,245,247,.55); --glassMaterialShadowColor:rgba(0,0,0,.1);
            --glassMaterialBackground-onLight:rgba(245,245,247,.55); --glassMaterialShadowColor-onLight:rgba(0,0,0,.1);
            --glassMaterialBackground-onDark:rgba(38,38,40,.6); --glassMaterialShadowColor-onDark:rgba(0,0,0,.2) }
        .app-container.is-dark-theme { --systemPrimary:rgb(255,255,255) }
        .player-bar__floating-player { position:fixed; bottom:20px; left:260px; right:0; height:54px; padding-inline:20px }
        .chrome-player.official-scope { position:relative; height:56px; max-width:668px; border-radius:1000px; color:var(--systemPrimary) }
        .chrome-player.official-scope::before { content:''; position:absolute; inset:0; background:var(--glassMaterialBackground); backdrop-filter:var(--glassMaterialBackdropFilter,saturate(220%) blur(16px)); box-shadow:0 10px 40px var(--glassMaterialShadowColor); border-radius:inherit }
        .is-light-theme .chrome-player::before { --glassMaterialBackground:var(--glassMaterialBackground-onLight); --glassMaterialShadowColor:var(--glassMaterialShadowColor-onLight) }
        .is-dark-theme .chrome-player::before { --glassMaterialBackground:var(--glassMaterialBackground-onDark); --glassMaterialShadowColor:var(--glassMaterialShadowColor-onDark) }
        .search-input__text-field.official-scope, .search-scope-bar__pill-container.official-scope { background-color:var(--pageBG); border-radius:1000px }
        .search-input__text-field { border:1px solid gray; outline:2px solid red }
        .search-input-wrapper, .search-scope-bar__pill-container { box-shadow:0 10px 40px #0000001a }
        .search-scope-bar__pill-container::before { content:''; background:rgba(0,0,0,.1); transform:translateX(4px) }
        </style></head><body><div class="app-container"><main style="height:2000px">Page
        <div class="search-input-wrapper"><input class="search-input__text-field official-scope" type="search" aria-label="検索"></div>
        <div class="search-scope-bar__pill-container official-scope"><input type="radio" name="scope" checked>Apple Music<input type="radio" name="scope">ライブラリ</div></main>
        <div class="player-bar__floating-player"><div class="chrome-player official-scope">Official player</div></div>
        </div></body></html>
        """, baseURL: URL(string: "https://music.apple.com/jp/"))
        try await waitFor(view, "!!document.querySelector('.music-prayer-controls')")
        for dark in [false, true] {
            _ = try await view.evaluateJavaScript("document.querySelector('.app-container').className='app-container \(dark ? "is-dark-theme" : "is-light-theme")'; true")
            let equal = try await view.evaluateJavaScript("""
            (() => {
                const official = document.querySelector('.chrome-player:not(.music-prayer-controls)');
                const controls = document.querySelector('.music-prayer-controls');
                const a = getComputedStyle(official,'::before'), b = getComputedStyle(controls,'::before');
                return a.backgroundColor === b.backgroundColor && a.backdropFilter === b.backdropFilter
                    && getComputedStyle(official).height === getComputedStyle(controls).height
                    && getComputedStyle(controls.querySelector('button')).color === getComputedStyle(official).color
                    && Math.abs(official.getBoundingClientRect().top - controls.getBoundingClientRect().top) < 1
                    && controls.querySelectorAll('button').length === 3;
            })()
            """) as? Bool
            XCTAssertEqual(equal, true, "公式バーと同じテーマ・ガラス・高さを使用する")
            let searchMaterial = try await view.evaluateJavaScript("""
            (() => {
                const player = getComputedStyle(document.querySelector('.chrome-player'), '::before');
                const field = document.querySelector('.search-input__text-field');
                const scope = document.querySelector('.search-scope-bar__pill-container');
                const matches = [field, scope].every(element => {
                    const style = getComputedStyle(element);
                    return style.backgroundColor === player.backgroundColor && style.backdropFilter === player.backdropFilter;
                });
                return matches && [field.parentElement, scope].every(element => getComputedStyle(element).boxShadow === player.boxShadow)
                    && getComputedStyle(field).outlineColor === 'rgb(255, 0, 0)'
                    && getComputedStyle(scope, '::before').transform === 'matrix(1, 0, 0, 1, 4, 0)'
                    && scope.querySelector('input').checked;
            })()
            """) as? Bool
            XCTAssertEqual(searchMaterial, true, "検索の材質は公式バーに合わせ、入力フォーカスと切替の選択表示を保つ")
        }
        _ = try await view.evaluateJavaScript("window.scrollTo(0,500); window.musicPrayerControls.update({canGoBack:true,canAdd:true,isAdding:false,message:''}); true")
        let fixed = try await view.evaluateJavaScript("""
        (()=>{const c=document.querySelector('.music-prayer-controls');
        return Math.abs(c.getBoundingClientRect().bottom-(innerHeight-18))<1
            && !c.querySelector('[data-action="back"]').disabled
            && !c.querySelector('[data-action="add"]').disabled;})()
        """) as? Bool
        XCTAssertEqual(fixed, true)
        _ = try await view.evaluateJavaScript("document.querySelector('.player-bar__floating-player').outerHTML='<div class=\"player-bar__floating-player\"><div class=\"chrome-player official-scope\">New player</div></div>'; true")
        try await waitFor(view, "document.querySelectorAll('.music-prayer-controls').length === 1 && !document.querySelector('[data-action=back]').disabled")
    }

    @MainActor
    func testAddNoticeShowsResultAndExpiresWithoutInterruptingControls() async throws {
        _ = NSApplication.shared
        let store = AppleMusicStore(websiteDataStore: .nonPersistent(), usesAnalysisWorkers: false, isOfficialBrowser: true)
        let view = store.webViewForDisplay()
        view.stopLoading()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        defer { store.stop(); window.orderOut(nil); window.contentView = nil }
        view.loadHTMLString("""
        <html><head><style>
        .app-container { --systemPrimary:rgb(0,0,0) }
        .player-bar__floating-player { position:fixed; bottom:20px; right:0; height:56px }
        .chrome-player { height:56px; border-radius:1000px }
        .chrome-player::before { content:''; position:absolute; inset:0; background:rgba(245,245,247,.8); backdrop-filter:blur(16px); border-radius:inherit }
        </style></head><body><div class="app-container">
        <div class="player-bar__floating-player"><div class="chrome-player">Official player</div></div>
        </div></body></html>
        """, baseURL: URL(string: "https://music.apple.com/jp/"))
        try await waitFor(view, "!!document.querySelector('.music-prayer-add-notice')")
        try await waitFor(view, "document.querySelector('.music-prayer-add-notice').hidden")

        func updateMessage(_ message: String) async throws {
            let data = try JSONSerialization.data(withJSONObject: ["canGoBack": true, "canAdd": true, "isAdding": false, "message": message])
            let json = String(decoding: data, as: UTF8.self)
            _ = try await view.evaluateJavaScript("window.musicPrayerControls.update(\(json)); true")
        }

        let message = "「曲名 <b>テスト</b>」を一覧に追加しました。"
        try await updateMessage(message)
        let text = try await view.evaluateJavaScript("document.querySelector('.music-prayer-add-notice').textContent") as? String
        XCTAssertEqual(text, message, "曲名はHTMLとして解釈せず、そのまま表示する")
        let visible = try await view.evaluateJavaScript("""
        (() => {
            const notice = document.querySelector('.music-prayer-add-notice');
            const rect = notice.getBoundingClientRect();
            return !notice.hidden && rect.width > 0 && rect.height > 0
                && rect.left >= 0 && rect.right <= innerWidth && rect.bottom < innerHeight - 76
                && getComputedStyle(notice).pointerEvents === 'none'
                && notice.getAttribute('role') === 'status'
                && !notice.querySelector('b')
                && !document.querySelector('[data-action="add"]').disabled;
        })()
        """) as? Bool
        XCTAssertEqual(visible, true)
        try await Task.sleep(for: .milliseconds(2200))
        try await updateMessage(message)
        try await Task.sleep(for: .milliseconds(2000))
        try await waitFor(view, "document.querySelector('.music-prayer-add-notice').hidden")
        try await updateMessage(message)
        try await waitFor(view, "document.querySelector('.music-prayer-add-notice').hidden")

        // A new add clears the old result, allowing the same song's result to appear again.
        try await updateMessage("")
        try await updateMessage(message)
        try await waitFor(view, "!document.querySelector('.music-prayer-add-notice').hidden")
        try await Task.sleep(for: .milliseconds(2200))
        let nextMessage = "曲を追加できませんでした。Apple Musicの配信曲を再生し、接続状態を確認してもう一度押してください。"
        try await updateMessage(nextMessage)
        try await Task.sleep(for: .milliseconds(2000))
        try await waitFor(view, "!document.querySelector('.music-prayer-add-notice').hidden")
        let updatedText = try await view.evaluateJavaScript("document.querySelector('.music-prayer-add-notice').textContent") as? String
        XCTAssertEqual(updatedText, nextMessage, "連続した結果は最新の案内へ更新する")
        let fits = try await view.evaluateJavaScript("(() => { const n = document.querySelector('.music-prayer-add-notice'); return n.scrollWidth <= n.clientWidth && n.getBoundingClientRect().height > 50; })()") as? Bool
        XCTAssertEqual(fits, true, "長い案内は通知内で折り返す")
        try await Task.sleep(for: .milliseconds(2200))
        try await waitFor(view, "document.querySelector('.music-prayer-add-notice').hidden")
        try await updateMessage("「曲名」はすでに一覧に登録されています。")
        try await waitFor(view, "!document.querySelector('.music-prayer-add-notice').hidden")
        try await updateMessage("")
        try await waitFor(view, "document.querySelector('.music-prayer-add-notice').hidden")
    }

    @MainActor
    private func waitFor(_ view: WKWebView, _ condition: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("条件が成立しませんでした: \(condition)")
    }
}
