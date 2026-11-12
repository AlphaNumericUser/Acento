import AppKit
import Foundation
import OSLog

// Owned by the application delegate, never by a window or a SwiftUI view.
// Closing/recreating the main window must not dispose of the dictation pipeline.
@MainActor
final class AppServices {
    let model: AppModel
    let recorder: DictationController
    let modelStore: SpeechModelStore
    let processor: AIProcessingStore
    var openMainWindow: (() -> Void)?

    private let defaults: UserDefaults
    private var started = false
    private var preferencesObserver: NSObjectProtocol?
    private var showBar = true
    private var showDock = true
    private var transcribingPending = false
    /// Status text that only describes an outage; cleared as soon as the connection returns.
    private var offlineStatusMessage: String?
    private static let logger = Logger(subsystem: "com.useacento.acento", category: "Pipeline")

    init(defaults: UserDefaults = .standard) {
        AppLanguage.migrate()
        self.defaults = defaults
        model = AppModel()
        recorder = DictationController()
        modelStore = SpeechModelStore()
        processor = AIProcessingStore()
    }

    func start() {
        guard !started else { return }
        started = true
        model.pruneRecordings()
        recorder.selectedModel = { [weak modelStore] in modelStore?.selected }
        recorder.isModelReady = { [weak modelStore] in modelStore?.isReady ?? false }
        recorder.onOpenSettings = { [weak self] in
            self?.model.page = .settings
            self?.showMainWindow()
        }
        recorder.onOpenModels = { [weak self] in
            self?.model.page = .models
            self?.modelStore.refresh()
            self?.showMainWindow()
        }
        recorder.onWillRecord = { [weak self] selected in
            guard let self else { return }
            self.recorder.recordingOffline = !selected.isLocal && !NetworkMonitor.shared.isOnline
                && self.modelStore.offlineFallback == nil
            var origins = [ConnectionWarmer.origin(for: selected)].compactMap { $0 }
            if self.processor.settings.enabled { origins.append(ConnectionWarmer.origin(for: self.processor.settings.provider)) }
            ConnectionWarmer.warm(origins)
        }
        recorder.onFinished = { [weak self] url, target, selected, live in
            await self?.finishRecording(url, target: target, selected: selected, live: live)
        }

        NetworkMonitor.shared.onReconnect = { [weak self] in
            guard let self else { return }
            if let offline = self.offlineStatusMessage, self.recorder.message == offline {
                self.recorder.message = nil
            }
            self.offlineStatusMessage = nil
            self.recorder.recordingOffline = false
            self.transcribePending()
        }
        Task { @MainActor [weak self] in
            // Give the model store and the network monitor a moment to settle after launch.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.transcribePending()
        }

        showBar = defaults.object(forKey: "showBar") as? Bool ?? true
        showDock = defaults.object(forKey: "showDock") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        recorder.configureShortcut()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPreferences() }
        }
    }

    func showMainWindow() {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshPreferences() {
        let nextBar = defaults.object(forKey: "showBar") as? Bool ?? true
        if showBar != nextBar {
            showBar = nextBar
            recorder.refreshBarVisibility()
        }
        let nextDock = defaults.object(forKey: "showDock") as? Bool ?? true
        if showDock != nextDock {
            showDock = nextDock
            NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        }
    }

    /// Uses the live transcript when it is available; otherwise transcribes the saved recording.
    private func transcribe(_ url: URL, using selected: SpeechModel, live: AppleLiveTranscription?) async throws -> String {
        if let live {
            do {
                let text = try await withTaskCancellationHandler { try await live.finish() } onCancel: { live.cancel() }
                if !text.isEmpty { return text }
                Self.logger.notice("Live transcription returned no text; transcribing the recording")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Self.logger.error("Live transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return try await modelStore.transcribe(url, using: selected)
    }

    private func finishRecording(_ url: URL, target: TextInsertionTarget?, selected: SpeechModel,
                                 live: AppleLiveTranscription?) async {
        guard !Task.isCancelled else { live?.cancel(); return }
        let clock = ContinuousClock()
        let started = clock.now
        func elapsed(_ since: ContinuousClock.Instant) -> Int {
            let duration = since.duration(to: clock.now)
            return Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
        do {
            let offline = !NetworkMonitor.shared.isOnline
            var fallback = !selected.isLocal && offline ? modelStore.offlineFallback : nil
            var engine = fallback ?? selected
            if !engine.isLocal, offline { throw OfflineFailure(provider: engine.title) }
            let text: String
            do {
                text = try await transcribe(url, using: engine, live: live)
            } catch {
                // The connection dropped mid-request even though the system still reported a network.
                guard !engine.isLocal, NetworkMonitor.isConnectivityError(error), let local = modelStore.offlineFallback else { throw error }
                try Task.checkCancellation()
                fallback = local
                engine = local
                text = try await transcribe(url, using: local, live: nil)
            }
            let transcribed = elapsed(started)
            try Task.checkCancellation()
            var output = model.corrected(text)
            var warning: String?
            var skippedOffline = false
            let polishStart = clock.now
            processor.refreshKey()
            if processor.settings.enabled && processor.hasKey {
                if NetworkMonitor.shared.isOnline {
                    recorder.markPolishing()
                    recorder.message = L10n.text("Improving text with AI…")
                    do {
                        output = try await processor.process(output, applicationName: target?.localizedName, dictionaryTerms: model.terms)
                    } catch {
                        try Task.checkCancellation()
                        if NetworkMonitor.shared.isOfflineError(error) { skippedOffline = true }
                        else { warning = L10n.format("AI processing failed: %@. The transcript was preserved.", error.localizedDescription) }
                    }
                } else {
                    skippedOffline = true
                }
                if skippedOffline { warning = L10n.text("No connection: pasted without AI polish.") }
            }
            let polished = elapsed(polishStart)
            try Task.checkCancellation()
            recorder.retainRecording()
            let insertStart = clock.now
            var delivered = false
            let result: TextInsertionResult
            if target == nil, recorder.insertIntoOwnTextField(output) {
                result = .inserted
                delivered = true
                recorder.markDelivered()
                recorder.playSound(.paste)
            } else {
                result = await TextInserter.insert(output, into: target) { [weak self] in
                    delivered = true
                    self?.recorder.markDelivered()
                    self?.recorder.playSound(.paste)
                }
            }
            Self.logger.notice("Dictation timings ms: transcription \(transcribed), AI \(polished), insertion \(elapsed(insertStart)), total \(elapsed(started))")
            // Saving and pruning touch SQLite and the disk; do it after the text reached the user.
            model.addTranscript(output, audioFile: url.lastPathComponent, rawText: text)
            model.pruneRecordings()
            try Task.checkCancellation()
            if result.succeeded {
                // A successful dictation needs no status text; only problems are worth reading.
                recorder.message = nil
                if !delivered { recorder.playSound(.paste) }
            } else {
                // The recovery window already explains what happened; no status text needed.
                recorder.message = nil
                recorder.showRecovery(text: output, target: target, result: result)
                recorder.playSound(.alert)
            }
            if warning == nil, let fallback { warning = L10n.format("No connection · used %@", fallback.title) }
            if let warning { recorder.message = [warning, recorder.message].compactMap { $0 }.joined(separator: " ") }
            offlineStatusMessage = skippedOffline || fallback != nil ? recorder.message : nil
            if result.succeeded, skippedOffline || fallback != nil, NetworkMonitor.shared.claimOfflineNotice() {
                let notice: String
                if let fallback {
                    notice = skippedOffline
                        ? L10n.format("No connection · used %@ without AI polish", fallback.title)
                        : L10n.format("No connection · used %@", fallback.title)
                } else {
                    notice = L10n.text("No connection · pasted without AI polish")
                }
                recorder.showNotice(notice)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            recorder.retainRecording()
            let id = model.addTranscript("", audioFile: url.lastPathComponent)
            if NetworkMonitor.isConnectivityError(error) {
                OfflineQueue.shared.add(id)
                recorder.message = L10n.text("No connection: audio saved. It will be transcribed when you're back online.")
                offlineStatusMessage = recorder.message
                recorder.showNotice(L10n.text("No connection · audio saved to transcribe later"))
            } else {
                recorder.message = L10n.format("%@ Audio saved for retry.", error.localizedDescription)
            }
            recorder.playSound(.error)
        }
    }

    /// Transcribes dictations recorded without a connection. They are saved to the history, never pasted,
    /// because the user has likely moved on from the original text field.
    private func transcribePending() {
        guard !transcribingPending, NetworkMonitor.shared.isOnline else { return }
        let queue = OfflineQueue.shared
        let queued = queue.ids
        let entries = model.history.filter { queued.contains($0.id) }
        for id in queued where !entries.contains(where: { $0.id == id && $0.isFailed }) { queue.remove(id) }
        let pending = entries.filter(\.isFailed)
        guard !pending.isEmpty, modelStore.isReady, let selected = modelStore.selected else { return }
        transcribingPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.transcribingPending = false }
            var transcribed = 0
            for entry in pending {
                guard let url = RecordingStorage.existingURL(for: entry.audioFile) else { queue.remove(entry.id); continue }
                do {
                    let text = try await self.modelStore.transcribe(url, using: selected)
                    var output = self.model.corrected(text)
                    self.processor.refreshKey()
                    if self.processor.settings.enabled && self.processor.hasKey {
                        output = (try? await self.processor.process(output, applicationName: nil, dictionaryTerms: self.model.terms)) ?? output
                    }
                    queue.remove(entry.id)
                    guard !output.isEmpty,
                          let index = self.model.history.firstIndex(where: { $0.id == entry.id }),
                          self.model.history[index].isFailed else { continue }
                    self.model.history[index].text = output
                    self.model.history[index].rawText = text
                    transcribed += 1
                } catch {
                    // Still offline: keep this and the remaining entries for the next reconnection.
                    if NetworkMonitor.isConnectivityError(error) { break }
                    // Any other failure stays in the history for a manual retry.
                    queue.remove(entry.id)
                }
            }
            guard transcribed > 0 else { return }
            let summary = transcribed == 1
                ? L10n.text("1 pending dictation was transcribed")
                : L10n.format("%ld pending dictations were transcribed", transcribed)
            self.recorder.message = summary
            if self.recorder.phase == .idle {
                self.recorder.showNotice(summary, symbol: "checkmark.circle", duration: 6) { [weak self] in
                    self?.model.page = .dictation
                    self?.showMainWindow()
                }
            }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemAudioMuter.shared.recoverFromPreviousSession()
        services.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemAudioMuter.shared.release()
        services.model.finalizePendingDeletion()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The floating panel can count as a visible window. Always target the
        // single main SwiftUI scene instead of relying on hasVisibleWindows.
        services.showMainWindow()
        return true
    }
}
