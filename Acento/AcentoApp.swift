//
//  AcentoApp.swift
//  Acento
//
//  Created by Alfredo Diaz on 24/09/26.
//

import SwiftUI

@main
struct AcentoApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @AppStorage("appLanguage") private var appLanguage = "es"

    init() {
        // Disables macOS stem darkening so Figtree renders as thin as Wispr Flow's `-webkit-font-smoothing: antialiased`.
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
    }

    var body: some Scene {
        Window("Acento", id: MainWindowView.identifier) {
            MainWindowView(services: delegate.services)
                .environment(\.locale, Locale(identifier: appLanguage))
        }
        .defaultSize(width: 1080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.format("About %@", locale: Locale(identifier: appLanguage), "Acento")) {
                    AppSignature.showAboutPanel(locale: Locale(identifier: appLanguage))
                }
            }
            CommandGroup(replacing: .help) {
                Button(L10n.text("Send Feedback…", locale: Locale(identifier: appLanguage))) {
                    NotificationCenter.default.post(name: .acentoOpenSupport, object: nil)
                }
                Button(L10n.text("View on GitHub", locale: Locale(identifier: appLanguage))) {
                    NSWorkspace.shared.open(AppSignature.projectURL)
                }
            }
        }
    }
}

enum AppSignature {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static let authorName = "Alfredo Díaz"
    static let authorURL = URL(string: "https://github.com/AlphaNumericUser")!
    static let projectURL = URL(string: "https://github.com/AlphaNumericUser/Acento")!
    static let supportEndpoint = "https://acento-support.alfredo-diaz-dev.workers.dev"

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var fullVersion: String { "\(version) (\(build))" }

    static var macOSVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    static func showAboutPanel(locale: Locale) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: L10n.text("Made with love by", locale: locale) + " ", attributes: attributes)
        var linkAttributes = attributes
        linkAttributes[.link] = authorURL
        credits.append(NSAttributedString(string: authorName, attributes: linkAttributes))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

private struct MainWindowView: View {
    static let identifier = "main"
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: services.model, recorder: services.recorder,
                    modelStore: services.modelStore, processor: services.processor)
            .onAppear {
                // This callback only presents UI. Dictation setup lives at app scope.
                let open = openWindow
                services.openMainWindow = { open(id: Self.identifier) }
            }
    }
}
