import SwiftUI
import AppKit

struct PlayerContentDisplayIcon: View {
    let display: PlayerContentDisplay
    private static let lyrics = Bundle.module.image(forResource: "Lyrics")!
    private static let lyricsSelected = Bundle.module.image(forResource: "LyricsSelected")!

    var body: some View {
        Group {
            if display == .visualizerOnly {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13, weight: .medium))
            } else {
                Image(nsImage: display.showsLyrics ? Self.lyricsSelected : Self.lyrics)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
        }
        .frame(width: 30, height: 30)
        .foregroundStyle(Color.primary.opacity(0.85))
    }
}
