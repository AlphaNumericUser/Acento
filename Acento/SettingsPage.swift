import AppKit
import AVFoundation
import Carbon
import ServiceManagement
import SwiftUI

private enum SettingsEditor: String, Identifiable {
    case shortcut, microphone, appearance, language
    var id: String { rawValue }
}

struct FlowSwitchStyle: ToggleStyle {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color.inkPrimary : Color.switchOff)
                .frame(width: 46, height: 26)
                .overlay {
                    Circle()
                        .fill(configuration.isOn ? Color.onAccent : Color.white)
                        .frame(width: 21, height: 21)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: configuration.isOn ? 10 : -10)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(FlowButtonStyle())
        .accessibilityLabel(L10n.text(configuration.isOn ? "On" : "Off", locale: locale))
    }
}

struct SettingsPage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var recorder: DictationController
    @ObservedObject var processor: AIProcessingStore
    @ObservedObject var modelStore: SpeechModelStore
    @AppStorage("shortcutKeyCode") private var shortcutKeyCode = 54
    @AppStorage("shortcutModifiers") private var shortcutModifiers = 0
    @AppStorage("shortcutLabel") private var shortcutLabel = "Right Command"
    @AppStorage("doubleTapFreeMode") private var doubleTapFreeMode = true
    @AppStorage("micID") private var micID = ""
    @AppStorage("soundsEnabled") private var soundsEnabled = true
    @AppStorage(SystemAudioMuter.settingKey) private var muteAudioWhileDictating = false
    @AppStorage("showBar") private var showBar = true
    @AppStorage("showDock") private var showDock = true
    @AppStorage("showModelsOnHome") private var showModelsOnHome = true
    @AppStorage("appLanguage") private var appLanguage = "es"
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.light.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var activeEditor: SettingsEditor?
    @State private var settingsError: String?
    @State private var draftKeyCode = 54
    @State private var draftModifiers = 0
    @State private var draftLabel = "Right Command"
    @State private var capturedShortcut = false
    @State private var shortcutError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(AppFonts.figtree(size: 28, weight: .semibold))
                    .padding(.bottom, 6)

                sectionTitle("Dictation")
                card {
                    row("Shortcut", subtitle: L10n.format(shortcutKeyCode == 57 ? "Press %@ to start or stop dictation" : "Hold %@ to dictate", locale: locale, ShortcutKey.displayLabel(shortcutLabel, locale: locale))) {
                        changeButton { openShortcutEditor() }
                    }
                    separator
                    row("Double-tap for hands-free", subtitle: "Tap your shortcut twice to keep recording after release") {
                        Toggle("Double-tap for hands-free", isOn: $doubleTapFreeMode)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                    }
                    separator
                    row("Microphone", subtitle: selectedMicrophone) {
                        changeButton { activeEditor = .microphone }
                    }
                }
                if let message = recorder.shortcutStatus {
                    Text(L10n.text(message, locale: locale))
                        .font(AppFonts.figtree(size: 13))
                        .foregroundStyle(Color.errorText)
                }

                sectionTitle("App settings")
                card {
                    row("Appearance", subtitle: (AppAppearance(rawValue: appAppearance) ?? .light).title) {
                        changeButton { activeEditor = .appearance }
                    }
                    separator
                    row("Launch app at login") {
                        Toggle("Launch app at login", isOn: $launchAtLogin)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                            .onChange(of: launchAtLogin) { _, enabled in
                                do {
                                    if enabled { try SMAppService.mainApp.register() }
                                    else { try SMAppService.mainApp.unregister() }
                                    settingsError = nil
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                    settingsError = error.localizedDescription
                                }
                            }
                    }
                    separator
                    row("Show dictation bar") {
                        Toggle("Show dictation bar", isOn: $showBar)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                    }
                    separator
                    row("Show app in dock") {
                        Toggle("Show app in dock", isOn: $showDock)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                    }
                    separator
                    row("Show models on Home", subtitle: "Shows which model transcribes and which provider polishes your dictations") {
                        Toggle("Show models on Home", isOn: $showModelsOnHome)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                    }
                    separator
                    row("App Language", subtitle: appLanguage == "es" ? "Español" : "English") {
                        changeButton { activeEditor = .language }
                    }
                    separator
                    offlineFallbackRow
                }
                if let settingsError {
                    Text(settingsError)
                        .font(AppFonts.figtree(size: 13))
                        .foregroundStyle(Color.errorText)
                }

                sectionTitle("Sound")
                card {
                    row("Dictation sounds", subtitle: "Play sounds when dictation starts and ends") {
                        Toggle("Dictation sounds", isOn: $soundsEnabled)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                    }
                    separator
                    row("Mute audio while dictating", subtitle: "Silences music and videos while you speak and restores them when you finish") {
                        Toggle("Mute audio while dictating", isOn: $muteAudioWhileDictating)
                            .toggleStyle(FlowSwitchStyle()).labelsHidden()
                    }
                }

                SignatureFooter(locale: locale)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            .foregroundStyle(Color.inkPrimary)
            .padding(38)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color.cardBackground)
        .sheet(item: $activeEditor, onDismiss: { recorder.isEditingShortcut = false }) { editor in
            Group {
                switch editor {
                case .shortcut: shortcutEditor
                case .microphone: microphoneEditor
                case .appearance:
                    selectionEditor("Appearance", items: AppAppearance.allCases.map(\.rawValue), selection: $appAppearance) {
                        L10n.text((AppAppearance(rawValue: $0) ?? .light).title, locale: locale)
                    }
                case .language:
                    selectionEditor("App Language", items: ["es", "en"], selection: $appLanguage) {
                        $0 == "es" ? "Español" : "English"
                    }
                }
            }
            .foregroundStyle(Color.inkPrimary)
            .background(Color.cardBackground)
            .appAppearance()
            .presentationBackground(Color.cardBackground)
        }
    }

    private var shortcutEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Configure shortcut")
                    .font(AppFonts.figtree(size: 22, weight: .semibold))
                Spacer()
                FlowModalCloseButton { activeEditor = nil }
            }
            Text("Press a key, with or without modifiers, to assign a shortcut.")
                .font(AppFonts.figtree(size: 13))
                .foregroundStyle(Color.inkSecondary)
            Divider()
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.insetBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.cardBorder))
                Text(capturedShortcut ? ShortcutKey.displayLabel(draftLabel, locale: locale) : L10n.format("Press your new shortcut here · %@", locale: locale, ShortcutKey.displayLabel(draftLabel, locale: locale)))
                    .font(AppFonts.figtree(size: 14))
                    .foregroundStyle(capturedShortcut ? Color.inkPrimary : Color.inkSecondary)
                KeyCaptureView(onCapture: { keyCode, modifiers, label in
                    draftKeyCode = keyCode
                    draftModifiers = modifiers
                    draftLabel = label
                    capturedShortcut = true
                    shortcutError = nil
                })
            }
            .frame(height: 46)
            if let shortcutError {
                Text(L10n.text(shortcutError, locale: locale))
                    .font(AppFonts.figtree(size: 13))
                    .foregroundStyle(Color.errorText)
            }
            HStack {
                Spacer()
                Button("Cancel") { activeEditor = nil }
                    .buttonStyle(FlowButtonStyle())
                Button { saveShortcutEditor() } label: {
                    Text("Save")
                        .font(AppFonts.figtree(size: 12, weight: .semibold))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Color.inkPrimary, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(FlowButtonStyle())
            }
        }
        .padding(28)
        .frame(width: 530)
    }

    private func openShortcutEditor() {
        recorder.isEditingShortcut = true
        draftKeyCode = shortcutKeyCode
        draftModifiers = shortcutModifiers
        draftLabel = shortcutLabel
        capturedShortcut = false
        shortcutError = nil
        activeEditor = .shortcut
    }

    private func saveShortcutEditor() {
        let previous = (shortcutKeyCode, shortcutModifiers, shortcutLabel)
        shortcutKeyCode = draftKeyCode
        shortcutModifiers = draftModifiers
        shortcutLabel = draftLabel
        recorder.isEditingShortcut = false
        if recorder.shortcutRegistrationFailed {
            shortcutError = recorder.shortcutStatus
            recorder.isEditingShortcut = true
            shortcutKeyCode = previous.0
            shortcutModifiers = previous.1
            shortcutLabel = previous.2
            return
        }
        activeEditor = nil
    }

    private var microphoneEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Choose microphone")
                    .font(AppFonts.figtree(size: 22, weight: .semibold))
                Spacer()
                FlowModalCloseButton { activeEditor = nil }
            }
            Divider()
            VStack(spacing: 0) {
                microphoneOption("Auto-detect", id: "")
                ForEach(MicrophoneDevices.all, id: \.uniqueID) { device in
                    separator
                    microphoneOption(device.localizedName, id: device.uniqueID)
                }
            }
            .padding(.horizontal, 16)
            .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(28)
        .frame(width: 440)
    }

    private var selectedMicrophone: String {
        MicrophoneDevices.all.first { $0.uniqueID == micID }?.localizedName ?? L10n.text("Auto-detect (system default)", locale: locale)
    }

    private func selectionEditor(_ title: String, items: [String], selection: Binding<String>, label: @escaping (String) -> String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(AppFonts.figtree(size: 22, weight: .semibold))
                Spacer()
                FlowModalCloseButton { activeEditor = nil }
            }
            Divider()
            VStack(spacing: 0) {
                ForEach(items, id: \.self) { item in
                    if item != items.first { separator }
                    Button {
                        selection.wrappedValue = item
                        activeEditor = nil
                    } label: {
                        HStack {
                            Text(label(item)).font(AppFonts.figtree(size: 13))
                            Spacer()
                            if selection.wrappedValue == item { Image(systemName: "checkmark") }
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FlowButtonStyle(pressScale: 0.99))
                }
            }
            .padding(.horizontal, 16)
            .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 11))
        }
        .padding(28)
        .frame(width: 440)
    }

    private var separator: some View { Color.cardBorder.frame(height: 1) }

    private func sectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title)).font(AppFonts.figtree(size: 16, weight: .semibold))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 20)
            .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 13))
    }

    private var offlineFallbackRow: some View {
        let local = modelStore.installedLocalModel
        let subtitle = local != nil
            ? "If you have a local model installed, it will transcribe and paste your dictation."
            : "Install a local model to keep dictating without internet."
        return row("Use a local model when there's no internet", subtitle: subtitle) {
            Toggle("Use a local model when there's no internet", isOn: Binding(
                get: { local != nil && modelStore.offlineFallbackEnabled },
                set: { modelStore.offlineFallbackEnabled = $0 }
            ))
            .toggleStyle(FlowSwitchStyle()).labelsHidden()
            .disabled(local == nil)
        }
    }

    private func row<Control: View>(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(title)).font(AppFonts.figtree(size: 14, weight: .medium))
                if let subtitle {
                    Text(L10n.text(subtitle, locale: locale))
                        .font(AppFonts.figtree(size: 13))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .frame(minHeight: 77)
    }

    private func changeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Change")
                .font(AppFonts.figtree(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkPrimary)
                .frame(width: 130, height: 36)
                .background(Color.buttonBackground, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
            .buttonStyle(FlowButtonStyle())
    }

    private func microphoneOption(_ name: String, id: String) -> some View {
        Button {
            micID = id
            activeEditor = nil
        } label: {
            HStack {
                Text(id.isEmpty ? L10n.text(name, locale: locale) : name)
                    .font(AppFonts.figtree(size: 13))
                Spacer()
                if micID == id { Image(systemName: "checkmark") }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlowButtonStyle(pressScale: 0.99))
    }
}

private struct SignatureFooter: View {
    let locale: Locale
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "Acento \(AppSignature.version) · " + L10n.text("Made with love by", locale: locale) + " ")
            Link(destination: AppSignature.authorURL) {
                Text(verbatim: AppSignature.authorName)
                    .underline(hovering)
                    .foregroundStyle(Color.inkFaint)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .help("github.com/AlphaNumericUser")
        }
        .font(AppFonts.figtree(size: 11))
        .foregroundStyle(Color.inkFaint)
    }
}
