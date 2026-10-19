import SwiftUI

/// Opaque system colors follow macOS appearance without translucent wallpaper tint.
enum AppleMusicAppearance {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)

    // Use the site's surface variables only; preserve artwork and playback controls.
    static let browserStyle = """
    if (location.protocol === 'https:' && location.hostname === 'music.apple.com') {
        const style = document.createElement('style');
        style.textContent = `
            :root, .app-container {
                --pageBG: #fff !important;
                --pageBG-rgb: 255, 255, 255 !important;
                --joe-color: #fff !important;
            }
            body, .scrollable-page { background-color: #fff !important; }
            .side-panel, .mini-player { background-color: #f5f5f7 !important; }
            @media (prefers-color-scheme: dark) {
                :root, .app-container {
                    --pageBG: #1f1f1f !important;
                    --pageBG-rgb: 31, 31, 31 !important;
                    --joe-color: #1f1f1f !important;
                }
                body, .scrollable-page { background-color: #1f1f1f !important; }
                .side-panel, .mini-player { background-color: #282828 !important; }
            }
        `;
        document.head.appendChild(style);
    }
    """
}
