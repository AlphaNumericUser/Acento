import AppKit
import SwiftUI

struct AIProcessingPage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var processor: AIProcessingStore
    @ObservedObject var modelStore: SpeechModelStore
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var editingProvider: AITextProvider?
    @State private var editingTemplate: AIPromptTemplateDraft?

    private var ready: Bool { modelStore.isReady && processor.hasKey }
    // Only lock the sections when the user turned polishing off; if a key is missing they must stay usable to fix it.
    private var sectionsDisabled: Bool { ready && !processor.settings.enabled }

    var body: some View {
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AI Processing").font(AppFonts.figtree(size: 28, weight: .semibold))
                    Text("Turn your dictations into ready-to-use text, in English or Spanish.")
                        .font(AppFonts.figtree(size: 14)).foregroundStyle(Color.inkSecondary)
                }

                card {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Automatic polish").font(AppFonts.figtree(size: 16, weight: .semibold))
                            Text(statusText).font(AppFonts.figtree(size: 12)).foregroundStyle(Color.inkSecondary)
                        }
                        Spacer(minLength: 12)
                        if ready && processor.settings.enabled && !network.isOnline {
                            Label("No connection", systemImage: "wifi.slash")
                                .font(AppFonts.figtree(size: 12, weight: .medium))
                                .foregroundStyle(Color.inkSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Color.hoverBackground, in: Capsule())
                        }
                        Text(LocalizedStringKey(ready && processor.settings.enabled ? "On" : "Off"))
                            .font(AppFonts.figtree(size: 12, weight: .medium))
                            .foregroundStyle(Color.inkSecondary)
                        Toggle("AI Processing", isOn: Binding(
                            get: { ready && processor.settings.enabled },
                            set: { processor.settings.enabled = $0 }
                        ))
                        .toggleStyle(FlowSwitchStyle()).labelsHidden()
                        .disabled(!ready)
                    }
                }

                section("Text provider", subtitle: "The model selected in Models transcribes the audio. Only the text is sent to this provider.") {
                    VStack(spacing: 12) {
                        ForEach(AITextProvider.allCases) { provider in
                            providerCard(provider)
                        }
                    }
                }
                .disabled(sectionsDisabled)
                .opacity(sectionsDisabled ? 0.45 : 1)
                .allowsHitTesting(!sectionsDisabled)
                .animation(.easeOut(duration: 0.15), value: sectionsDisabled)

                section("AI instructions", subtitle: "Choose how your dictation is edited, or create your own template.") {
                    CardPrimaryButton(title: "New template") {
                        editingTemplate = AIPromptTemplateDraft(id: UUID().uuidString, name: "", prompt: "", isNew: true)
                    }
                } content: {
                    VStack(spacing: 12) {
                        ForEach(processor.settings.templates) { template in
                            templateCard(template)
                        }
                    }
                }
                .disabled(sectionsDisabled)
                .opacity(sectionsDisabled ? 0.45 : 1)
                .allowsHitTesting(!sectionsDisabled)
                .animation(.easeOut(duration: 0.15), value: sectionsDisabled)

            }
            .padding(38)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .foregroundStyle(Color.inkPrimary)
            .background(Color.cardBackground)
            .onAppear {
                processor.refreshKey()
                for provider in AITextProvider.allCases {
                    AITextModelCatalog.shared.refreshIfStale(provider, key: CredentialStore.get(provider.credentialAccount))
                }
            }
            .sheet(item: $editingProvider) { provider in
                AITextProviderEditor(provider: provider, processor: processor)
                    .foregroundStyle(Color.inkPrimary)
                    .background(Color.cardBackground)
                    .appAppearance()
                    .presentationBackground(Color.cardBackground)
            }
            .sheet(item: $editingTemplate) { draft in
                AIPromptTemplateEditor(draft: draft, processor: processor)
                    .foregroundStyle(Color.inkPrimary)
                    .background(Color.cardBackground)
                    .appAppearance()
                    .presentationBackground(Color.cardBackground)
            }
    }

    private var statusText: String {
        if !modelStore.isReady { return L10n.text("Choose a dictation model in Models to enable polishing.", locale: locale) }
        if !processor.hasKey { return L10n.format("Configure a %@ API key to enable polishing.", locale: locale, processor.settings.provider.title) }
        if processor.settings.enabled && !network.isOnline {
            return L10n.text("No connection. Dictations will be pasted without AI polish until you're back online.", locale: locale)
        }
        return L10n.text(processor.settings.enabled ? "Each dictation will be polished after transcription." : "Dictations will be saved without AI processing.", locale: locale)
    }

    private func templateCard(_ template: AIPromptTemplate) -> some View {
        let selected = processor.settings.selectedTemplateID == template.id
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: template.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.inkPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.hoverBackground, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(template.displayName(locale: locale)).font(AppFonts.figtree(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Group {
                        if let summary = template.summary {
                            Text(LocalizedStringKey(summary))
                        } else {
                            Text(verbatim: template.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                        }
                    }
                    .font(AppFonts.figtree(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(2)
                }
                Spacer(minLength: 0)
                if selected {
                    ActiveStateBadge()
                } else {
                    CardPrimaryButton(title: "Use template") { processor.settings.selectedTemplateID = template.id }
                }
            }
            HStack(spacing: 8) {
                providerTag(template.isBuiltIn ? "Built-in" : "Custom", color: Color.inkSecondary)
                Spacer(minLength: 0)
                templateAction(template)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.selectedBackground : Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.selectedBorder : Color.cardBorder))
    }

    private func templateAction(_ template: AIPromptTemplate) -> some View {
        Button(LocalizedStringKey(template.isBuiltIn ? "View" : "Edit")) {
            editingTemplate = AIPromptTemplateDraft(id: template.id, name: template.displayName(locale: locale), prompt: template.prompt, isNew: false, isReadOnly: template.isBuiltIn)
        }
        .buttonStyle(.plain)
        .font(AppFonts.figtree(size: 11))
        .foregroundStyle(Color.inkSecondary)
        .pointerCursor()
    }

    private func providerCard(_ provider: AITextProvider) -> some View {
        let selected = processor.settings.provider == provider
        let hasKey = !(CredentialStore.get(provider.credentialAccount) ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                providerIcon(provider)
                VStack(alignment: .leading, spacing: 5) {
                    Text(provider.title).font(AppFonts.figtree(size: 16, weight: .semibold))
                    Text(LocalizedStringKey(provider.subtitle))
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 0)
                if selected && hasKey {
                    ActiveStateBadge()
                } else if hasKey {
                    CardPrimaryButton(title: "Use model") { processor.selectProvider(provider) }
                } else {
                    CardPrimaryButton(title: "Set up") { editingProvider = provider }
                }
            }
            HStack(spacing: 8) {
                if provider == .cerebras {
                    providerTag("Recommended", color: Color.inkPrimary, systemImage: "star.fill")
                }
                providerTag(hasKey ? "Key configured" : "Requires API key", color: Color.inkSecondary)
            }
            HStack {
                Text(verbatim: processor.settings.parameters(for: provider).model)
                    .font(AppFonts.figtree(size: 11))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                Spacer()
                if hasKey {
                    Button("Change settings") { editingProvider = provider }
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

    private func providerIcon(_ provider: AITextProvider) -> some View {
        let icon: Image
        let tint: AnyShapeStyle
        switch provider {
        case .cerebras:
            icon = Image(systemName: "c.circle.fill")
            tint = AnyShapeStyle(Color(hex: 0xE76736))
        case .openAI:
            icon = Image("BrandOpenAI")
            tint = AnyShapeStyle(Color.inkPrimary)
        case .gemini:
            icon = Image("BrandGemini")
            tint = AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x4086F4), Color(hex: 0x9F5BE8), Color(hex: 0xE88DA4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .openRouter:
            icon = Image("BrandOpenRouter")
            tint = AnyShapeStyle(Color(hex: 0x6366F1))
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

    private func providerTag(_ value: String, color: Color, background: Color = Color.hoverBackground, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(LocalizedStringKey(value))
        }
            .font(AppFonts.figtree(size: 10, weight: systemImage == nil ? .medium : .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(background, in: Capsule())
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.cardBorder))
    }

    private func section<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(_ title: String, subtitle: String,
                                                         @ViewBuilder accessory: () -> Accessory,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 13) {
                    Text(LocalizedStringKey(title)).font(AppFonts.figtree(size: 16, weight: .semibold))
                    Text(LocalizedStringKey(subtitle)).font(AppFonts.figtree(size: 12)).foregroundStyle(Color.inkSecondary)
                }
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
    }

}

private struct AITextProviderEditor: View {
    @Environment(\.locale) private var locale
    let provider: AITextProvider
    @ObservedObject var processor: AIProcessingStore
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var error: String?
    @State private var parameters: AIProviderParameters
    @ObservedObject private var catalog = AITextModelCatalog.shared

    private let savedKey: String
    private let savedParameters: AIProviderParameters

    init(provider: AITextProvider, processor: AIProcessingStore) {
        self.provider = provider
        self.processor = processor
        let parameters = processor.settings.parameters(for: provider)
        savedParameters = parameters
        _parameters = State(initialValue: parameters)
        // The saved key fills the secure field so it shows as dots; it can't be revealed or copied.
        savedKey = CredentialStore.get(provider.credentialAccount) ?? ""
        _newKey = State(initialValue: savedKey)
    }

    private var hasKey: Bool { !savedKey.isEmpty }
    private var typedKey: String { newKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyChanged: Bool { !typedKey.isEmpty && typedKey != savedKey }
    private var isActive: Bool { processor.settings.provider == provider }
    private var hasChanges: Bool { keyChanged || parameters != savedParameters }
    /// Without edits the button only makes sense to switch to this provider.
    private var canSave: Bool { (hasKey || !typedKey.isEmpty) && (hasChanges || !isActive) }
    private var reasoningOptions: [String] { parameters.reasoningOptions(for: provider) }
    private var loadingModels: Bool { catalog.loading.contains(provider) }
    private var activeKey: String? {
        let typed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? CredentialStore.get(provider.credentialAccount) : typed
    }
    private var modelItems: [String] {
        _ = catalog.revision
        let models = catalog.models(for: provider)
        return models.contains(parameters.model) ? models : [parameters.model] + models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(provider.title).font(AppFonts.figtree(size: 22, weight: .semibold))
                Spacer()
                FlowModalCloseButton { dismiss() }
            }
            Text("Set up this provider to polish dictations using your own key.")
                .font(AppFonts.figtree(size: 13))
                .foregroundStyle(Color.inkSecondary)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("Provider")
                    Spacer()
                    Text(provider.title).foregroundStyle(Color.inkSecondary)
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
                Divider()
                parameterRow("Text model") {
                    FlowMenuPicker(title: "Text model", selection: $parameters.model, items: modelItems, width: 230, alwaysDropdown: true)
                        .onChange(of: parameters.model) { _, _ in
                            parameters.reasoningEffort = AITextModelCapabilities.defaultReasoning(reasoningOptions)
                        }
                        .overlay(alignment: .leading) {
                            if loadingModels && catalog.lastUpdated(provider) == nil {
                                ProgressView().controlSize(.small).offset(x: -26)
                            }
                        }
                }
                Divider()
                parameterRow("Reasoning effort") {
                    if reasoningOptions.isEmpty {
                        Text("Not supported by this model").foregroundStyle(Color.inkSecondary)
                    } else {
                        FlowMenuPicker(title: "Reasoning effort", selection: $parameters.reasoningEffort,
                                       items: reasoningOptions,
                                       label: { L10n.text($0 == "default" ? "Auto" : $0.capitalized, locale: locale) })
                    }
                }
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
                Link("Get API key ↗", destination: provider.keyURL)
                    .pointerCursor()
            }
            .font(AppFonts.figtree(size: 11))
            if let error = error ?? catalog.errors[provider] {
                Text(error).font(AppFonts.figtree(size: 12)).foregroundStyle(Color.errorText)
            }
            HStack {
                if hasKey {
                    Button("Remove key", action: removeKey)
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.errorText)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .pointerCursor()
                Button(action: save) {
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
        // Stale-while-revalidate: cached models show instantly; stale lists refresh silently, new keys once typing settles.
        .task(id: newKey) {
            guard keyChanged else { return catalog.refreshIfStale(provider, key: activeKey) }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await catalog.refresh(provider, key: activeKey)
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if keyChanged {
                let key = typedKey
                try CredentialStore.set(key, for: provider.credentialAccount)
                Task { await AITextModelCatalog.shared.refresh(provider, key: key) }
            }
            processor.settings.use(provider, parameters: parameters)
            processor.refreshKey()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func parameterRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title)).font(AppFonts.figtree(size: 13))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 52)
    }

    private func removeKey() {
        do {
            try CredentialStore.set("", for: provider.credentialAccount)
            processor.refreshKey()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AIPromptTemplateDraft: Identifiable {
    var id: String
    var name: String
    var prompt: String
    var isNew: Bool
    /// The built-in template can only be viewed; users write their own with "New template".
    var isReadOnly = false
}

private extension AIPromptTemplate {
    var symbol: String {
        switch id {
        case Self.naturalID: "wand.and.stars"
        default: "doc.text"
        }
    }

    var summary: String? {
        switch id {
        case Self.naturalID: "Removes fillers and fixes punctuation, spelling, and self-corrections."
        default: nil
        }
    }

    func displayName(locale: Locale) -> String {
        isBuiltIn || name == Self.migratedName ? L10n.text(name, locale: locale) : name
    }
}

private struct AIPromptTemplateEditor: View {
    @State private var draft: AIPromptTemplateDraft
    @ObservedObject var processor: AIProcessingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private let original: AIPromptTemplateDraft

    init(draft: AIPromptTemplateDraft, processor: AIProcessingStore) {
        _draft = State(initialValue: draft)
        original = draft
        self.processor = processor
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPrompt: String { draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Opening a template (or a duplicate) and saving without edits must not create or rewrite anything.
    private var hasChanges: Bool { draft.name != original.name || draft.prompt != original.prompt }
    private var canSave: Bool { !draft.isReadOnly && !trimmedName.isEmpty && !trimmedPrompt.isEmpty && hasChanges }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(draft.isReadOnly ? draft.name : L10n.text(draft.isNew ? "New template" : "Edit template", locale: locale))
                    .font(AppFonts.figtree(size: 22, weight: .semibold))
                Spacer()
                FlowModalCloseButton { dismiss() }
            }
            Text(LocalizedStringKey(draft.isReadOnly
                ? "Built-in template. It can't be edited; create a new template to write your own instructions."
                : "These instructions tell the AI how to edit each dictation."))
                .font(AppFonts.figtree(size: 13))
                .foregroundStyle(Color.inkSecondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(AppFonts.figtree(size: 13, weight: .medium))
                if draft.isReadOnly {
                    Text(draft.name)
                        .font(AppFonts.figtree(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.cardBorder))
                } else {
                    TextField(LocalizedStringKey("Template name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Instructions").font(AppFonts.figtree(size: 13, weight: .medium))
                promptField
                    .frame(height: 320)
                    .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.cardBorder))
                    .overlay(alignment: .topLeading) {
                        if draft.prompt.isEmpty {
                            Text("Describe how the AI should edit your dictation…")
                                .font(AppFonts.figtree(size: 13))
                                .foregroundStyle(Color.inkFaint)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
            }
            if draft.isReadOnly {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Text("Close")
                            .font(AppFonts.figtree(size: 12, weight: .semibold))
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.inkPrimary, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            } else {
            HStack {
                if !draft.isNew {
                    Button("Delete template", action: delete)
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .font(AppFonts.figtree(size: 12))
                        .foregroundStyle(Color.errorText)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .pointerCursor()
                Button(action: save) {
                    Text("Save and use")
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
        }
        .padding(28)
        .frame(width: 560)
    }

    @ViewBuilder private var promptField: some View {
        if draft.isReadOnly {
            ScrollView {
                Text(draft.prompt)
                    .font(AppFonts.figtree(size: 13))
                    .foregroundStyle(Color.inkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        } else {
            TextEditor(text: $draft.prompt)
                .font(AppFonts.figtree(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
        }
    }

    private func save() {
        guard canSave else { return }
        let template = AIPromptTemplate(id: draft.id, name: trimmedName, prompt: trimmedPrompt)
        if let index = processor.settings.customTemplates.firstIndex(where: { $0.id == draft.id }) {
            processor.settings.customTemplates[index] = template
        } else {
            processor.settings.customTemplates.append(template)
        }
        processor.settings.selectedTemplateID = template.id
        dismiss()
    }

    private func delete() {
        processor.settings.customTemplates.removeAll { $0.id == draft.id }
        if processor.settings.selectedTemplateID == draft.id {
            processor.settings.selectedTemplateID = AIPromptTemplate.naturalID
        }
        dismiss()
    }
}
