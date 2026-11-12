import AppKit
import SwiftUI

private struct BarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

final class DictationBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct IdleBarButtonFace: View {
    let symbol: String
    let width: CGFloat
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbol == "mic.fill" ? 15 : symbol == "note.text" ? 13 : 17, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: width, height: 28)
            .background(hovering && enabled ? Color(hex: 0x2A2A2A) : .black, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hovering && enabled ? 0.22 : 0.14), lineWidth: 1))
            .contentShape(Capsule())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let inside = enabled && Capsule().path(in: CGRect(x: 0, y: 0, width: width, height: 28)).contains(point)
                    if hovering != inside {
                        hovering = inside
                        (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                    }
                case .ended:
                    if hovering { NSCursor.arrow.set() }
                    hovering = false
                }
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled {
                    if hovering { NSCursor.arrow.set() }
                    hovering = false
                }
            }
            .animation(.easeOut(duration: reduceMotion ? 0.05 : 0.1), value: hovering)
    }
}

final class DictationBarHostingView: NSHostingView<FlowBarView> {
    private weak var recorder: DictationController?

    required init(rootView: FlowBarView) {
        self.recorder = rootView.recorder
        super.init(rootView: rootView)
        // The panel has a fixed size; skip re-measuring the SwiftUI tree on every waveform frame.
        sizingOptions = []
    }

    convenience init(recorder: DictationController) {
        self.init(rootView: FlowBarView(recorder: recorder))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies this point in the superview's coordinate system.
        // NSHostingView is flipped, while the panel's content container may not be.
        let localPoint = convert(point, from: superview)
        if recorder?.cancellationVisible == true {
            let area = NSRect(x: (bounds.width - 244) / 2,
                              y: isFlipped ? bounds.height - 12 - 75 : 12,
                              width: 244, height: 75)
            return area.contains(localPoint) ? super.hitTest(point) : nil
        }
        let expanded = recorder?.barExpanded == true || recorder?.phase != .idle
        let idleHover = recorder?.barExpanded == true && recorder?.phase == .idle
        let capsuleWidth: CGFloat = !expanded ? 40 : recorder?.phase == .idle ? 48 : 102
        let height: CGFloat = idleHover ? 75 : expanded ? 30 : 7
        let width: CGFloat = idleHover ? 224 : capsuleWidth + 16
        let area = NSRect(x: (bounds.width - width) / 2,
                          y: isFlipped ? bounds.height - 12 - height - 8 : 4,
                          width: width, height: height + 16)
        guard area.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }
}

struct FlowBarView: View {
    private enum RecordingControl: Hashable {
        case cancel, finish

        var title: String { self == .cancel ? "Cancel" : "Finish and paste" }
        var horizontalOffset: CGFloat { self == .cancel ? -36 : 36 }
    }

    @ObservedObject var recorder: DictationController
    @AppStorage("appLanguage") private var language = "es"
    @AppStorage("shortcutLabel") private var shortcut = "Right Command"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var undoHovered = false
    @State private var tooltipVisible = false
    @State private var hoveredControl: RecordingControl?
    @State private var controlTooltip: RecordingControl?

