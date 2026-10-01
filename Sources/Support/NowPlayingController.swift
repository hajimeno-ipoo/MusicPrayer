import Foundation
import NowPlaying
import Observation
import OSLog

@MainActor @Observable
private final class PublishedMediaSession: MediaSessionRepresentable {
    let id = "com.hazimeno.MusicPrayer.playback"
    var content: (any MediaContentRepresentable)?
    var playbackSnapshot: MediaPlaybackSnapshot?
    var commands: [MediaCommand] = []
}

@MainActor
final class NowPlayingController {
    private weak var store: PlayerStore?
    private let model: PublishedMediaSession
    private let session: MediaSession<PublishedMediaSession>
    private var metadataKey: MetadataKey?
    private var artworkData: Data?
    private var commandState: CommandState?
    private var primaryRequest: Task<Void, Never>?
    private var previousTrackID: UUID?
    private var wasPlaying = false
    private var requestedPrimaryForPlayback = false
    private let log = Logger(subsystem: "com.hazimeno.MusicPrayer", category: "NowPlaying")

    private struct MetadataKey: Equatable {
        var id: UUID
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }
    private struct CommandState: Equatable {
        var hasTrack: Bool
        var shuffle: Bool
        var repeatSetting: RepeatSetting
    }

    init(store: PlayerStore) {
        self.store = store
        let model = PublishedMediaSession()
        self.model = model
        self.session = MediaSession(model)
        update()
    }

    func update() {
        guard let store else { return }
        let track = store.currentTrack
        let duration = store.duration.isFinite && store.duration > 0 ? store.duration : (track?.duration ?? 0)
        if let track {
            let key = MetadataKey(id: track.id, title: track.title, artist: track.artist,
                                  album: track.album, duration: duration)
            if metadataKey != key || artworkData != track.artwork {
                let artwork: Artwork? = track.artwork.map { data in
                    Artwork(id: "\(track.id.uuidString).artwork") { _ in
                        try ArtworkRepresentation(data: data)
                    }
                }
                model.content = MusicContent(id: track.id.uuidString, songTitle: track.title,
                                             artistName: track.artist, albumName: track.album,
                                             type: .audio,
                                             duration: duration.isFinite && duration > 0 ? .finite(duration) : nil,
                                             artwork: artwork)
                metadataKey = key
                artworkData = track.artwork
            }
        } else {
            model.content = nil
            metadataKey = nil
            artworkData = nil
        }
        let position = store.position.isFinite ? max(0, store.position) : 0
        model.playbackSnapshot = MediaPlaybackSnapshot(
            state: track == nil ? .stopped : (store.isPlaying ? .playing(rate: 1) : .paused),
            elapsedTime: duration > 0 ? min(position, duration) : position,
            timestamp: Date())

        let commands = CommandState(hasTrack: track != nil, shuffle: store.shuffle,
                                    repeatSetting: store.repeatSetting)
        if commands != commandState {
            configureCommands(store: store, state: commands)
            commandState = commands
        }
        let started = store.isPlaying && (!wasPlaying || previousTrackID != track?.id)
        if started || !store.isPlaying { requestedPrimaryForPlayback = false }
        wasPlaying = store.isPlaying
        previousTrackID = track?.id
        if store.isPlaying, track != nil, !requestedPrimaryForPlayback, !session.isApplicationPrimary,
           session.canBecomeApplicationPrimary, primaryRequest == nil {
            requestedPrimaryForPlayback = true
            primaryRequest = Task { [weak self] in
                guard let self else { return }
                defer { self.primaryRequest = nil }
                do { try await self.session.requestToBecomeApplicationPrimary() }
                catch { self.log.error("Now Playing primary request failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private func configureCommands(store: PlayerStore, state: CommandState) {
        let repeatMode: MediaCommand.RepeatMode
        switch state.repeatSetting {
        case .off: repeatMode = .off
        case .one: repeatMode = .one
        case .all: repeatMode = .all
        }
        model.commands = [
            .play { [weak store] in
                await MainActor.run {
                    guard let store, store.currentTrack != nil, !store.isPlaying else { return }
                    store.togglePlayback()
                }
            }.enabled(state.hasTrack),
            .pause { [weak store] in
                await MainActor.run {
                    guard let store, store.isPlaying else { return }
                    store.togglePlayback()
                }
            }.enabled(state.hasTrack),
            .togglePlayPause { [weak store] in
                await MainActor.run {
                    guard let store, store.currentTrack != nil else { return }
                    store.togglePlayback()
                }
            }.enabled(state.hasTrack),
            .stop { [weak store] in await MainActor.run { store?.stop() } }.enabled(state.hasTrack),
            .next { [weak store] in await MainActor.run { store?.next() } }.enabled(state.hasTrack),
            .previous { [weak store] in await MainActor.run { store?.previous() } }.enabled(state.hasTrack),
            .seekToPosition { [weak store] position in
                guard position.isFinite else { return }
                await MainActor.run { store?.seek(position) }
            }.enabled(state.hasTrack),
            .changeRepeatMode(current: repeatMode, supported: [.off, .one, .all]) { [weak store] mode in
                await MainActor.run {
                    switch mode {
                    case .off: store?.repeatSetting = .off
                    case .one: store?.repeatSetting = .one
                    case .all: store?.repeatSetting = .all
                    @unknown default: break
                    }
                }
            }.enabled(state.hasTrack),
            .changeShuffleMode(current: state.shuffle ? .items : .off, supported: [.off, .items]) { [weak store] mode in
                await MainActor.run {
                    switch mode {
                    case .off: store?.shuffle = false
                    case .items: store?.shuffle = true
                    case .collections: break
                    @unknown default: break
                    }
                }
            }.enabled(state.hasTrack)
        ]
    }
}
