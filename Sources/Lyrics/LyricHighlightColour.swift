import SwiftUI
import AppKit

enum LyricHighlightColour: String, CaseIterable, Identifiable {
    case cyan, red, coralRed, rose, pink, apricot, gold, mintGreen, blue, purple
    case skyCyan, lightBlue, turquoise, aquaMint

    static let preferenceKey = "lyricHighlightColour"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cyan: return "シアン"
        case .red: return "明るいレッド"
        case .coralRed: return "コーラルレッド"
        case .rose: return "ローズ"
        case .pink: return "明るいピンク"
        case .apricot: return "アプリコット"
        case .gold: return "ゴールドイエロー"
        case .mintGreen: return "ミントグリーン"
        case .blue: return "明るいブルー"
        case .purple: return "ライトパープル"
        case .skyCyan: return "スカイシアン"
        case .lightBlue: return "ライトブルー"
        case .turquoise: return "ターコイズ"
        case .aquaMint: return "アクアミント"
        }
    }

    var color: Color {
        switch self {
        case .cyan: return Color(red: 0.24, green: 0.87, blue: 1)
        case .red: return Self.color(hex: 0xFF5252)
        case .coralRed: return Self.color(hex: 0xFF6B6B)
        case .rose: return Self.color(hex: 0xFF5C8A)
        case .pink: return Self.color(hex: 0xFF7AC8)
        case .apricot: return Self.color(hex: 0xFFAA5C)
        case .gold: return Self.color(hex: 0xFFD166)
        case .mintGreen: return Self.color(hex: 0x68E6A6)
        case .blue: return Self.color(hex: 0x66A6FF)
        case .purple: return Self.color(hex: 0xB388FF)
        case .skyCyan: return Self.color(hex: 0x00CFFF)
        case .lightBlue: return Self.color(hex: 0x4DCBFF)
        case .turquoise: return Self.color(hex: 0x32D6D0)
        case .aquaMint: return Self.color(hex: 0x4DE8D4)
        }
    }

    var menuImage: NSImage {
        let fill = NSColor(color)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func color(hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var lyricHighlightColour: LyricHighlightColour = .cyan
}
