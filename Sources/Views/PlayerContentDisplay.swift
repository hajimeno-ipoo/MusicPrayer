enum PlayerContentDisplay {
    // Both are visible initially; the first press starts the requested cycle.
    case initial, artworkOnly, artworkAndLyrics, lyricsOnly, visualizerOnly

    var showsArtwork: Bool { self != .lyricsOnly && self != .visualizerOnly }
    var showsLyrics: Bool { self == .initial || self == .artworkAndLyrics || self == .lyricsOnly }

    var next: Self {
        switch self {
        case .initial, .visualizerOnly: return .artworkOnly
        case .artworkOnly: return .artworkAndLyrics
        case .artworkAndLyrics: return .lyricsOnly
        case .lyricsOnly: return .visualizerOnly
        }
    }

    var title: String {
        switch self {
        case .initial, .artworkAndLyrics: return "カバーと歌詞"
        case .artworkOnly: return "カバーのみ"
        case .lyricsOnly: return "歌詞のみ"
        case .visualizerOnly: return "ビジュアライザーのみ"
        }
    }

}
