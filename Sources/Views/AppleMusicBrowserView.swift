import SwiftUI
import WebKit

struct AppleMusicBrowserView: View {
    let store: AppleMusicStore
    let onReturnToPlayer: () -> Void

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

                if store.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Apple Musicを読み込み中")
                }
            }
            .padding(.leading, 90)
            .padding(.trailing, 20)
            .padding(.vertical, 12)

            Text("Apple Accountでサインイン後、「プレイヤーに戻る」から一覧の曲を再生できます。")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 12)

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
    }
}

private struct AppleMusicWebView: NSViewRepresentable {
    let store: AppleMusicStore

    func makeNSView(context: Context) -> WKWebView {
        store.webViewForDisplay()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
