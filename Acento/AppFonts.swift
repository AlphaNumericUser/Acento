import CoreText
import SwiftUI

/// Bundled typefaces (SIL OFL 1.1, see Fonts/*-OFL.txt), matching Wispr Flow: Figtree for UI text, EB Garamond for display numbers.
enum AppFonts {
    static let figtreeFamily = "Figtree"
    static let garamondFamily = "EB Garamond"

    private static let registered: Void = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("Figtree") || url.lastPathComponent.hasPrefix("EBGaramond") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func figtree(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registered
        return Font.custom(figtreeFamily, size: size).weight(weight)
    }

    static func garamond(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registered
        return Font.custom(garamondFamily, size: size).weight(weight)
    }
}
