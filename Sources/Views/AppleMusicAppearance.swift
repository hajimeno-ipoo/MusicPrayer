import SwiftUI

/// Opaque system colors follow macOS appearance without translucent wallpaper tint.
enum AppleMusicAppearance {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
}
