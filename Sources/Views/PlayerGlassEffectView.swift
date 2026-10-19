import AppKit

/// The player is the glass's content, so AppKit owns its backdrop and contrast.
final class PlayerGlassEffectView: NSGlassEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
    }
}
