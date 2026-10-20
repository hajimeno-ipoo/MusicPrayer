import AppKit
import SwiftUI

struct PlayerGlassContainer: NSViewRepresentable {
    let store: PlayerStore
    let appearance: PlayerAppearance
    @Environment(\.colorScheme) private var systemColorScheme

    func makeCoordinator() -> PlayerFileDrop.Session { PlayerFileDrop.Session() }

    func makeNSView(context: Context) -> PlayerGlassEffectView {
        let glass = PlayerGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = 20
        let hosting = NSHostingView(rootView: PlayerView(store: store, fileDropSession: context.coordinator))
        hosting.sizingOptions = []
        glass.contentView = PlayerGlassBackdropView(hosting: hosting)
        updateNSView(glass, context: context)
        return glass
    }

    func updateNSView(_ nsView: PlayerGlassEffectView, context: Context) {
        let session = context.coordinator
        nsView.onFileTargetChanged = { session.isTargeted = $0 }
        nsView.onFileDrop = { urls in
            session.request = PlayerFileDrop.Request(urls: urls, generation: store.playbackGeneration)
        }
        nsView.appearance = appearance.nsAppearance(systemColorScheme: systemColorScheme)
        if let content = nsView.contentView as? PlayerGlassBackdropView,
           let hosting = content.hosting as? NSHostingView<PlayerView> {
            hosting.rootView = PlayerView(store: store, fileDropSession: session)
        }
    }
}

final class PlayerGlassBackdropView: NSView {
    let backdrop = NSVisualEffectView()
    let hosting: NSView

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func configureSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true

        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // Mix a small amount of the system material; this does not set its blur radius.
        backdrop.alphaValue = 0.25

        for view in [backdrop, hosting] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
        }
        addSubview(backdrop)
        addSubview(hosting, positioned: .above, relativeTo: backdrop)
    }
}
