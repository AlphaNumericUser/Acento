import AppKit
import SwiftUI

final class DictationRecoveryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct DictationRecoveryView: View {
    let text: String
    let initialResult: TextInsertionResult
    let retry: @MainActor () async -> TextInsertionResult
    let close: () -> Void
    /// Setup notices replace the insertion hint and the Copy button.
    var notice: String? = nil
    var action: (label: String, perform: () -> Void)? = nil
    @AppStorage("appLanguage") private var language = "es"
    @State private var result: TextInsertionResult?
    @State private var retrying = false
    @State private var copied = false
    @State private var retryTask: Task<Void, Never>?
    @State private var visible = false
    @State private var dismissing = false
    @State private var remainingSeconds = 10.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func size(for text: String) -> NSSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 388, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph])
        return NSSize(width: 420, height: 126 + min(210, max(24, ceil(bounds.height))))
    }

    private var instruction: String {
        if let notice { return notice }
        return switch result ?? initialResult {
        case .permissionRequired, .focusUnavailable, .unsupportedTarget, .unconfirmed: (result ?? initialResult).recoveryMessage
        default: "Select a textbox first, then dictate"
        }
    }

    private func dismiss(gently: Bool = false) {
        guard !dismissing else { return }
        dismissing = true
        retryTask?.cancel()
        let duration = reduceMotion ? 0 : (gently ? 0.22 : 0.06)
        withAnimation(gently ? .timingCurve(0.4, 0, 0.2, 1, duration: duration) : .easeIn(duration: duration)) { visible = false }
        if gently, let panel = NSApp.windows.first(where: { $0 is DictationRecoveryPanel && $0.isVisible }) {
            // Fade the window too, so its shadow leaves with the content.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                panel.animator().alphaValue = 0
            }
        }
        Task { @MainActor in
            if duration > 0 { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            close()
        }
    }

    /// Confirms the copy in place, lets it be read, then leaves softly instead of vanishing.
    private func copyText() {
        guard !copied else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.28)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            dismiss(gently: true)
        }
    }

    private var copyButton: some View {
        Button(action: copyText) {
            HStack(spacing: 6) {
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Text(LocalizedStringKey(copied ? "Copied" : "Copy"))
                    .contentTransition(.opacity)
            }
            .font(AppFonts.figtree(size: 14, weight: .medium))
            .foregroundStyle(copied ? Color.black : Color(white: 0.93))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(copied ? Color(white: 0.93) : Color(white: 0.32), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Spacer()
            if let action {
                Button {
                    action.perform()
                    dismiss()
                } label: {
                    Text(L10n.text(action.label, locale: Locale(identifier: language)))
                        .font(AppFonts.figtree(size: 14, weight: .medium))
                        .foregroundStyle(Color(white: 0.93))
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(Color(white: 0.32), in: RoundedRectangle(cornerRadius: 9))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .onHover { inside in
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            } else {
                copyButton
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .buttonStyle(.plain)
                    .onHover { inside in
                        (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                    }
                    .contextMenu {
                        Button(LocalizedStringKey(retrying ? "Inserting…" : "Retry insertion")) {
                            retrying = true
                            retryTask = Task { @MainActor in
                                result = await retry()
                                retrying = false
                            }
                        }
                        .disabled(retrying)
                    }
            }
        }
    }

    private func runCountdown() async {
        withAnimation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.14)) { visible = true }
        var lastTick = ProcessInfo.processInfo.systemUptime
        while remainingSeconds > 0 && !dismissing {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // Paused while retrying or after copying, which closes the panel itself.
            let paused = retrying || dismissing || copied
            if !paused { remainingSeconds = max(0, remainingSeconds - (now - lastTick)) }
            lastTick = now
        }
        if !dismissing { dismiss() }
    }

    var body: some View {
        let size = Self.size(for: text)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text(L10n.text(instruction, locale: Locale(identifier: language)))
                    .font(AppFonts.figtree(size: 12))
                    .foregroundStyle(Color(white: 0.4))
                    .lineLimit(1)
                    .help(L10n.text(instruction, locale: Locale(identifier: language)))
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 26, height: 26)
                        .background(Color(white: 0.025), in: Circle())
                        .overlay(Circle().strokeBorder(Color(white: 0.14), lineWidth: 1))
                        .overlay {
                            Circle()
                                .trim(from: 0, to: CGFloat(1 - remainingSeconds / 10))
                                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .scaleEffect(x: -1, y: 1)
                                .animation(reduceMotion ? nil : .linear(duration: 0.05), value: remainingSeconds)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
                .help(L10n.text("Close", locale: Locale(identifier: language)))
                .accessibilityLabel(L10n.text("Close", locale: Locale(identifier: language)))
                .accessibilityValue(L10n.format("Closes in %ld seconds", locale: Locale(identifier: language), Int(ceil(remainingSeconds))))
                .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(text)
                    .font(AppFonts.figtree(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Color(white: 0.65))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: size.height - 126)
            actionRow
            .frame(height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(width: size.width, height: size.height)
        .background(.black, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .scaleEffect(reduceMotion || visible ? 1 : 0.9, anchor: .bottom)
        .offset(y: reduceMotion || visible ? 0 : 6)
        .opacity(visible ? 1 : 0)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, .dark)
        .task { await runCountdown() }
        .onDisappear {
            retryTask?.cancel()
            NSCursor.arrow.set()
        }
    }
}
