import AppKit
import SwiftUI

/// Saved appearance choice for the native player and its Liquid Glass surfaces.
enum PlayerAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "システム設定に合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    func nsAppearance(systemColorScheme: ColorScheme) -> NSAppearance? {
        switch self {
        case .system: NSAppearance(named: systemColorScheme == .dark ? .darkAqua : .aqua)
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
