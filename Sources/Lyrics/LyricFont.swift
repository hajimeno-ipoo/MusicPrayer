import AppKit
import CoreText
import SwiftUI

enum LyricFont: String, CaseIterable, Identifiable {
    case system
    case furifont

    static let preferenceKey = "lyricDisplayFont"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "システムフォント"
        case .furifont: "Furifont Sans VF"
        }
    }

    private static let furifontDescriptor: NSFontDescriptor = {
        guard let url = Bundle.module.url(forResource: "FurifontSansVF", withExtension: "ttf", subdirectory: "Fonts") else {
            preconditionFailure("Bundled FurifontSansVF.ttf is missing")
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        let registrationError = error?.takeRetainedValue()
        precondition(registered || registrationError.map { CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue } == true,
                     "Unable to register bundled FurifontSansVF.ttf")
        guard let font = NSFont(name: "FurifontSansVF-Medium", size: 32) else {
            preconditionFailure("Bundled FurifontSansVF-Medium is unavailable")
        }
        return font.fontDescriptor
    }()

    func nativeFont(size: CGFloat) -> NSFont {
        switch self {
        case .system: return .systemFont(ofSize: size, weight: .medium)
        case .furifont: return NSFont(descriptor: Self.furifontDescriptor, size: size)!
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size, weight: .medium)
        case .furifont: return Font(nativeFont(size: size))
        }
    }
}
