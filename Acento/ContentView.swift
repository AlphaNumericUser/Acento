import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: DictationController
    @ObservedObject var modelStore: SpeechModelStore
    @ObservedObject var processor: AIProcessingStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let hasTitlebarInset = geometry.safeAreaInsets.top > 0
            let verticalMargin = hasTitlebarInset
                ? max(geometry.safeAreaInsets.top, geometry.safeAreaInsets.bottom) + 2
                : max(20, geometry.safeAreaInsets.bottom + 8)
            let sideMargin: CGFloat = hasTitlebarInset ? 8 : 16
            // Only the top needs room for the traffic lights; the bottom matches the sides.
            let bottomMargin = max(sideMargin, geometry.safeAreaInsets.bottom)

            ZStack {
                PaperBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        sidebar
                            .frame(minWidth: 184)
                            .fixedSize(horizontal: true, vertical: false)
                        Group {
                            switch model.page {
                            case .dictation: DictationPage(model: model, recorder: recorder, modelStore: modelStore, processor: processor)
                            case .dictionary: DictionaryPage(model: model)
                            case .models: ModelsPage(store: modelStore)
                            case .processing: AIProcessingPage(processor: processor, modelStore: modelStore)
                            case .help: HelpPage()
                            case .settings: SettingsPage(recorder: recorder, processor: processor, modelStore: modelStore)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .scrollEdgeEffectHidden(for: .top)
                        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.cardBorder))
                    }
                    .padding(.horizontal, sideMargin)
                    .padding(.top, verticalMargin - geometry.safeAreaInsets.top)
                    .padding(.bottom, bottomMargin - geometry.safeAreaInsets.bottom)
                }

                if let pending = model.pendingDeletion {
                    DeletionNotice(model: model, message: pending.message)
                        .id(pending.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, bottomMargin + 18)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
                                                                 .combined(with: .offset(y: 6)))
                }

            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.05) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.28), value: model.pendingDeletion)
        .frame(minWidth: 1000, minHeight: 690)
        .onReceive(NotificationCenter.default.publisher(for: .acentoOpenSupport)) { _ in model.page = .help }
        .font(AppFonts.figtree(size: 13))
        .appAppearance()
        .overlayPreferenceValue(TooltipPreferenceKey.self) { tooltip in
            GeometryReader { geometry in
                if let tooltip {
                    let rect = geometry[tooltip.bounds]
                    let width = min(250, max(96, CGFloat(tooltip.text.count) * 7 + 24))
                    let height: CGFloat = tooltip.text.count > 32 ? 52 : 36
                    let above = rect.minY > height + 12
                    Text(tooltip.text)
                        .font(AppFonts.figtree(size: 12, weight: .medium))
                        .foregroundStyle(Color.onAccent)
                        .multilineTextAlignment(.center)
                        .frame(width: width)
                        .padding(.vertical, 8)
                        .background(Color.inkPrimary, in: RoundedRectangle(cornerRadius: 8))
                        .position(
                            x: min(max(rect.midX, width / 2 + 8), geometry.size.width - width / 2 - 8),
                            y: above ? rect.minY - height / 2 - 6 : rect.maxY + height / 2 + 6
                        )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image("AppLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(verbatim: "Acento")
                    .font(AppFonts.figtree(size: 21, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.bottom, 24)
            .padding(.leading, 8)

            sidebarButton("Home", icon: "mic", selected: model.page == .dictation) {
                model.page = .dictation
            }
            sidebarButton("Dictionary", icon: "character.book.closed", selected: model.page == .dictionary) {
                model.page = .dictionary
            }
            sidebarButton("Models", icon: "waveform.badge.magnifyingglass", selected: model.page == .models) {
                model.page = .models
            }
            sidebarButton("AI Processing", icon: "sparkles", selected: model.page == .processing) {
                model.page = .processing
            }

            Spacer()
            Rectangle().fill(Color.cardBorder).frame(height: 1).padding(.bottom, 8)
            sidebarButton("Help", icon: "questionmark.circle", selected: model.page == .help) {
                model.page = .help
            }
            sidebarButton("Settings", icon: "gearshape", selected: model.page == .settings) {
                model.page = .settings
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .foregroundStyle(Color.inkPrimary)
    }

    private func sidebarButton(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SidebarButton(title: title, icon: icon, selected: selected, action: action)
    }
}

/// Sidebar item styled after Wispr Flow: Figtree Medium, regular-weight outline icons, compact rows.
private struct SidebarButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let titleFont = AppFonts.figtree(size: 14, weight: .medium)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 20)
                Text(LocalizedStringKey(title))
                    .font(Self.titleFont)
                    .lineLimit(1)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Color.hoverBackground : hovering ? Color.hoverBackground.opacity(0.55) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.16), value: hovering)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.18), value: selected)
        }
        .buttonStyle(FlowButtonStyle(pressScale: 0.98))
        .onHover { hovering = $0 }
    }
}

