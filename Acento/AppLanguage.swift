import Foundation

nonisolated enum AppLanguage {
    static var code: String {
        UserDefaults.standard.string(forKey: "appLanguage") == "en" ? "en" : "es"
    }

    static var locale: Locale { Locale(identifier: code) }

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "bilingualInterfaceEnabled") else { return }
        defaults.set("es", forKey: "appLanguage")
        defaults.set(true, forKey: "bilingualInterfaceEnabled")
    }
}

nonisolated enum L10n {
    static func text(_ key: String, locale: Locale = AppLanguage.locale) -> String {
        let code = locale.language.languageCode?.identifier == "en" ? "en" : "es"
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, locale: Locale = AppLanguage.locale, _ arguments: CVarArg...) -> String {
        String(format: text(key, locale: locale), locale: locale, arguments: arguments)
    }
}
