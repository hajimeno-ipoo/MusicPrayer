import SwiftUI

struct QueueView: View {
    @Bindable var store: PlayerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("再生する曲").font(.headline); Spacer(); Button(action: store.openFiles) { Label("追加", systemImage: "plus") } }
            if store.tracks.isEmpty { Text("まだ曲がありません").foregroundStyle(.secondary).padding(.vertical, 30) }
            else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(store.tracks.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 12) {
                                Button { store.select(index) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: index == store.currentIndex ? "waveform" : "music.note").frame(width: 20).foregroundStyle(index == store.currentIndex ? .cyan : .secondary)
                                        VStack(alignment: .leading, spacing: 3) { Text(track.title).lineLimit(1); if !track.artist.isEmpty { Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                                        Spacer(); Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { store.remove(track.id) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.plain).help("一覧から外す")
                            }
                            .padding(10).background(index == store.currentIndex ? Color.cyan.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 340)
            }
        }.padding(18).frame(width: 410)
    }
}
