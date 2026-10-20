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
        .app-container { --systemPrimary:rgb(0,0,0); --material:rgba(245,245,247,.55) }
        .app-container.is-dark-theme { --systemPrimary:rgb(255,255,255); --material:rgba(38,38,40,.6) }
        .player-bar__floating-player { position:fixed; bottom:20px; left:260px; right:0; height:54px; padding-inline:20px }
        .chrome-player.official-scope { position:relative; height:56px; max-width:668px; border-radius:1000px; color:var(--systemPrimary) }
        .chrome-player.official-scope::before { content:''; position:absolute; inset:0; background:var(--material); backdrop-filter:saturate(2.2) blur(16px); border-radius:inherit }
        </style></head><body><div class="app-container"><main style="height:2000px">Page</main>
        <div class="player-bar__floating-player"><div class="chrome-player official-scope">Official player</div></div>
        </div></body></html>
        """, baseURL: URL(string: "https://music.apple.com/jp/"))
        try await waitFor(view, "!!document.querySelector('.music-prayer-controls')")
        for dark in [false, true] {
            _ = try await view.evaluateJavaScript("document.querySelector('.app-container').classList.toggle('is-dark-theme', \(dark)); true")
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
    private func waitFor(_ view: WKWebView, _ condition: String) async throws {
        for _ in 0..<100 {
            if (try? await view.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("条件が成立しませんでした: \(condition)")
    }
}
