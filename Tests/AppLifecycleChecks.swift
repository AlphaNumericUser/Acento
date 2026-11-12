import AppKit
import SwiftUI

// Exercise the real AppServices/ApplicationDelegate with in-memory dependencies.
// No microphone, API keys, network requests, paste events, or saved history.
enum AppPage { case dictation, settings }
struct DictionaryTerm { }
enum SpeechModel { case apple; var title: String { "Apple Dictation" } }
struct TextInsertionTarget { var localizedName: String? { "Test input" } }
enum TextInsertionResult {
    case inserted, pasteSubmitted, noTarget, permissionRequired, focusUnavailable, unsupportedTarget, unconfirmed, cancelled
    var succeeded: Bool { self == .inserted || self == .pasteSubmitted }
    var recoveryMessage: String { "Select a text field or copy your text." }
}
enum DictationSound { case paste, alert, error }
enum AppLanguage { static func migrate() { } }
enum L10n {
    static func text(_ text: String, locale: Locale = .current) -> String { text }
    static func format(_ text: String, locale: Locale = .current, _ arguments: CVarArg...) -> String {
        String(format: text, arguments: arguments)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var history: [String] = []
    var page = AppPage.dictation
    let terms: [DictionaryTerm] = []
    func corrected(_ text: String) -> String { text }
    func addTranscript(_ text: String, audioFile: String, rawText: String? = nil) { history.append(text) }
    func pruneRecordings() {}
}

@MainActor
final class SpeechModelStore: ObservableObject {
    let selected: SpeechModel? = .apple
    let isReady = true
    var delay: UInt64 = 0
    var transcriptionStarted = false
    var transcript = "Dictado con la ventana cerrada."
    func transcribe(_ url: URL, using model: SpeechModel) async throws -> String {
        transcriptionStarted = true
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return transcript
    }
}

@MainActor
final class AIProcessingStore: ObservableObject {
    struct Settings { var enabled = true }
    var settings = Settings()
    var hasKey = true
    var calls = 0
    func refreshKey() { }
    func process(_ text: String, applicationName: String?, dictionaryTerms: [DictionaryTerm]) async throws -> String {
        calls += 1
        return text
    }
}

@MainActor
enum TextInserter {
    static var deliveries: [String] = []
    static var nextResult = TextInsertionResult.inserted
    static var attempts = 0
    static func insert(_ text: String, into target: TextInsertionTarget?) async -> TextInsertionResult {
        attempts += 1
        if nextResult.succeeded { deliveries.append(text) }
        return nextResult
    }
}

@MainActor
final class DictationController: ObservableObject {
    var selectedModel: (() -> SpeechModel?)?
    var isModelReady: (() -> Bool)?
    var onOpenSettings: (() -> Void)?
    var onFinished: (@MainActor (URL, TextInsertionTarget?, SpeechModel) async -> Void)?
    var message: String?
    var configurations = 0
    var barRefreshes = 0
    var completions = 0
    var recoveries: [(text: String, result: TextInsertionResult)] = []
#if SCENE_LIFECYCLE_CHECKS
    var recoveryPanel: DictationRecoveryPanel?
#endif
    func configureShortcut() { configurations += 1 }
    func refreshBarVisibility() { barRefreshes += 1 }
    func markPolishing() { }
    func retainRecording() { completions += 1 }
    func playSound(_ cue: DictationSound) { }
    func showRecovery(text: String, target: TextInsertionTarget?, result: TextInsertionResult) {
        recoveries.append((text, result))
#if SCENE_LIFECYCLE_CHECKS
        recoveryPanel?.close()
        let panel = DictationRecoveryPanel(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000),
                                                               size: DictationRecoveryView.size(for: text)),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0
        panel.contentView = NSHostingView(rootView: DictationRecoveryView(text: text, initialResult: result,
            retry: { .noTarget }, close: { [weak panel] in panel?.close() }))
        recoveryPanel = panel
        panel.orderFrontRegardless()
#endif
    }
}

private struct WindowContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: DictationController
    @ObservedObject var store: SpeechModelStore
    @ObservedObject var processor: AIProcessingStore
    var body: some View { Text("\(model.history.count) dictations") }
}