    private var idleHover: Bool { recorder.barExpanded && recorder.phase == .idle && !recorder.cancellationVisible }
    private var shortcutTitle: String {
        ShortcutKey.displayLabel(shortcut, locale: Locale(identifier: language))
    }
    private var motion: Animation {
        reduceMotion ? .linear(duration: 0.05) : .timingCurve(0.16, 1, 0.3, 1, duration: idleHover ? 0.15 : 0.11)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                HStack(spacing: 5) {
                    Text("Dictate")
                    Text(shortcutTitle).fontWeight(.semibold)
                }
                    .font(AppFonts.figtree(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(.black, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .opacity(idleHover && tooltipVisible ? 1 : 0)
                    .offset(y: reduceMotion ? -35 : idleHover && tooltipVisible ? -35 : -30)
                    .allowsHitTesting(false)
                    .accessibilityHidden(!idleHover || !tooltipVisible)

                idleControl("mic.fill", title: "Start dictation", width: 48) { recorder.toggle() }
                    .scaleEffect(x: reduceMotion || idleHover ? 1 : 40.0 / 48,
                                 y: reduceMotion || idleHover ? 1 : 7.0 / 28, anchor: .bottom)
                    .opacity(idleHover ? 1 : 0)
                    .allowsHitTesting(idleHover)

                Capsule()
                    .fill(.black.opacity(0.4))
                    .background(BarMaterialView().clipShape(Capsule()))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
                    .frame(width: 40, height: 7)
                    .opacity(idleHover ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .frame(height: 28, alignment: .bottom)
            .opacity(recorder.phase == .idle && !recorder.cancellationVisible && recorder.notice == nil ? 1 : 0)
            .allowsHitTesting(recorder.phase == .idle)
            .accessibilityHidden(!idleHover)

            HStack(spacing: 8) {
                switch recorder.phase {
                case .idle:
                    Color.clear.frame(width: 1, height: 1)
                case .preparing:
                    control(.cancel) { recorder.stop(cancelled: true) }
                    processingDots
                    processingSpinner
                case .recording:
                    control(.cancel) { recorder.stop(cancelled: true) }
                    waveform
                    control(.finish) { recorder.stop() }
                case .transcribing, .polishing:
                    control(.cancel) { recorder.stop(cancelled: true) }
                    processingDots
                    processingSpinner
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 102, height: 30)
            .background(.black, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color(hex: 0x282828), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    ForEach([RecordingControl.cancel, .finish], id: \.self) { item in
                        Text(L10n.text(item.title, locale: Locale(identifier: language)))
                            .font(AppFonts.figtree(size: 14))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(.black, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color(hex: 0x282828), lineWidth: 1))
                            .opacity(controlTooltip == item && recorder.phase != .idle ? 1 : 0)
                            .offset(x: item.horizontalOffset,
                                    y: reduceMotion || controlTooltip == item ? -34 : -30)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash").font(.system(size: 11, weight: .semibold))
                        Text(L10n.text("No connection", locale: Locale(identifier: language)))
                            .font(AppFonts.figtree(size: 13))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(.black, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(hex: 0x282828), lineWidth: 1))
                    .opacity(recorder.recordingOffline && recorder.phase.isCapturing && controlTooltip == nil ? 1 : 0)
                    .offset(y: -34)
                    .accessibilityHidden(!recorder.recordingOffline)
                }
                .allowsHitTesting(false)
            }
            .scaleEffect(x: recorder.phase == .idle ? 40.0 / 102 : 1,
                         y: recorder.phase == .idle ? 7.0 / 30 : 1, anchor: .bottom)
            .opacity(recorder.phase == .idle ? 0 : 1)
            .allowsHitTesting(recorder.phase != .idle)
            .accessibilityHidden(recorder.phase == .idle)

            if recorder.cancellationVisible {
                HStack(spacing: 12) {
                    Text("Transcript cancelled")
                        .font(AppFonts.figtree(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Button { recorder.undoCancellation() } label: {
                        Text("Undo")
                            .font(AppFonts.figtree(size: 14))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color(white: undoHovered ? 0.2 : 0.14), in: RoundedRectangle(cornerRadius: 9))
                            .animation(.easeOut(duration: 0.12), value: undoHovered)
                    }
                        .disabled(!recorder.canUndoCancellation)
                        .opacity(recorder.canUndoCancellation ? 1 : 0.4)
                        .onHover { inside in
                            undoHovered = inside
                            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                        }
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.bottom, 3)
                .frame(width: 244, height: 52)
                .background(Color(white: 0.09), in: Capsule())
                .overlay(alignment: .bottom) {
                    // Same language as the model download bar: a soft track that fills until the notice closes.
                    TimelineView(.animation(paused: reduceMotion)) { _ in
                        let elapsed = 1 - recorder.cancellationRemaining
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
                .onHover { recorder.setCancellationHover($0) }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
                                                         .combined(with: .offset(y: 6)))
            }

            if let notice = recorder.notice, recorder.phase == .idle, !recorder.cancellationVisible {
                HStack(spacing: 10) {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(notice.text)
                        .font(AppFonts.figtree(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if notice.action != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 18)
                .frame(width: 244, height: 52)
                .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 26))
                .contentShape(RoundedRectangle(cornerRadius: 26))
                .onTapGesture {
                    notice.action?()
                    recorder.clearNotice()
                }
                .onHover { inside in
                    guard notice.action != nil else { return }
                    (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
                .id(notice.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
                                                         .combined(with: .offset(y: 6)))
            }
        }
        .frame(width: 224, height: 75, alignment: .bottom)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let area = recorder.barExpanded || recorder.phase != .idle
                    ? CGRect(x: 0, y: 0, width: 224, height: 75)
                    : CGRect(x: 84, y: 52, width: 56, height: 23)
                let hovering = area.contains(point)
                if recorder.barExpanded != hovering { recorder.barExpanded = hovering }
            case .ended:
                recorder.barExpanded = false
                hoveredControl = nil
                controlTooltip = nil
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .animation(motion, value: idleHover)
        .animation(.easeOut(duration: reduceMotion ? 0.05 : 0.08), value: tooltipVisible)
        .animation(.easeOut(duration: reduceMotion ? 0.05 : 0.08), value: controlTooltip)
        .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.10), value: recorder.phase)
        .animation(reduceMotion ? .easeOut(duration: 0.05) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.28), value: recorder.cancellationVisible)
        .animation(reduceMotion ? .easeOut(duration: 0.05) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.28), value: recorder.notice)
        .task(id: idleHover) {
            guard idleHover else { tooltipVisible = false; return }
            do {
                if !reduceMotion { try await Task.sleep(nanoseconds: 120_000_000) }
                try Task.checkCancellation()
                tooltipVisible = true
            } catch { }
        }
        .task(id: hoveredControl) {
            guard let hoveredControl, recorder.phase != .idle else {
                controlTooltip = nil
                return
            }
            do {
                if !reduceMotion { try await Task.sleep(nanoseconds: 120_000_000) }
                try Task.checkCancellation()
                guard self.hoveredControl == hoveredControl, recorder.phase != .idle else { return }
                controlTooltip = hoveredControl
            } catch { }
        }
        .onChange(of: recorder.phase) { _, _ in
            hoveredControl = nil
            controlTooltip = nil
            NSCursor.arrow.set()
        }
        .onChange(of: language) { _, _ in
            hoveredControl = nil
            controlTooltip = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 12)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, .dark)
    }

    private var waveform: some View {
        DictationWaveformView(meter: recorder.audioMeter,
                              label: L10n.text(recorder.isHandsFree ? "Hands-free recording" : "Recording",
                                               locale: Locale(identifier: language)))
    }

    private var processingDots: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { _ in
                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 2, height: 2)
            }
        }
        .frame(width: 38, height: 24)
        .allowsHitTesting(false)
        .accessibilityLabel(Text(recorder.phase == .polishing ? "Polishing…" : recorder.phase == .preparing ? "Start dictation" : "Transcribing…"))
    }

    private var processingSpinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: reduceMotion)) { timeline in
            let step = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 10) % 8
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let age = (step - index + 8) % 8
                    Capsule()
                        .fill(Color(hex: 0x8B7AA8).opacity(reduceMotion ? 0.75 : 1 - Double(age) * 0.1))
                        .frame(width: 2, height: 4)
                        .offset(y: -5)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .frame(width: 18, height: 18)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func idleControl(_ symbol: String, title: String, width: CGFloat = 28, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IdleBarButtonFace(symbol: symbol, width: width, enabled: idleHover)
        }
        .help(L10n.text(title, locale: Locale(identifier: language)))
        .accessibilityLabel(L10n.text(title, locale: Locale(identifier: language)))
    }

    private func control(_ item: RecordingControl, action: @escaping () -> Void) -> some View {
        Button {
            hoveredControl = nil
            controlTooltip = nil
            NSCursor.arrow.set()
            action()
        } label: {
            Image(systemName: item == .finish ? "checkmark" : "xmark")
                .font(.system(size: item == .finish ? 12 : 10, weight: .semibold))
                .foregroundStyle(item == .finish ? Color.black : Color.white)
                .frame(width: 18, height: 18)
                .background(item == .finish ? Color(hex: 0xFAFAF7) : Color(hex: 0x433F38), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(L10n.text(item.title, locale: Locale(identifier: language)))
        .onContinuousHover { phase in
            let inside: Bool
            switch phase {
            case .active(let point):
                inside = Circle().path(in: CGRect(x: 0, y: 0, width: 18, height: 18)).contains(point)
            case .ended:
                inside = false
            }
            if inside {
                if hoveredControl != item {
                    controlTooltip = nil
                    hoveredControl = item
                }
                NSCursor.arrow.set()
            } else if hoveredControl == item {
                hoveredControl = nil
                controlTooltip = nil
                NSCursor.arrow.set()
            }
        }
    }
}

private struct DictationWaveformView: View {
    @ObservedObject var meter: DictationMeter
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.75 + 0.25 * meter.levels[index]))
                    .frame(width: 2, height: 2 + meter.levels[index] * 18)
            }
        }
        .frame(width: 38, height: 24)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.07), value: meter.levels)
        .accessibilityLabel(label)
    }
}
