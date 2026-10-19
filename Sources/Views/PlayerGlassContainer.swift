import AppKit
import SwiftUI

struct PlayerGlassContainer: NSViewRepresentable {
    let store: PlayerStore
    let usesDarkAppearance: Bool

    func makeCoordinator() -> PlayerFileDrop.Session { PlayerFileDrop.Session() }

    func makeNSView(context: Context) -> PlayerGlassEffectView {
        let glass = PlayerGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = 20
        let hosting = NSHostingView(rootView: PlayerView(store: store, fileDropSession: context.coordinator))
        hosting.sizingOptions = []
        glass.contentView = hosting
        updateNSView(glass, context: context)
        return glass
    }

    func updateNSView(_ nsView: PlayerGlassEffectView, context: Context) {
        let session = context.coordinator
        nsView.onFileTargetChanged = { session.isTargeted = $0 }
        nsView.onFileDrop = { urls in
            session.request = PlayerFileDrop.Request(urls: urls, generation: store.playbackGeneration)
        }
        nsView.appearance = usesDarkAppearance ? NSAppearance(named: .darkAqua) : nil
        if let hosting = nsView.contentView as? NSHostingView<PlayerView> {
            hosting.rootView = PlayerView(store: store, fileDropSession: session)
        }
    }
}
