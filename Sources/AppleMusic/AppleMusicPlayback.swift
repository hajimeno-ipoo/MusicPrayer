import Foundation

struct AppleMusicPlayback: Decodable, Equatable {
    var id = ""
    var isReady = false
    var isAuthorized = false
    var available = false
    var title = ""
    var artist = ""
    var artworkURL: String?
    var isPlaying = false
    var ended = false
    var time: Double = 0
    var playbackRate: Double?
    var preservesPitch: Bool?
    var duration: Double = 0
    var canNext = false
    var canPrevious = false
}

struct AppleMusicSong: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: String?
    var duration: Double
}

struct AppleMusicSearchResult: Decodable {
    var songs: [AppleMusicSong]
}

enum AppleMusicBridge {
    static var invocation: String {
        """
        let timer;
        const selection = (command === 'playSong' || command === 'prepareSong') ? {active:true} : null;
        if (selection) {
            if (window.__musicPrayerSelection) window.__musicPrayerSelection.active = false;
            window.__musicPrayerSelection = selection;
        }
        const invocationIsCurrent = () => !selection || (selection.active && window.__musicPrayerSelection === selection);
        const run = async () => { \(source) };
        const previousSelection = selection ? window.__musicPrayerSelectionWork : null;
        const operation = (async () => {
            if (previousSelection) { try { await previousSelection; } catch {} }
            if (!invocationIsCurrent()) throw new Error('Selection expired');
            return await run();
        })();
        if (selection) window.__musicPrayerSelectionWork = operation;
        try {
            return await Promise.race([
                operation,
                new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Playback command timed out')), 8000); })
            ]);
        } finally {
            clearTimeout(timer);
            if (selection) selection.active = false;
        }
        """
    }

    static let source: String = {
        guard let url = Bundle.module.url(forResource: "AppleMusicBridge", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("AppleMusicBridge.js is missing")
        }
        return source
    }()

    static func decode(_ value: Any?) throws -> AppleMusicPlayback {
        guard let value, !(value is NSNull) else { return AppleMusicPlayback() }
        return try JSONDecoder().decode(AppleMusicPlayback.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
