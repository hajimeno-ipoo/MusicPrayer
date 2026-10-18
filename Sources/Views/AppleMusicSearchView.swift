import SwiftUI

struct AppleMusicSearchView: View {
    @Bindable var store: AppleMusicStore
    let onAdd: (AppleMusicSong) -> Void
    let onSignIn: () -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    private var canSearch: Bool {
        store.playback.isReady && !store.isSearching &&
        !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Apple Music", systemImage: "music.note")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("閉じる", action: onClose).keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 12) {
                    if !store.playback.isReady {
                        Text("接続状態を確認中…").foregroundStyle(.secondary)
                    } else if store.playback.isAuthorized {
                        Label("Apple Musicアカウントに接続中", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未サインイン：プレビュー再生")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("サインイン", action: onSignIn)
                    }
                }
                .font(.callout)
                HStack(spacing: 12) {
                    TextField("曲名・アーティスト・アルバムで検索", text: $store.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit(search)
                        .accessibilityLabel("Apple Musicを検索")
                    Button("検索", action: search)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSearch)
                }
                if !store.playback.isReady {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Apple Musicを準備しています…").foregroundStyle(.secondary)
                    }.font(.callout)
                }
                if let error = store.searchError {
                    errorMessage(error)
                }
                if let error = store.errorMessage, error != store.searchError {
                    errorMessage(error)
                }
            }
            .padding(24)
            Divider()
            results
            Divider()
            HStack {
                Text("曲を一覧に追加し、再生する時は曲の一覧から選びます。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("接続を確認", action: onSignIn)
                    .font(.caption)
                    .help("Apple Musicの公式サインイン画面を開きます")
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 640)
        .onAppear { searchFocused = true }
        .onDisappear { store.cancelSearch() }
    }

    @ViewBuilder
    private var results: some View {
        if store.isSearching {
            VStack(spacing: 12) {
                ProgressView()
                Text("曲を検索しています…").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !store.searchResults.isEmpty {
            List(store.searchResults, id: \.id) { song in
                Button {
                    onAdd(song)
                } label: {
                    songRow(song)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(song.title)、\(song.artist)を一覧に追加")
                .help("一覧に追加")
            }
            .listStyle(.inset)
        } else {
            VStack(spacing: 12) {
                Image(systemName: store.hasSearched ? "magnifyingglass" : "music.note.list")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                Text(store.searchError != nil ? "検索できませんでした" : (store.hasSearched ? "曲が見つかりませんでした" : "聴きたい曲を検索"))
                    .font(.headline)
                Text(store.searchError != nil ? "上のメッセージを確認して、もう一度検索してください。" : (store.hasSearched ? "曲名やアーティスト名を変えて検索してください。" : "曲名・アーティスト・アルバムから探せます。"))
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func songRow(_ song: AppleMusicSong) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: song.artworkURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(song.title).font(.body.weight(.medium)).lineLimit(1)
                Text(song.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if !song.album.isEmpty {
                    Text(song.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 14)
            Text(clock(song.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Label("一覧に追加", systemImage: "plus.circle")
                .font(.callout).padding(.leading, 6)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout).foregroundStyle(.orange)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func search() {
        guard canSearch else { return }
        Task { await store.search() }
    }
}
