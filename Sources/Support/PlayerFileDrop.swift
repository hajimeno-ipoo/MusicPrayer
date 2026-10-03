import Foundation
import UniformTypeIdentifiers

enum PlayerFileDrop {
    enum Destination: Equatable {
        case lyrics(URL)
        case audio([URL])
        case songAndLyrics(audio: URL, lyrics: URL)
    }
    enum DropError: LocalizedError {
        case unsupported
        case ambiguousPair
        var errorDescription: String? {
            switch self {
            case .unsupported: return "音楽ファイルまたは歌詞のテキストファイルをドロップしてください。"
            case .ambiguousPair: return "同時に読み込む場合は、曲1つと歌詞ファイル1つをドロップしてください。"
            }
        }
    }

    static func destination(for urls: [URL]) throws -> Destination {
        guard !urls.isEmpty else { throw DropError.unsupported }
        var lyrics: [URL] = []
        var audio: [URL] = []
        for url in urls {
            guard url.isFileURL else { throw DropError.unsupported }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw DropError.unsupported }
            if values.contentType?.conforms(to: .plainText) == true { lyrics.append(url) }
            else if values.contentType?.conforms(to: .audio) == true { audio.append(url) }
            else { throw DropError.unsupported }
        }
        guard lyrics.count <= 1 else { throw LyricTextFile.ImportError.singleFileRequired }
        if let text = lyrics.first {
            guard audio.count <= 1 else { throw DropError.ambiguousPair }
            if let song = audio.first { return .songAndLyrics(audio: song, lyrics: text) }
            return .lyrics(text)
        }
        return .audio(audio)
    }

    @MainActor
    static func importPair(audio: URL, lyrics: URL, store: PlayerStore, generation: UInt64) async throws -> String? {
        guard generation == store.playbackGeneration, store.lyricsAcceptingRequests else { return nil }
        // Decode before adding the song so an unreadable lyric file leaves the queue alone.
        let text = try LyricTextFile.read([lyrics])
        await store.add(urls: [audio], selectFirst: false)
        guard generation == store.playbackGeneration, store.lyricsAcceptingRequests,
              let index = store.tracks.firstIndex(where: { $0.url == audio }) else { return nil }
        store.select(index, autoplay: false)
        guard store.playbackGeneration != generation, store.currentTrack?.url == audio else { return nil }
        return text
    }
}
