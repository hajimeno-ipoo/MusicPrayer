import AppKit
import SwiftUI

struct PlayerGlassContainer: NSViewRepresentable {
    let store: PlayerStore
    let usesDarkAppearance: Bool

    func makeNSView(context: Context) -> PlayerGlassEffectView {
        let glass = PlayerGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = 20
        let hosting = NSHostingView(rootView: PlayerView(store: store))
        hosting.sizingOptions = []
        glass.contentView = hosting
        updateNSView(glass, context: context)
        return glass
    }

    func updateNSView(_ nsView: PlayerGlassEffectView, context: Context) {
        nsView.appearance = usesDarkAppearance ? NSAppearance(named: .darkAqua) : nil
        if let hosting = nsView.contentView as? NSHostingView<PlayerView> {
            hosting.rootView = PlayerView(store: store)
        }
    }
}
