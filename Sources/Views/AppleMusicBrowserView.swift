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
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onReturnToPlayer) {
                    Label("プレイヤーに戻る", systemImage: "chevron.left")
                }

                Divider().frame(height: 20)

                Button(action: store.goBack) {
                    Image(systemName: "arrow.left")
                }
                .disabled(!store.canGoBack)
                .accessibilityLabel("前のページに戻る")
                .help("前のページに戻る")

                Button(action: store.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Apple Musicを再読み込み")
                .help("再読み込み")

                Label("Apple Music", systemImage: "music.note")
                    .font(.headline)

                Spacer()

                Button(action: addCurrentSong) {
                    Label(isAdding ? "曲を確認中…" : "再生中の曲を一覧に追加", systemImage: "plus.circle")
                }
                .disabled(isAdding || store.isLoading || !store.playback.available)
                .help("Apple Musicで再生中または一時停止中の曲を、MusicPrayerの一覧に追加します")

                if store.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Apple Musicを読み込み中")
                }
            }
            .padding(.leading, 90)
            .padding(.trailing, 20)
            .padding(.vertical, 12)

            Text("Apple Musicで曲を再生し、上の「再生中の曲を一覧に追加」を押してください。一時停止中も追加できます。")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 12)

            if let addMessage {
                Label(addMessage, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }

            if let addError {
                Label(addError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()
            AppleMusicWebView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppleMusicAppearance.background)
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

struct AppleMusicWebView: NSViewRepresentable {
    let store: AppleMusicStore

    func makeNSView(context: Context) -> WKWebView {
        store.webViewForDisplay()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
