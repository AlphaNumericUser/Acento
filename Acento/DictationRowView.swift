import SwiftUI
import AppKit

struct TooltipAnchor {
    let bounds: Anchor<CGRect>
    let text: String
}

struct TooltipPreferenceKey: PreferenceKey {
    static var defaultValue: TooltipAnchor?

    static func reduce(value: inout TooltipAnchor?, nextValue: () -> TooltipAnchor?) {
        value = nextValue() ?? value
    }
}

/// Dark action button shown at the top-right of provider and model cards.
struct CardPrimaryButton: View {
    let title: String
    var muted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(AppFonts.figtree(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .foregroundStyle(muted ? Color.inkSecondary : Color.onAccent)
                .background(muted ? Color.hoverBackground : Color.inkPrimary, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(FlowButtonStyle())
    }
}

/// Takes the place of a card's action to show the option currently in use.
struct ActiveStateBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            Text("Active")
        }
        .font(AppFonts.figtree(size: 12, weight: .semibold))
        .foregroundStyle(Color.activeText)
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Color.activeTagBackground, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

/// Outlined pencil drawn to pair with the "trash" symbol.
struct PencilGlyph: Shape {
    static let name = "acento.pencil"

    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 24
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.move(to: point(16.5, 3.5))
        path.addLine(to: point(20.5, 7.5))
        path.addLine(to: point(8, 20))
        path.addLine(to: point(3.5, 20.5))
        path.addLine(to: point(4, 16))
        path.closeSubpath()
        path.move(to: point(14, 6))
        path.addLine(to: point(18, 10))
        return path
    }
}

struct HoverIconButton: View {
    @Environment(\.locale) private var locale
    let symbol: String
    let tooltip: String
    var enabled = true
    var weight: Font.Weight = .medium
    var action: () -> Void
    @State private var hovering = false

    @ViewBuilder private var glyph: some View {
        if symbol == PencilGlyph.name {
            PencilGlyph()
                .stroke(style: StrokeStyle(lineWidth: weight == .medium ? 1.5 : 1.1, lineCap: .round, lineJoin: .round))
                .frame(width: 17, height: 17)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: weight))
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
        }
    }

    var body: some View {
        Button {
            if enabled { action() }
        } label: {
            glyph
                .frame(width: 30, height: 30)
                .foregroundStyle(Color.inkPrimary)
                .opacity(enabled ? 1 : 0.35)
                .background(hovering && enabled ? Color.hoverBackground : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.16), value: hovering)
        }
        .buttonStyle(FlowButtonStyle(enabled: enabled, pressScale: 0.94))
        .onHover {
            hovering = $0
        }
        .onDisappear {
            if hovering {
                hovering = false
                NSCursor.arrow.set()
            }
        }
        .background {
            if hovering {
                Color.clear.anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) { bounds in
                    TooltipAnchor(bounds: bounds, text: L10n.text(tooltip, locale: locale))
                }
            }
        }
        .accessibilityLabel(L10n.text(tooltip, locale: locale))
    }
}

struct DictationRowView: View {
    @Environment(\.locale) private var locale
    let entry: DictationEntry
    /// Resolved by the page once per history change so rendering never touches the disk.
    let audioURL: URL?
    let isFirst: Bool
    let isLast: Bool
    /// A model is ready and no dictation is running; passed by value so rows only redraw when it changes.
    var canTranscribe: Bool
    let playbackActive: Bool
    let playbackPlaying: Bool
    let model: AppModel
    let recorder: DictationController
    let modelStore: SpeechModelStore
    let processor: AIProcessingStore
    @State private var hovering = false
    @State private var showingMoreOptions = false
    @State private var retrying = false
    @State private var copied = false
    @State private var moreMenu = FlowMenuPanelController()
    @ObservedObject private var offlineQueue = OfflineQueue.shared

    private static let actionsWidth: CGFloat = 3 * 30 + 2 * 5
    private static let timeFont = AppFonts.figtree(size: 13)
    private static let textFont = AppFonts.figtree(size: 15)
    private static let failedFont = AppFonts.figtree(size: 14)