/// Precomputed history row: grouping, audio lookup and card position are resolved once per history change, not per frame.
struct HistoryRowItem: Identifiable {
    let entry: DictationEntry
    let audioURL: URL?
    let isFirst: Bool
    let isLast: Bool
    var id: UUID { entry.id }
}

struct HistorySectionItem: Identifiable {
    let id: String
    let title: String
    let isToday: Bool
    let rows: [HistoryRowItem]
}

struct DictationPage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: DictationController
    @ObservedObject var modelStore: SpeechModelStore
    @ObservedObject var processor: AIProcessingStore
    @AppStorage("showModelsOnHome") private var showModelsOnHome = true
    @ObservedObject private var playback = AudioPlayback.shared
    @State private var searching = false
    @State private var search = ""
    @State private var sections: [HistorySectionItem] = []
    @State private var totalWordsCount = 0
    @State private var totalDictationsCount = 0

    private func rebuildHistory() {
        let history = model.history
        totalWordsCount = history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        totalDictationsCount = history.reduce(0) { $0 + ($1.text.isEmpty ? 0 : 1) }
        let filtered = search.isEmpty ? history : history.filter { $0.text.localizedCaseInsensitiveContains(search) }
        sections = DictationDaySection.group(filtered).map { section in
            let count = section.entries.count
            return HistorySectionItem(
                id: section.id,
                title: section.title(locale: locale),
                isToday: section.isToday,
                rows: section.entries.enumerated().map { index, entry in
                    HistoryRowItem(entry: entry, audioURL: RecordingStorage.existingURL(for: entry.audioFile),
                                   isFirst: index == 0, isLast: index == count - 1)
                }
            )
        }
    }

    var body: some View {
        let canTranscribe = modelStore.isReady && recorder.phase == .idle
        ScrollView(.vertical, showsIndicators: false) {
            // One flat lazy stack (headers + rows) so only on-screen rows are built and measured.
            LazyVStack(alignment: .leading, spacing: 0) {
                statsCard
                if let message = recorder.message {
                    Text(L10n.text(message, locale: locale))
                        .font(AppFonts.figtree(size: 13))
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.top, 32)
                }

                ForEach(sections) { section in
                    sectionHeader(section)
                        .padding(.top, 32)
                        .padding(.bottom, 12)
                    if section.rows.isEmpty {
                        Text("No dictations found")
                            .font(AppFonts.figtree(size: 13))
                            .foregroundStyle(Color.inkSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(22)
                            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 15))
                            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.cardBorder))
                    }
                    ForEach(section.rows) { item in
                        DictationRowView(
                            entry: item.entry,
                            audioURL: item.audioURL,
                            isFirst: item.isFirst,
                            isLast: item.isLast,
                            canTranscribe: canTranscribe,
                            playbackActive: playback.entryID == item.id,
                            playbackPlaying: playback.isPlaying(item.id),
                            model: model,
                            recorder: recorder,
                            modelStore: modelStore,
                            processor: processor
                        )
                    }
                }
            }
            .padding(38)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.cardBackground)
        .onAppear(perform: rebuildHistory)
        .onChange(of: model.history) { rebuildHistory() }
        .onChange(of: search) { rebuildHistory() }
        .onChange(of: locale) { rebuildHistory() }
        .onChange(of: recorder.phase) { _, phase in
            if phase != .idle { AudioPlayback.shared.stop() }
        }
        .onDisappear { AudioPlayback.shared.stop() }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 30) {
                metric(Self.compact(totalWordsCount, locale: locale), "total words")
                metric("\(totalDictationsCount)", "dictations")
                Spacer(minLength: 0)
                Button {
                    recorder.toggle()
                } label: {
                    Label(LocalizedStringKey(dictationAction), systemImage: recorder.phase.isProcessing ? "hourglass" : recorder.phase.isCapturing ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(Color.onAccent)
                        .background(Color.inkPrimary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(FlowButtonStyle(enabled: !recorder.phase.isProcessing))
                .disabled(recorder.phase.isProcessing)
            }
            if showModelsOnHome {
                Rectangle().fill(Color.cardBorder).frame(height: 1)
                HStack(spacing: 28) {
                    modelInfo(icon: "waveform", label: "Transcription", value: transcriptionInfo) { model.page = .models }
                    modelInfo(icon: "sparkles", label: "AI Polish", value: aiPolishInfo) { model.page = .processing }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.cardBorder))
    }

    /// Wispr Flow style: 9048 → "9.0K", 1_250_000 → "1.3M"; values under 1000 stay exact.
    static func compact(_ value: Int, locale: Locale) -> String {
        let (scaled, suffix): (Double, String) = value >= 1_000_000 ? (Double(value) / 1_000_000, "M")
            : value >= 1_000 ? (Double(value) / 1_000, "K") : (Double(value), "")
        guard !suffix.isEmpty else { return "\(value)" }
        // Round down so 9999 reads 9.9K rather than a misleading 10.0K.
        let truncated = (scaled * 10).rounded(.down) / 10
        return truncated.formatted(.number.precision(.fractionLength(1)).locale(locale)) + suffix
    }

    private var transcriptionInfo: String {
        modelStore.isReady ? (modelStore.selected?.title ?? "") : L10n.text("Not set up", locale: locale)
    }

    private var aiPolishInfo: String {
        let settings = processor.settings
        guard settings.enabled else { return L10n.text("AI polish off", locale: locale) }
        guard processor.hasKey else { return L10n.text("Not set up", locale: locale) }
        let modelID = settings.parameters(for: settings.provider).model
        return modelID.isEmpty ? settings.provider.title : "\(settings.provider.title) · \(modelID)"
    }

    private func modelInfo(icon: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                Text(LocalizedStringKey(label))
                    .font(AppFonts.figtree(size: 12, weight: .semibold))
                    .foregroundStyle(Color.inkPrimary)
                Text(value)
                    .font(AppFonts.figtree(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(FlowButtonStyle())
    }

    private func metric(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(AppFonts.garamond(size: 30))
            Text(LocalizedStringKey(label)).font(AppFonts.figtree(size: 15)).foregroundStyle(Color.inkSecondary)
        }
        .foregroundStyle(Color.inkPrimary)
    }

    private var dictationAction: String {
        switch recorder.phase {
        case .idle: "Start dictation"
        case .preparing: "Cancel dictation"
        case .recording: "Stop dictation"
        case .transcribing: "Transcribing…"
        case .polishing: "Polishing…"
        }
    }

    private func sectionHeader(_ section: HistorySectionItem) -> some View {
        HStack {
            Text(verbatim: section.title)
                .font(AppFonts.figtree(size: 12, weight: .semibold))
                .tracking(1.2).foregroundStyle(Color.inkFaint)
            Spacer()
            if searching && section.isToday {
                TextField("Search dictations", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
            }
            if section.isToday {
                HoverIconButton(symbol: searching ? "xmark" : "magnifyingglass", tooltip: searching ? "Close search" : "Search dictations") {
                    searching.toggle()
                    if !searching { search = "" }
                }
            }
        }
    }
}

#Preview {
    ContentView(model: AppModel(), recorder: DictationController(), modelStore: SpeechModelStore(), processor: AIProcessingStore())
        .environment(\.locale, Locale(identifier: "es"))
        .frame(width: 1200, height: 760)
}

/// Confirms a deleted transcript or dictionary word; deliberately mirrors the "Transcript cancelled" notice of the dictation bar.
private struct DeletionNotice: View {
    @ObservedObject var model: AppModel
    let message: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var undoHovered = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text(message)
                    .font(AppFonts.figtree(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            Button(action: model.undoDeletion) {
                Text("Undo")
                    .font(AppFonts.figtree(size: 14))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color(white: undoHovered ? 0.2 : 0.14), in: RoundedRectangle(cornerRadius: 9))
                    .animation(.easeOut(duration: 0.12), value: undoHovered)
            }
            .buttonStyle(FlowButtonStyle())
            .onHover { undoHovered = $0 }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.bottom, 3)
        .frame(minWidth: 244)
        .fixedSize()
        .frame(height: 52)
        .background(Color(white: 0.09), in: Capsule())
        .overlay(alignment: .bottom) {
            TimelineView(.animation(paused: reduceMotion)) { _ in
                let elapsed = 1 - model.deletionRemaining
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule()
                            .fill(.white.opacity(0.75))
                            .frame(width: max(3, geometry.size.width * elapsed))
                    }
                }
                .frame(height: 3)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
            .allowsHitTesting(false)
        }
        .clipShape(Capsule())
        .environment(\.colorScheme, .dark)
        .onHover { model.setDeletionHover($0) }
    }
}
