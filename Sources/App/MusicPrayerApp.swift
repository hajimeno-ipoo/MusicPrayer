import SwiftUI
import AppKit

struct MusicPrayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = PlayerStore()
    @State private var didStartRestore = false
    @State private var showFontLicenses = false
    var body: some Scene {
        Window("Music Prayer", id: "player") {
            PlayerGlassContainer(store: store,
                                 usesDarkAppearance: !store.isAppleMusicSearchVisible && !store.isAppleMusicBrowserVisible)
                .frame(minWidth: 860, minHeight: 800)
                .ignoresSafeArea()
                .containerBackground(.clear, for: .window)
                .modifier(PlayerWindowRecovery(delegate: delegate))
                .sheet(isPresented: $showFontLicenses) { FontLicensesView() }
                .task {
                    delegate.store = store
                    guard !didStartRestore else { return }
                    didStartRestore = true
                    await store.restore()
                }
        }
        .defaultSize(width: 1160, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("フォントのライセンス…") {
                    showFontLicenses = true
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("曲を追加…", action: store.openFiles).keyboardShortcut("o")
                Button("Apple Music…", action: store.openAppleMusic)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            CommandMenu("再生") {
                Button(store.isPlaying ? "一時停止" : "再生", action: store.togglePlayback)
                    .keyboardShortcut(.space, modifiers: []).disabled(showFontLicenses || store.isAppleMusicBrowserVisible || store.isAppleMusicSearchVisible || !store.canTogglePlayback)
                Button("停止", action: store.stop).keyboardShortcut(".").disabled(store.isAppleMusicBrowserVisible || store.isAppleMusicSearchVisible || !store.canTogglePlayback)
                Button("前の曲", action: store.previous).keyboardShortcut(.leftArrow, modifiers: .command).disabled(store.isAppleMusicBrowserVisible || store.isAppleMusicSearchVisible || !store.canSkipPrevious)
                Button("次の曲", action: store.next).keyboardShortcut(.rightArrow, modifiers: .command).disabled(store.isAppleMusicBrowserVisible || store.isAppleMusicSearchVisible || !store.canSkipNext)
            }
        }
    }
}

@main
enum MusicPrayerMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--apple-music-analysis-worker") {
            AppleMusicAnalysisWorker.runMain()
        } else {
            MusicPrayerApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: PlayerStore? {
        didSet {
            guard let store, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs; pendingURLs = []
            Task { @MainActor in await store.add(urls: urls) }
        }
    }
    private var pendingURLs: [URL] = []
    private var keyMonitor: Any?
    private var lyricTerminationTask: Task<Void, Never>?
    var reopenPlayer: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Space always controls playback in the player, even when a toolbar button has focus.
        // Native file panels and text editors retain their normal keyboard behavior.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard event.keyCode == 49, modifiers.isEmpty, let window = NSApp.keyWindow,
                  !(window is NSPanel), window.attachedSheet == nil, window.sheetParent == nil,
                  !(window.firstResponder is NSTextView), let store = self?.store,
                  !store.isAppleMusicBrowserVisible, !store.isAppleMusicSearchVisible, store.canTogglePlayback else { return event }
            store.togglePlayback()
            return nil
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.needsLyricSaveBeforeTermination || store.appleMusic.needsStorageBeforeTermination else { return .terminateNow }
        if lyricTerminationTask == nil {
            lyricTerminationTask = Task { @MainActor [weak self] in
                let saved = await store.finishLyricsBeforeTermination()
                if saved { await store.appleMusic.finishStorageBeforeTermination() }
                self?.lyricTerminationTask = nil
                sender.reply(toApplicationShouldTerminate: saved)
                if !saved { self?.reopenPlayer?(); sender.activate(ignoringOtherApps: true) }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        store?.shutdown()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let store { Task { @MainActor in await store.add(urls: urls) } }
        else { pendingURLs.append(contentsOf: urls) }
        sender.reply(toOpenOrPrint: .success)
    }
}

private struct PlayerWindowRecovery: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.reopenPlayer = { openWindow(id: "player") }
        }
    }
}