    var body: some View {
        // Failed rows keep their actions visible so retrying is obvious; playback keeps running while hidden.
        // The slot keeps its width even without a play button so every row wraps text the same way.
        let showActions = hovering || showingMoreOptions || retrying || entry.isFailed
        let segment = CardSegment(isFirst: isFirst, isLast: isLast)

        HStack(alignment: .center, spacing: 12) {
            Text(entry.time)
                .font(Self.timeFont)
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 80, alignment: .leading)
            transcript(hasAudio: audioURL != nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Fixed-width slot keeps text from reflowing; the buttons are only built while visible.
            Color.clear
                .frame(width: Self.actionsWidth, height: 30)
                .overlay(alignment: .trailing) {
                    if showActions { actions }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 17)
        .frame(minHeight: 57)
        .background(hovering ? Color.rowHoverBackground : Color.cardBackground, in: segment)
        .overlay(alignment: .top) {
            if !isFirst {
                Color.cardBorder.frame(height: 1).padding(.horizontal, 1)
            }
        }
        .overlay(segment.border.stroke(Color.cardBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDisappear {
            if hovering && !showingMoreOptions {
                hovering = false
            }
        }
    }

    private var actions: some View {
        let canRetry = audioURL != nil && canTranscribe && !retrying
        return HStack(spacing: 5) {
            if let audioURL {
                HoverIconButton(symbol: playbackPlaying ? "pause.fill" : playbackActive ? "play.fill" : "play",
                                tooltip: playbackPlaying ? "Pause audio" : playbackActive ? "Resume audio" : "Play audio") {
                    do {
                        try AudioPlayback.shared.toggle(entry.id, url: audioURL)
                    } catch {
                        recorder.message = L10n.format("Could not play the audio: %@", error.localizedDescription)
                    }
                }
            }
            HoverIconButton(symbol: copied ? "checkmark" : "square.on.square",
                            tooltip: copied ? "Copied" : "Copy transcript",
                            enabled: !entry.isFailed) {
                copyTranscript()
            }
            if retrying {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                HoverIconButton(symbol: "ellipsis", tooltip: "More options") {
                    toggleMoreOptions(canRetry: canRetry)
                }
                .background(FlowMenuAnchor(controller: moreMenu))
                .onDisappear { moreMenu.close() }
            }
        }
    }

    private func toggleMoreOptions(canRetry: Bool) {
        if moreMenu.isOpen {
            moreMenu.close()
            return
        }
        let menu = moreMenu
        let entryID = entry.id
        let list = DictationMoreOptionsMenu(canRetry: canRetry,
                                            onRetry: { menu.close(); retry() },
                                            onDelete: {
                                                menu.close()
                                                AudioPlayback.shared.stop(entryID)
                                                model.deleteTranscript(entryID)
                                            })
            .environment(\.locale, locale)
            .appAppearance()
        showingMoreOptions = true
        menu.show(AnyView(list), alignTrailing: true) { showingMoreOptions = false }
    }

    @ViewBuilder
    private func transcript(hasAudio: Bool) -> some View {
        if entry.isFailed, hasAudio, offlineQueue.contains(entry.id) {
            Label(L10n.text("No connection. It will be transcribed when you're back online.", locale: locale),
                  systemImage: "wifi.slash")
                .font(Self.failedFont)
                .foregroundStyle(Color.inkSecondary)
        } else if entry.isFailed {
            Label(L10n.text(hasAudio ? "Transcription failed. Audio saved for retry." : "Transcription failed. No audio was saved.", locale: locale),
                  systemImage: "exclamationmark.triangle")
                .font(Self.failedFont)
                .foregroundStyle(hasAudio ? Color.inkSecondary : Color.errorText)
        } else {
            Text(entry.text)
                .font(Self.textFont)
                .lineSpacing(3)
                .foregroundStyle(Color.inkPrimary)
        }
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(entry.text, forType: .string),
              pasteboard.string(forType: .string) == entry.text else {
            recorder.message = L10n.text("Could not copy the transcript.")
            return
        }
        withAnimation(.easeOut(duration: 0.08)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.1)) { copied = false }
        }
    }

    private func retry() {
        guard !retrying, let url = audioURL, canTranscribe,
              let selection = modelStore.selected else { return }
        showingMoreOptions = false
        if !selection.isLocal, !NetworkMonitor.shared.isOnline {
            recorder.message = L10n.text("No connection: audio saved. It will be transcribed when you're back online.")
            if entry.isFailed { offlineQueue.add(entry.id) }
            return
        }
        retrying = true
        recorder.message = L10n.format("Retrying with %@…", selection.title)
        Task {
            defer { retrying = false }
            do {
                let text = try await modelStore.transcribe(url, using: selection)
                var output = model.corrected(text)
                var warning: String?
                processor.refreshKey()
                if processor.settings.enabled && processor.hasKey {
                    if NetworkMonitor.shared.isOnline {
                        recorder.message = L10n.text("Improving text with AI…")
                        do {
                            output = try await processor.process(output, applicationName: nil, dictionaryTerms: model.terms)
                        } catch {
                            warning = NetworkMonitor.shared.isOfflineError(error)
                                ? L10n.text("No connection: transcribed without AI polish.")
                                : L10n.format("AI processing failed: %@.", error.localizedDescription)
                        }
                    } else {
                        warning = L10n.text("No connection: transcribed without AI polish.")
                    }
                }
                offlineQueue.remove(entry.id)
                if let index = model.history.firstIndex(where: { $0.id == entry.id }) {
                    model.history[index].text = output
                    model.history[index].rawText = text
                }
                recorder.message = warning ?? L10n.format("Transcription retried with %@.", selection.title)
            } catch {
                if NetworkMonitor.isConnectivityError(error), entry.isFailed { offlineQueue.add(entry.id) }
                recorder.message = error.localizedDescription
            }
        }
    }
}

/// Same panel and row style as the AI Processing pickers: opens instantly, no popover animation.
private struct DictationMoreOptionsMenu: View {
    let canRetry: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onRetry) {
                row("Retry transcription", symbol: "arrow.clockwise")
            }
            .buttonStyle(FlowMenuRowStyle())
            .disabled(!canRetry)
            .opacity(canRetry ? 1 : 0.45)
            .help("Requires saved audio and an installed or configured model")

