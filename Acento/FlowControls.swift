import AppKit
import SwiftUI

struct FlowModalCloseButton: View {
    @Environment(\.locale) private var locale
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.inkPrimary)
                .frame(width: 30, height: 30)
                .background(hovering ? Color.hoverBackground : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(L10n.text("Close", locale: locale))
        .accessibilityLabel(L10n.text("Close", locale: locale))
    }
}

struct FlowMenuPicker<Item: Hashable>: View {
    @Environment(\.locale) private var locale
    let title: String
    @Binding var selection: Item
    let items: [Item]
    var label: (Item) -> String = { "\($0)" }
    var width: CGFloat = 180
    var alwaysDropdown = false

    @State private var hovering = false
    @State private var open = false
    @State private var menu = FlowMenuPanelController()
    @Namespace private var segmentNamespace

    var body: some View {
        // Few options read better as an always-visible segmented control: one click, no popover animation.
        if alwaysDropdown {
            dropdown
        } else if items.count <= 1 {
            Text(label(selection))
                .foregroundStyle(Color.inkSecondary)
                .accessibilityLabel(L10n.text(title, locale: locale))
        } else if items.count <= 4 && items.reduce(0, { $0 + label($1).count }) <= 36 {
            segmented
        } else {
            dropdown
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                FlowSegment(text: label(item), selected: item == selection, namespace: segmentNamespace) {
                    withAnimation(.snappy(duration: 0.16)) { selection = item }
                }
            }
        }
        .padding(3)
        .background(Color.cardBorder.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(title, locale: locale))
    }

    private func toggleMenu() {
        if menu.isOpen {
            menu.close()
            return
        }
        let width = max(width, 260)
        let list = FlowMenuList(selection: $selection, items: items, label: label, width: width) { [menu] in menu.close() }
            .environment(\.locale, locale)
            .appAppearance()
        open = true
        menu.show(AnyView(list)) { open = false }
    }

    private var dropdown: some View {
        // A borderless child panel instead of Menu/popover: solid background, no arrow, and it appears instantly.
        Button { toggleMenu() } label: {
            HStack(spacing: 8) {
                Text(label(selection))
                    .font(AppFonts.figtree(size: 13, weight: .medium))
                    .foregroundStyle(Color.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.inkFaint)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 32)
            .background(hovering || open ? Color.hoverBackground : Color.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(open ? Color.inkFaint : Color.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .background(FlowMenuAnchor(controller: menu))
        .onDisappear { menu.close() }
        .accessibilityLabel(L10n.text(title, locale: locale))
        .accessibilityValue(label(selection))
    }
}

/// Dropdown contents; long lists get a search field and scroll.
private struct FlowMenuList<Item: Hashable>: View {
    @Environment(\.locale) private var locale
    @Binding var selection: Item
    let items: [Item]
    let label: (Item) -> String
    let width: CGFloat
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var searchable: Bool { items.count > 8 }
    private var filtered: [Item] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? items : items.filter { label($0).localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if searchable {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkFaint)
                    TextField(L10n.text("Search models", locale: locale), text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = filtered.first { pick(first) } }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.insetBackground, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.cardBorder))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered, id: \.self) { item in
                            Button { pick(item) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .opacity(item == selection ? 1 : 0)
                                    Text(label(item))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(FlowMenuRowStyle())
                            .id(item)
                            .accessibilityAddTraits(item == selection ? .isSelected : [])
                        }
                        if filtered.isEmpty {
                            Text(L10n.text("No models found", locale: locale))
                                .foregroundStyle(Color.inkSecondary)
                                .padding(10)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: searchable ? 300 : nil)
                .fixedSize(horizontal: false, vertical: !searchable)
                .onAppear { if searchable { proxy.scrollTo(selection, anchor: .center) } }
            }
        }
        .font(AppFonts.figtree(size: 13))
        .foregroundStyle(Color.inkPrimary)
        .padding(6)
        .frame(width: width)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cardBorder))
        .onAppear { searchFocused = searchable }
    }

    private func pick(_ item: Item) {
        selection = item
        close()
    }
}

struct FlowMenuAnchor: NSViewRepresentable {
    let controller: FlowMenuPanelController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        controller.anchor = view
    }
}

private final class FlowMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows dropdown contents in a borderless child window attached under the anchor, without system animations.
final class FlowMenuPanelController {
    weak var anchor: NSView?
    private var panel: FlowMenuPanel?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?

    var isOpen: Bool { panel != nil }

    func show(_ content: AnyView, alignTrailing: Bool = false, onClose: @escaping () -> Void) {
        close()
        guard let anchor, let parent = anchor.window else { return }
        self.onClose = onClose

        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let panel = FlowMenuPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = host

        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let gap: CGFloat = 6
        var origin = NSPoint(x: alignTrailing ? anchorRect.maxX - size.width : anchorRect.minX,
                             y: anchorRect.minY - gap - size.height)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y < visible.minY { origin.y = anchorRect.maxY + gap }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            guard event.window !== panel else { return event }
            // Swallow the click on the anchor itself so it closes instead of reopening.
            if let anchor = self.anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                self.close()
                return nil
            }
            self.close()
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        ]
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let panel else { return }
        self.panel = nil
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
        let callback = onClose
        onClose = nil
        callback?()
    }
}

private struct FlowSegment: View {
    let text: String
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(AppFonts.figtree(size: 13, weight: .medium))
                .foregroundStyle(selected || hovering ? Color.inkPrimary : Color.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 56, minHeight: 26)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.cardBackground)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "segment", in: namespace)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FlowMenuRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.cardBorder : hovering ? Color.hoverBackground : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovering an enabled control.
    func pointerCursor(_ enabled: Bool = true) -> some View {
        onHover { ($0 && enabled ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }
}

extension View {
    /// Stops macOS from focusing (and selecting) the first text field when a sheet opens.
    func noInitialFocus() -> some View { background(NoInitialFocusView()) }
}

private struct NoInitialFocusView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResignOnAppearView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ResignOnAppearView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
            // The sheet picks its initial first responder when it becomes key, which can happen after this point.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                window.makeFirstResponder(nil)
                if let observer = self?.observer { NotificationCenter.default.removeObserver(observer) }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
