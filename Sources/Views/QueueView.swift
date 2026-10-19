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
                            let selected = store.currentQueueTrack?.id == track.id
                            HStack(spacing: 12) {
                                Button { store.select(index, autoplay: false) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected ? "waveform" : "music.note").frame(width: 20).foregroundStyle(selected ? .cyan : .secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                                            if !track.artist.isEmpty {
                                                Text(track.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            if let song = track.appleMusicSong {
                                                Label("Apple Music", systemImage: "music.note")
                                                    .font(.system(size: 13)).foregroundStyle(.pink)
                                                if store.appleMusic.preanalysis.isAnalyzing(songID: song.id) {
                                                    AnalysisProgressView(status: store.appleMusic.preanalysis.status(for: song),
                                                                         progress: store.appleMusic.preanalysis.progress(for: song))
                                                        .tint(.cyan).foregroundStyle(.primary)
                                                } else {
                                                    Text(store.appleMusic.preanalysis.status(for: song))
                                                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                                                }
                                                if let error = store.appleMusic.preanalysis.errors[song.id] {
                                                    Text(error).font(.system(size: 14)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                                }
                                            }
                                        }
                                        Spacer(); Text(clock(track.duration)).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { store.remove(track.id) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.plain).help("一覧から外す")
                            }
                            .padding(10).background(selected ? Color.cyan.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 340)
            }
        }.padding(18).frame(width: 480)
    }
}