            Button(action: onDelete) {
                row("Delete transcription", symbol: "trash")
                    .foregroundStyle(Color.destructiveText)
            }
            .buttonStyle(FlowMenuRowStyle())
        }
        .font(AppFonts.figtree(size: 13))
        .foregroundStyle(Color.inkPrimary)
        .padding(6)
        .frame(width: 230)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cardBorder))
    }

    private func row(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

/// One row's slice of a rounded history card, so a section can be a run of independent lazy rows.
struct CardSegment: Shape {
    var isFirst: Bool
    var isLast: Bool
    var radius: CGFloat = 15

    func path(in rect: CGRect) -> Path {
        outline(in: rect, closed: true)
    }

    /// Side edges plus the rounded top/bottom only where the card actually ends; inset by half a point for a crisp 1 pt stroke.
    var border: some Shape {
        CardSegmentBorder(segment: self)
    }

    fileprivate func outline(in rect: CGRect, closed: Bool) -> Path {
        let inset: CGFloat = closed ? 0 : 0.5
        let minX = rect.minX + inset, maxX = rect.maxX - inset
        let minY = isFirst ? rect.minY + inset : rect.minY
        let maxY = isLast ? rect.maxY - inset : rect.maxY
        let r = max(0, radius - inset)
        var path = Path()
        path.move(to: CGPoint(x: minX, y: isLast ? maxY - r : maxY))
        if isFirst {
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: maxX, y: minY), radius: r)
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: maxY), radius: r)
        } else {
            path.addLine(to: CGPoint(x: minX, y: minY))
            if closed { path.addLine(to: CGPoint(x: maxX, y: minY)) } else { path.move(to: CGPoint(x: maxX, y: minY)) }
        }
        if isLast {
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY), radius: r)
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: minY), radius: r)
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            if closed { path.addLine(to: CGPoint(x: minX, y: maxY)) }
        }
        if closed { path.closeSubpath() }
        return path
    }
}

private struct CardSegmentBorder: Shape {
    let segment: CardSegment
    func path(in rect: CGRect) -> Path { segment.outline(in: rect, closed: false) }
}
