import AppKit
import CoreText
import SwiftUI

enum LyricFont: String, CaseIterable, Identifiable {
    case system
    case furifont
    case rubifont

    static let preferenceKey = "lyricDisplayFont"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "システムフォント"
        case .furifont: "Furifont Sans VF"
        case .rubifont: "Rubifont Sans VF"
        }
    }

    private static let furifontDescriptor = bundledDescriptor(resource: "FurifontSansVF", name: "FurifontSansVF-Medium")
    private static let rubifontDescriptor = bundledDescriptor(resource: "RubifontSansVF", name: "RubifontSansVF-Medium")

    var licenseResource: String? {
        switch self {
        case .system: nil
        case .furifont: "Furifont-LICENSES"
        case .rubifont: "Rubifont-LICENSES"
        }
    }

    private static func bundledDescriptor(resource: String, name: String) -> NSFontDescriptor {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "ttf", subdirectory: "Fonts") else {
            preconditionFailure("Bundled \(resource).ttf is missing")
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        let registrationError = error?.takeRetainedValue()
        precondition(registered || registrationError.map { CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue } == true,
                     "Unable to register bundled \(resource).ttf")
        guard let font = NSFont(name: name, size: 32) else {
            preconditionFailure("Bundled \(name) is unavailable")
        }
        return font.fontDescriptor
    }

    func nativeFont(size: CGFloat) -> NSFont {
        switch self {
        case .system: return .systemFont(ofSize: size, weight: .medium)
        case .furifont: return NSFont(descriptor: Self.furifontDescriptor, size: size)!
        case .rubifont: return NSFont(descriptor: Self.rubifontDescriptor, size: size)!
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size, weight: .medium)
        case .furifont, .rubifont: return Font(nativeFont(size: size))
        }
    }
}