#if !SCENE_LIFECYCLE_CHECKS
@main
@MainActor
struct AppLifecycleChecks {
    private static var checks = 0
    private static func expect(_ condition: Bool, _ description: String) {
        precondition(condition, description)
        checks += 1
    }

    private static func makeWindow(_ services: AppServices) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WindowContent(model: services.model, recorder: services.recorder,
            store: services.modelStore, processor: services.processor))
        return window
    }

    private static func dispose(_ window: inout NSWindow?) {
        window?.performClose(nil)
        window?.contentView = nil
        window = nil
    }

    static func main() async {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        let services = delegate.services
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        services.start()
        expect(services.recorder.configurations == 1, "App launch configures shortcuts once")
        expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "The red button must not terminate the app")

        weak var store = services.modelStore
        weak var processor = services.processor
        var window: NSWindow? = makeWindow(services)
        dispose(&window)
        expect(store != nil && processor != nil, "Transcription and AI services survive destruction of window content")
        expect(services.recorder.selectedModel?() == .apple && services.recorder.isModelReady?() == true,
               "Global recording callbacks still resolve the selected ready model")
        let url = URL(fileURLWithPath: "/unused-lifecycle-test.wav")
        await services.recorder.onFinished?(url, nil, .apple)
        expect(services.model.history.count == 1 && TextInserter.deliveries.count == 1,
               "Transcribe, process, save, and insert with no main window")
        expect(services.processor.calls == 1, "AI processing remains connected after closing the window")
        store = nil
        processor = nil

        window = makeWindow(services)
        services.modelStore.delay = 100_000_000
        services.modelStore.transcriptionStarted = false
        let pending = Task { await services.recorder.onFinished?(url, nil, .apple) }
        while !services.modelStore.transcriptionStarted { await Task.yield() }
        dispose(&window)
        await pending.value
        expect(services.model.history.count == 2 && TextInserter.deliveries.count == 2,
               "Closing the main window during transcription does not interrupt delivery")

        var reopenCount = 0
        services.openMainWindow = {
            reopenCount += 1
            if window == nil { window = makeWindow(services) }
        }
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true)
        expect(window != nil && reopenCount == 1, "Dock reopen presents the main window even when a floating panel is visible")
        expect(services.model.history.count == 2 && services.recorder.configurations == 1,
               "Reopening preserves history and does not re-register shortcuts")
        services.recorder.onOpenSettings?()
        expect(services.model.page == .settings && reopenCount == 2, "Settings can reopen the shared main window")
        dispose(&window)

        let defaults = UserDefaults(suiteName: "Acento.InMemoryLifecycleChecks")!
        defaults.setVolatileDomain(["showBar": true, "showDock": false], forName: UserDefaults.argumentDomain)
        let background = AppServices(defaults: defaults)
        background.start()
        defaults.setVolatileDomain(["showBar": false, "showDock": false], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        expect(background.recorder.barRefreshes == 1, "Bar settings are observed without any main window")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        expect(background.recorder.barRefreshes == 1, "Unrelated preferences do not refresh the floating panel")
        let deliveredBeforeRecovery = TextInserter.deliveries.count
        for open in [true, false] {
            window = open ? makeWindow(services) : nil
            for result in [TextInsertionResult.noTarget, .unsupportedTarget, .unconfirmed] {
                TextInserter.nextResult = result
                let attemptsBefore = TextInserter.attempts
                let recoveredBefore = services.recorder.recoveries.count
                await services.recorder.onFinished?(url, nil, .apple)
                expect(services.recorder.recoveries.count == recoveredBefore + 1,
                       "Failed/uncertain insertion opens recovery with main window open=\(open), result=\(result)")
                expect(services.recorder.recoveries.last?.text == services.modelStore.transcript,
                       "The recovery callback receives the complete transcript")
                expect(TextInserter.attempts == attemptsBefore + 1,
                       "Recovery never automatically sends a duplicate insertion")
            }
            dispose(&window)
        }
        expect(TextInserter.deliveries.count == deliveredBeforeRecovery, "Failed insertions are not silently reported as successful deliveries")
        TextInserter.nextResult = .inserted
        print("Passed \(checks) app-owned lifecycle, closed-window dictation, in-flight processing, Dock reopening, and background settings checks.")
    }
}
#endif
