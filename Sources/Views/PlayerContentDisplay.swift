enum PlayerContentDisplay {
    // Both are visible initially; the first press starts the requested cycle.
    case initial, artworkOnly, artworkAndLyrics, visualizerOnly

    var showsArtwork: Bool { self != .visualizerOnly }
    var showsLyrics: Bool { self == .initial || self == .artworkAndLyrics }

    var next: Self {
        switch self {
        case .initial, .visualizerOnly: return .artworkOnly
        case .artworkOnly: return .artworkAndLyrics
        case .artworkAndLyrics: return .visualizerOnly
        }
    }

    var title: String {
        switch self {
        case .initial, .artworkAndLyrics: return "カバーと歌詞"
        case .artworkOnly: return "カバーのみ"
        case .visualizerOnly: return "ビジュアライザーのみ"
        }
    }

}
