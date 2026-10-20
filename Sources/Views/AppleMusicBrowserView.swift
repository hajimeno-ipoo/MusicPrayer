import SwiftUI
import WebKit

struct AppleMusicBrowserView: View {
    let store: AppleMusicStore
    let onAdd: (AppleMusicSong) -> Bool
    let onReturnToPlayer: () -> Void
    @State private var isAdding = false
    @State private var addMessage: String?
    @State private var addError: String?
    var body: some View {
        AppleMusicBrowserWebView(store: store, canGoBack: store.canGoBack,
            canAdd: !store.isLoading && store.playback.available, isAdding: isAdding,
            message: addError ?? addMessage ?? "",
            onReturnToPlayer: onReturnToPlayer, onAdd: addCurrentSong)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addCurrentSong() {
        guard !isAdding else { return }
        isAdding = true
        addMessage = nil
        addError = nil
        Task { @MainActor in
            defer { isAdding = false }
            do {
                guard let song = try await store.currentBrowserSong() else {
                    addError = "追加する曲がありません。Apple Musicで曲を再生してから、もう一度押してください。"
                    return
                }
                addMessage = onAdd(song) ? "「\(song.title)」を一覧に追加しました。" : "「\(song.title)」はすでに一覧に登録されています。"
            } catch {
                addError = "曲を追加できませんでした。Apple Musicの配信曲を再生し、接続状態を確認してもう一度押してください。"
            }
        }
    }
}

struct AppleMusicBrowserWebView: NSViewRepresentable {
    let store: AppleMusicStore
    let canGoBack: Bool
    let canAdd: Bool
    let isAdding: Bool
    let message: String
    let onReturnToPlayer: () -> Void
    let onAdd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let view = store.webViewForDisplay()
        view.configuration.userContentController.add(
            WeakControlsHandler(context.coordinator), name: "musicPrayerControls")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "musicPrayerControls")
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: AppleMusicBrowserWebView
        init(_ parent: AppleMusicBrowserWebView) { self.parent = parent }

        func update(_ view: WKWebView) {
            guard view.url?.host == "music.apple.com" else { return }
            let state: [String: Any] = ["canGoBack": parent.canGoBack,
                "canAdd": parent.canAdd,
                "isAdding": parent.isAdding, "message": parent.message]
            guard let data = try? JSONSerialization.data(withJSONObject: state),
                  let json = String(data: data, encoding: .utf8) else { return }
            view.evaluateJavaScript("window.musicPrayerControls?.update(\(json))", completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.host == "music.apple.com",
                  let action = message.body as? String else { return }
            switch action {
            case "player": parent.onReturnToPlayer()
            case "back": parent.store.goBack()
            case "add": parent.onAdd()
            case "ready": if let view = message.webView { update(view) }
            default: break
            }
        }
    }

    // WKUserContentController retains its handler; the proxy keeps the SwiftUI coordinator weak.
    @MainActor final class WeakControlsHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?
        init(_ target: Coordinator) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}

struct AppleMusicWebView: NSViewRepresentable {
    let store: AppleMusicStore
    func makeNSView(context: Context) -> WKWebView { store.webViewForDisplay() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
