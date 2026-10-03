import SwiftUI
import AppKit

@main
struct MusicPrayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = PlayerStore()
    @State private var didStartRestore = false
    var body: some Scene {
        Window("Music Prayer", id: "player") {
            PlayerView(store: store)
                .modifier(PlayerWindowRecovery(delegate: delegate))
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
            CommandGroup(replacing: .newItem) { Button("曲を追加…", action: store.openFiles).keyboardShortcut("o") }
            CommandMenu("再生") {
                Button(store.isPlaying ? "一時停止" : "再生", action: store.togglePlayback).keyboardShortcut(.space, modifiers: [])
                Button("停止", action: store.stop).keyboardShortcut(".")
                Button("前の曲", action: store.previous).keyboardShortcut(.leftArrow, modifiers: .command)
                Button("次の曲", action: store.next).keyboardShortcut(.rightArrow, modifiers: .command)
            }
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
                  !(window is NSPanel), window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView), let store = self?.store else { return event }
            store.togglePlayback()
            return nil
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.needsLyricSaveBeforeTermination else { return .terminateNow }
        if lyricTerminationTask == nil {
            lyricTerminationTask = Task { @MainActor [weak self] in
                let saved = await store.finishLyricsBeforeTermination()
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
