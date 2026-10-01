import Foundation

enum QueuePersistence {
    struct SavedTrack: Codable { var bookmark: Data; var path: String }
    struct Session: Codable { var tracks: [SavedTrack]; var current: Int; var time: Double; var volume: Float }
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hazimeno.MusicPrayer/queue.json")
    }
    static func save(tracks: [Track], current: Int, time: Double, volume: Float) throws {
        let items = try tracks.map { track in
            SavedTrack(bookmark: try track.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), path: track.url.path)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Session(tracks: items, current: current, time: time, volume: volume)).write(to: file, options: .atomic)
    }
    static func restore() -> (urls: [URL], current: Int, time: Double, volume: Float)? {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Session.self, from: data) else { return nil }
        // Keep missing files in the queue so the user can see and remove them.
        let urls = saved.tracks.map { item -> URL in
            var stale = false
            return (try? URL(resolvingBookmarkData: item.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? URL(fileURLWithPath: item.path)
        }
        return (urls, saved.current, saved.time, saved.volume)
    }
}
