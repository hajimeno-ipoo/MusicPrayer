import SwiftUI
import UniformTypeIdentifiers

struct LyricEditorView: View {
    let store: PlayerStore
    @Binding var draft: String
    @Binding var fileImportError: String?
    var onFileDrop: ([URL]) -> Void
    @State private var showFileImporter = false
    @State private var fileDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("歌詞").font(.headline)
                Spacer()
                Button("ファイルを読み込む", systemImage: "doc.badge.plus") { showFileImporter = true }
                    .disabled(!store.lyricsAcceptingRequests)
            }
            Text(".txtファイルをアプリ画面へドロップすると、ここに本文が入ります")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            LyricTextEditor(text: $draft, isEditable: store.lyricsAcceptingRequests,
                            onFileDrop: onFileDrop, onFileTargetChanged: { fileDropTarget = $0 })
                .padding(8)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(fileDropTarget ? Color.cyan : Color.clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .frame(height: 250)
            if let fileImportError {
                Text(fileImportError).font(.system(size: 12)).foregroundStyle(.orange)
            }
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
                Button("クリア", systemImage: "eraser") {
                    draft = ""
                    fileImportError = nil
                }
                .disabled(!store.lyricsAcceptingRequests || draft.isEmpty)
                Spacer()
                Button("適用") { store.applyLyrics(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.lyricsAcceptingRequests || store.currentTrack == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.plainText]) { result in
            switch result {
            case .success(let url): importFile([url])
            case .failure(let error): fileImportError = error.localizedDescription
            }
        }
    }

    private func importFile(_ urls: [URL]) {
        guard store.lyricsAcceptingRequests else { return }
        do {
            let text = try LyricTextFile.read(urls)
            draft = text
            fileImportError = nil
        } catch {
            fileImportError = error.localizedDescription
        }
    }
}
