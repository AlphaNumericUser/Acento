import AppKit
import SwiftUI

struct ModelsPage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var store: SpeechModelStore
    @State private var tab = 0
    @State private var editingProvider: SpeechModel?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Dictation models")
                        .font(AppFonts.figtree(size: 28, weight: .semibold))
                    Text("Your voice, your choice. Run models on your Mac or connect your own API.")
                        .font(AppFonts.figtree(size: 14))
                        .foregroundStyle(Color.inkSecondary)
                }

                HStack(spacing: 4) {
                    tabButton("On your Mac", value: 0)
                    tabButton("In the cloud", value: 1)
                    Spacer()
                    Text(LocalizedStringKey(tab == 0 ? "Audio stays on your Mac" : "API requests send audio to your provider"))
                        .font(AppFonts.figtree(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.leading, 8)
                        .padding(.trailing, 13)
                }
                .padding(4)
                .background(Color.hoverBackground, in: RoundedRectangle(cornerRadius: 11))

                if let error = store.error {
                    Text(error)
                        .font(AppFonts.figtree(size: 13))
                        .foregroundStyle(Color.errorText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.errorBackground, in: RoundedRectangle(cornerRadius: 9))
                }

                VStack(spacing: 12) {
                    ForEach(SpeechModel.allCases.filter { $0.isLocal == (tab == 0) }) { model in
                        if model.isLocal { modelCard(model) }
                        else { apiCard(model) }
                    }
                }

                Text(LocalizedStringKey(tab == 0
                     ? "Accuracy and speed are general guidance, not comparable benchmark scores. Download sizes are estimates and depend on model version and Core ML assets. Check each model's source for license details."
                      : "API requests may incur provider charges. Your keys are stored in macOS Keychain."))
                    .font(AppFonts.figtree(size: 11))
                    .foregroundStyle(Color.inkFaint)
            }
            .padding(38)
            .frame(maxWidth: 1050, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Color.inkPrimary)
        .background(Color.cardBackground)
        .sheet(item: $editingProvider) { provider in
            APIProviderEditor(model: provider, store: store)
                .foregroundStyle(Color.inkPrimary)
                .background(Color.cardBackground)
                .appAppearance()
                .presentationBackground(Color.cardBackground)
        }
    }

    private func tabButton(_ title: String, value: Int) -> some View {
        Button { tab = value } label: {
            Text(LocalizedStringKey(title))
                .font(AppFonts.figtree(size: 13, weight: .semibold))
                .frame(width: 100, height: 33)
                .background(tab == value ? Color.cardBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }

    private func modelCard(_ model: SpeechModel) -> some View {
        let ready = store.installed.contains(model.id)
        let selected = store.selectedID == model.id
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                brandIcon(model)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title).font(AppFonts.figtree(size: 16, weight: .semibold))
                    Text(LocalizedStringKey(model.subtitle))
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 0)
                if selected && ready {
                    ActiveStateBadge()
                } else if ready {
                    primaryButton("Use model", muted: false) { store.selectedID = model.id }
                } else if model == .apple && !store.appleModelDownloadable {
                    Text("Not available for this Mac language")
                        .font(AppFonts.figtree(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                } else {
                    let activate = model == .apple && store.appleModelOnDisk
                    primaryButton(store.busy.contains(model.id) ? (activate ? "Activating…" : "Downloading…")
                                  : (activate ? "Activate" : "Download"), muted: false) {
                        Task { await store.download(model) }
                    }
                    .disabled(store.busy.contains(model.id))
                }
            }
            if let progress = store.progress[model.id] {
                DownloadProgressBar(value: progress)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                if model == .apple {
                    tag("Recommended", color: Color.inkPrimary, systemImage: "star.fill")
                } else {
                    tag(model.size, color: Color.inkSecondary)
                }
                tag(appleLanguage(for: model) ?? model.languages, color: Color.inkSecondary)
                tag(L10n.format("Accuracy: %@", locale: locale, L10n.text(model.accuracy == "High" ? "High accuracy" : model.accuracy, locale: locale)), color: Color.inkSecondary)
                tag(L10n.format("Speed: %@", locale: locale, L10n.text(model.speed, locale: locale)), color: Color.inkSecondary)
                Spacer(minLength: 0)
            }
            Text(L10n.text(model.features, locale: locale))
                .font(AppFonts.figtree(size: 11))
                .foregroundStyle(Color.inkSecondary)
            HStack {
                Link(L10n.text(model.license, locale: locale) + " ↗", destination: model.source)
                    .font(AppFonts.figtree(size: 11))
                    .foregroundStyle(Color.inkSecondary)
                    .pointerCursor()
                Spacer()
                if ready {
                    Button(model == .apple ? "Remove from Acento" : "Remove files") { store.remove(model) }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .font(AppFonts.figtree(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
        }
        .padding(17)
        .animation(.easeInOut(duration: 0.2), value: store.progress[model.id] != nil)
        .background(selected ? Color.selectedBackground : Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.selectedBorder : Color.cardBorder))
    }

    /// Apple's model follows the Mac language, so the card names it instead of a generic label.
    private func appleLanguage(for model: SpeechModel) -> String? {
        guard model == .apple, let id = store.appleModelLocale else { return nil }
        return locale.localizedString(forIdentifier: id) ?? id
    }

    private func apiCard(_ model: SpeechModel) -> some View {
        let ready = store.installed.contains(model.id)
        let selected = store.selectedID == model.id
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                brandIcon(model)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(model.title).font(AppFonts.figtree(size: 16, weight: .semibold))
                    }
                    Text(LocalizedStringKey(model.subtitle))
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 0)
                if selected && ready {
                    ActiveStateBadge()
                } else if ready {
                    primaryButton("Use model", muted: false) { store.selectedID = model.id }
                } else {
                    primaryButton("Set up", muted: false) { editingProvider = model }
                }
            }
            HStack(spacing: 8) {
                tag(ready ? "Key configured" : "Requires API key", color: Color.inkSecondary)
            }
            HStack {
                Text(L10n.text(model.features, locale: locale))
                    .font(AppFonts.figtree(size: 11))
                    .foregroundStyle(Color.inkSecondary)
                Spacer()
                if ready {
                    Button("Change settings") { editingProvider = model }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .font(AppFonts.figtree(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.selectedBackground : Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.selectedBorder : Color.cardBorder))
    }

    private func tag(_ value: String, color: Color, background: Color = Color.hoverBackground, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(LocalizedStringKey(value))
        }
            .font(AppFonts.figtree(size: 10, weight: systemImage == nil ? .medium : .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(background, in: Capsule())
    }

    private func primaryButton(_ title: String, muted: Bool, action: @escaping () -> Void) -> some View {
        CardPrimaryButton(title: title, muted: muted, action: action)
    }

    private func brandIcon(_ model: SpeechModel) -> some View {
        let icon: Image
        let tint: AnyShapeStyle
        switch model {
        case .apple:
            icon = Image(systemName: "apple.logo")
            tint = AnyShapeStyle(Color.inkPrimary)
        case .parakeetV3:
            icon = Image("BrandNVIDIA")
            tint = AnyShapeStyle(Color(hex: 0x76B900))
        case .whisperTiny, .whisperBase, .whisperTurbo, .openAI:
            icon = Image("BrandOpenAI")
            tint = AnyShapeStyle(Color.inkPrimary)
        case .openRouter:
            icon = Image("BrandOpenRouter")
            tint = AnyShapeStyle(Color(hex: 0x6366F1))
        case .gemini:
            icon = Image("BrandGemini")
            tint = AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4086F4), Color(hex: 0x9F5BE8), Color(hex: 0xE88DA4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .groq:
            icon = Image(systemName: "bolt.fill")
            tint = AnyShapeStyle(Color(hex: 0xF55036))
        }
        return icon
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(tint)
            .frame(width: 25, height: 25)
            .frame(width: 44, height: 44)
            .background(Color.hoverBackground, in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct APIProviderEditor: View {
    @Environment(\.locale) private var locale
    let model: SpeechModel
    @ObservedObject var store: SpeechModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var detectLanguage = true
    @State private var groqModel = GroqTranscriptionModel.turbo
    @State private var error: String?

    @State private var savedKey = ""

    private var hasKey: Bool { !savedKey.isEmpty }
    private var typedKey: String { newKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyChanged: Bool { !typedKey.isEmpty && typedKey != savedKey }
    private var isActive: Bool { store.selectedID == model.id }
    private var hasChanges: Bool {
        keyChanged
            || detectLanguage != SpeechLanguagePreferences.autoDetect(for: model)
            || (model == .groq && groqModel != GroqTranscriptionModel.current)
    }
    /// Without edits the button only makes sense to switch to this provider.
    private var canSave: Bool { (hasKey || !typedKey.isEmpty) && (hasChanges || !isActive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(model.title).font(AppFonts.figtree(size: 22, weight: .semibold))
                Spacer()
                FlowModalCloseButton { dismiss() }
            }
            Text("Set up this provider to dictate using your own key.")
                .font(AppFonts.figtree(size: 13))
                .foregroundStyle(Color.inkSecondary)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("Provider")
                    Spacer()
                    Text(model.title).foregroundStyle(Color.inkSecondary)
                }
                .frame(minHeight: 52)
                Divider()
                HStack(spacing: 12) {
                    Text("API key")
                    Spacer(minLength: 16)
                    SecureField(LocalizedStringKey("Paste your API key"), text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }
                .frame(minHeight: 62)
                if model == .groq {
                    Divider()
                    HStack(spacing: 12) {
                        Text("Model")
                        Spacer(minLength: 16)
                        FlowMenuPicker(title: "Model", selection: $groqModel, items: GroqTranscriptionModel.allCases,
                                       label: { L10n.text($0.label, locale: locale) }, width: 250, alwaysDropdown: true)
                    }
                    .frame(minHeight: 62)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Language detection")
                        Text(detectLanguage ? L10n.text("Automatic", locale: locale) : L10n.format("Mac language: %@", locale: locale, locale.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))
                            .font(AppFonts.figtree(size: 11))
                            .foregroundStyle(Color.inkSecondary)
                    }
                    Spacer()
                    Toggle("Language detection", isOn: $detectLanguage)
                        .toggleStyle(FlowSwitchStyle()).labelsHidden()
                }
                .frame(minHeight: 62)
            }
            .font(AppFonts.figtree(size: 13))
            .padding(.horizontal, 16)
            .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 11))
            HStack {
                if hasKey {
                    Label("Key saved in Keychain", systemImage: "key.fill")
                        .foregroundStyle(Color.inkSecondary)
                } else {
                    Text("An API key is required to use this provider.")
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer()
                Link("Get API key ↗", destination: model.source)
                    .pointerCursor()
            }
            .font(AppFonts.figtree(size: 11))
            if let error {
                Text(error).font(AppFonts.figtree(size: 12)).foregroundStyle(Color.errorText)
            }
            HStack {
                if hasKey {
                    Button("Remove key") { removeKey() }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.errorText)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .pointerCursor()
                Button { save() } label: {
                    Text(LocalizedStringKey(hasChanges || isActive ? "Save and use" : "Use provider"))
                        .font(AppFonts.figtree(size: 12, weight: .semibold))
                        .foregroundStyle(canSave ? Color.onAccent : Color.inkPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(canSave ? Color.inkPrimary : Color.disabledBackground, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .onHover { ($0 && canSave ? NSCursor.pointingHand : NSCursor.arrow).set() }
            }
        }
        .padding(28)
        .frame(width: 530)
        .noInitialFocus()
        .onAppear {
            detectLanguage = SpeechLanguagePreferences.autoDetect(for: model)
            groqModel = GroqTranscriptionModel.current
            // The saved key fills the secure field so it shows as dots; it can't be revealed or copied.
            savedKey = CredentialStore.get(model) ?? ""
            newKey = savedKey
        }
    }

    private func save() {
        do {
            if keyChanged { try CredentialStore.set(typedKey, for: model) }
            SpeechLanguagePreferences.setAutoDetect(detectLanguage, for: model)
            if model == .groq { GroqTranscriptionModel.current = groqModel }
            store.selectedID = model.id
            store.error = nil
            store.refresh()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func removeKey() {
        do {
            try CredentialStore.set("", for: model)
            if store.selectedID == model.id { store.selectedID = nil }
            store.error = nil
            store.refresh()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Indeterminate shimmer until real progress arrives, then a smoothly animated fill with a percentage.
private struct DownloadProgressBar: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var determinate: Bool { value >= 0.02 }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hoverBackground)
                    if determinate {
                        Capsule()
                            .fill(Color.inkPrimary)
                            .frame(width: max(6, proxy.size.width * min(1, value)))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: value)
                    } else {
                        TimelineView(.animation(paused: reduceMotion)) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
                            let width = proxy.size.width * 0.28
                            Capsule()
                                .fill(Color.inkPrimary.opacity(0.75))
                                .frame(width: width)
                                .offset(x: -width + (proxy.size.width + width) * phase)
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            Text(determinate ? "\(Int((min(1, value) * 100).rounded())) %" : L10n.text("Preparing…"))
                .font(AppFonts.figtree(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.inkSecondary)
                .frame(minWidth: 64, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: Int(value * 100))
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Downloading…"))
        .accessibilityValue(determinate ? "\(Int(value * 100)) %" : L10n.text("Preparing…"))
    }
}
