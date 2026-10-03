import SwiftUI

struct LyricEditorView: View {
    let store: PlayerStore
    @State private var draft: String

    init(store: PlayerStore) {
        self.store = store
        _draft = State(initialValue: store.lyricText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("歌詞").font(.headline)
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .frame(height: 250)
                .accessibilityLabel("歌詞全文")
                .disabled(!store.lyricsAcceptingRequests)
            VStack(alignment: .leading, spacing: 6) {
                Text(store.lyricTimingStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let error = store.lyricTimingError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    Button("タイミングを再生成", action: store.retryLyricTiming)
                        .disabled(!store.lyricsAcceptingRequests)
                }
                if let error = store.lyricSaveError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if store.hasPendingLyricSaveFailure {
                    Button("保存を再試行", action: store.retryLyricSave)
                        .disabled(!store.lyricsAcceptingRequests)
                }
            }
            HStack {
                Spacer()
                Button("適用") { store.applyLyrics(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.lyricsAcceptingRequests || store.currentTrack == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .preferredColorScheme(.dark)
    }
}
