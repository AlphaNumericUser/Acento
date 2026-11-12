import AppKit
import SwiftUI

// Compiled with the production @main App and AppServices. Only the window's
// visual content and speech/insertion dependencies are replaced by test doubles.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: DictationController
    @ObservedObject var modelStore: SpeechModelStore
    @ObservedObject var processor: AIProcessingStore

    var body: some View {
        Text("Lifecycle check")
            .onAppear {
                for window in NSApp.windows where window.canBecomeMain { window.alphaValue = 0 }
                SceneLifecycleProbe.begin(model: model, recorder: recorder, store: modelStore, processor: processor)
            }
    }
}

@MainActor
private enum SceneLifecycleProbe {
    private static var started = false
    private static weak var model: AppModel?
    private static weak var recorder: DictationController?
    private static weak var store: SpeechModelStore?
    private static weak var processor: AIProcessingStore?
    private static var floatingPanel: NSPanel?
    private static var checks = 0

    static func begin(model: AppModel, recorder: DictationController, store: SpeechModelStore, processor: AIProcessingStore) {
        guard !started else { return }
        started = true
        self.model = model
        self.recorder = recorder
        self.store = store
        self.processor = processor
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                try await run()
            } catch { fatalError("Scene lifecycle check failed: \(error)") }
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) && $0.isVisible }
    }

    private static func closeMainWindows() {
        for window in mainWindows { window.performClose(nil) }
    }

    private static func reopenFromDock() {
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: true)
    }

    private static func run() async throws {
        expect(recorder?.configurations == 1, "Production app startup configures dictation once")
        expect(mainWindows.count == 1, "The production single-window scene launches")
        let panel = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        floatingPanel = panel

        closeMainWindows()
        try await Task.sleep(nanoseconds: 250_000_000)
        expect(mainWindows.isEmpty && panel.isVisible, "Red-button close leaves only the floating panel")
        expect(model != nil && recorder != nil && store != nil && processor != nil,
               "Real SwiftUI scene destruction does not release app services")
        expect(recorder?.isModelReady?() == true, "The shortcut still resolves the model with the real scene closed")

        let url = URL(fileURLWithPath: "/unused-scene-lifecycle.wav")
        await recorder?.onFinished?(url, nil, .apple)
        expect(model?.history.count == 1 && TextInserter.deliveries.count == 1,
               "The real application's pipeline delivers a dictation while its scene is closed")

        reopenFromDock()
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(mainWindows.count == 1, "Dock reopen works through the real SwiftUI delegate and retained OpenWindowAction")
        expect(recorder?.configurations == 1 && model?.history.count == 1, "Reopening does not replace services or re-register shortcuts")

        store?.delay = 200_000_000
        store?.transcriptionStarted = false
        let pending = Task { await recorder?.onFinished?(url, nil, .apple) }
        while store?.transcriptionStarted == false { await Task.yield() }
        closeMainWindows()
        await pending.value
        expect(mainWindows.isEmpty && model?.history.count == 2 && TextInserter.deliveries.count == 2,
               "Closing the actual main scene during processing preserves insertion and history")

        reopenFromDock()
        reopenFromDock()
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(mainWindows.count == 1 && recorder?.configurations == 1, "Repeated Dock reopen cannot duplicate the main scene or shortcuts")

        let fullText = String(repeating: "Texto recuperado con acentos y emoji 😀.\n", count: 30)
        store?.transcript = fullText
        TextInserter.nextResult = .noTarget
        await recorder?.onFinished?(url, nil, .apple)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(mainWindows.count == 1 && recorder?.recoveryPanel?.isVisible == true,
               "A missing destination presents the real recovery view while the main scene is open")
        let openContent = recorder?.recoveryPanel?.contentView as? NSHostingView<DictationRecoveryView>
        expect(openContent?.rootView.text == fullText, "The recovery view keeps the full multiline transcript for copying")

        recorder?.recoveryPanel?.close()
        closeMainWindows()
        try await Task.sleep(nanoseconds: 150_000_000)
        TextInserter.nextResult = .unconfirmed
        let attemptsBeforeRecovery = TextInserter.attempts
        await recorder?.onFinished?(url, nil, .apple)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(mainWindows.isEmpty && recorder?.recoveryPanel?.isVisible == true,
               "An unconfirmed paste presents the real recovery view with no main scene")
        let closedContent = recorder?.recoveryPanel?.contentView as? NSHostingView<DictationRecoveryView>
        expect(closedContent?.rootView.text == fullText, "Closing the main scene does not truncate recovered text")
        expect(TextInserter.attempts == attemptsBeforeRecovery + 1, "Recovery does not automatically retry uncertain paste")
        recorder?.recoveryPanel?.close()
        print("Passed \(checks) production SwiftUI scene close/reopen and background pipeline checks; exiting through NSApplication.terminate.")
        NSApp.terminate(nil)
    }
}
