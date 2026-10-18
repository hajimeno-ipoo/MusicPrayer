import Foundation

enum QueuePersistence {
    struct SavedTrack: Codable {
        var bookmark: Data?
        var path: String?
        var appleMusicSong: AppleMusicSong?
    }
    struct Session: Codable { var tracks: [SavedTrack]; var current: Int; var time: Double; var volume: Float }
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/queue.json")
    }
    static func save(tracks: [Track], current: Int, time: Double, volume: Float, to destination: URL = file) throws {
        let items = try tracks.map { track in
            if let song = track.appleMusicSong {
                return SavedTrack(appleMusicSong: song)
            }
            return SavedTrack(bookmark: try track.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), path: track.url.path)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Session(tracks: items, current: current, time: time, volume: volume)).write(to: destination, options: .atomic)
    }
    static func restore(from source: URL = file) -> (tracks: [Track], urls: [URL], current: Int, time: Double, volume: Float)? {
        guard let data = try? Data(contentsOf: source), let saved = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        // Keep missing files in the queue so the user can see and remove them.
        var restored: [(index: Int, track: Track)] = []
        for (index, item) in saved.tracks.enumerated() {
            if let song = item.appleMusicSong {
                restored.append((index, Track(appleMusicSong: song)))
                continue
            }
            var stale = false
            let bookmarkedURL = item.bookmark.flatMap {
                try? URL(resolvingBookmarkData: $0, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            guard let url = bookmarkedURL ?? item.path.map({ URL(fileURLWithPath: $0) }) else { continue }
            restored.append((index, Track(url: url)))
        }
        let tracks = restored.map(\.track)
        let current = saved.current < 0 || tracks.isEmpty ? -1
            : restored.lastIndex(where: { $0.index <= saved.current }) ?? 0
        return (tracks, tracks.filter { !$0.isAppleMusic }.map(\.url), current, saved.time, saved.volume)
    }
}
