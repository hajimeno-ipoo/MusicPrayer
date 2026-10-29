import AppKit

/// The player is the glass's content, so AppKit owns its backdrop and contrast.
final class PlayerGlassEffectView: NSGlassEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
        updateGlassTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlassTint()
    }

    private func updateGlassTint() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        tintColor = isDark ? NSColor.black.withAlphaComponent(0.35) : nil
    }

}
