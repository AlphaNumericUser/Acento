import SwiftUI

enum AppAppearance: String, CaseIterable {
    case light, dark, system

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appAppearance") private var appearance = AppAppearance.light.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme((AppAppearance(rawValue: appearance) ?? .light).colorScheme)
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }
}
