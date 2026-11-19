import Foundation
import Combine
import FluidAudio
import Security
import Speech
import SwiftUI
import WhisperKit

enum SpeechModel: String, CaseIterable, Identifiable {
    case apple, parakeetV3, whisperTiny, whisperBase, whisperTurbo
    case groq, openRouter, gemini, openAI

    var id: String { rawValue }
    var isLocal: Bool { ![.groq, .openRouter, .gemini, .openAI].contains(self) }
    var title: String {
        switch self {
        case .parakeetV3: "NVIDIA Parakeet TDT 0.6B V3"
        case .whisperTiny: "Whisper Tiny"
        case .whisperBase: "Whisper Base"
        case .whisperTurbo: "Whisper Large V3 Turbo"
        case .apple: L10n.text("Apple Dictation")
        case .groq: "Groq"
        case .openRouter: "OpenRouter"
        case .gemini: "Google Gemini"
        case .openAI: "OpenAI"
        }
    }
    var subtitle: String {
        switch self {
        case .parakeetV3: "High accuracy in 25 European languages"
        case .whisperTiny: "Lightweight and quick · many languages"
        case .whisperBase: "Balance of size and quality · many languages"
        case .whisperTurbo: "Whisper's best accuracy · many languages"
        case .apple: "Real-time transcription, private and free"
        case .groq: GroqTranscriptionModel.current.subtitle
        case .openRouter: "Hundreds of models with a single key"
        case .gemini: "Transcription with Google's AI"
        case .openAI: "OpenAI's dedicated transcription"
        }
    }
    var size: String {
        switch self {
        case .parakeetV3: "≈ 500 MB"
        case .whisperTiny: "≈ 75 MB"
        case .whisperBase: "≈ 150 MB"
        case .whisperTurbo: "≈ 626 MB"
        case .apple: "Built into macOS"
        default: "Cloud"
        }
    }
    var languages: String {
        switch self {
        case .parakeetV3: "25 languages"
        case .whisperTiny, .whisperBase, .whisperTurbo: "Multilingual"
        case .apple: "System locale"
        default: "Model dependent"
        }
    }
    var features: String {
        switch self {
        case .parakeetV3: "Automatic punctuation · Neural Engine · works offline"
        case .whisperTiny, .whisperBase, .whisperTurbo: "Detects the language · Core ML · works offline"
        case .apple: "Transcribes while you speak · works offline"
        case .groq: "Key from GroqCloud"
        case .openRouter: "Key from OpenRouter"
        case .gemini: "Key from Google AI Studio"
        case .openAI: "Key from OpenAI Platform"
        }
    }
    var accuracy: String {
        switch self {
        case .whisperTiny: "Basic"
        case .whisperBase: "Balanced"
        case .parakeetV3, .whisperTurbo: "High"
        case .apple: "Varies by locale"
        default: "Varies by model"
        }
    }
    var speed: String {
        switch self {
        case .whisperTurbo: "Moderate"
        case .whisperBase: "Fast"
        case .apple: "Real time"
        case .whisperTiny, .parakeetV3: "Fast"
        default: "Network dependent"
        }
    }
    var license: String {
        switch self {
        case .parakeetV3: "CC BY 4.0 · open weights"
        case .whisperTiny, .whisperBase, .whisperTurbo: "MIT · open weights"
        case .apple: "Apple · proprietary"
        default: "Provider terms · usage may cost"
        }
    }
    var source: URL {
        let address: String
        switch self {
        case .parakeetV3: address = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .whisperTiny, .whisperBase, .whisperTurbo: address = "https://huggingface.co/argmaxinc/whisperkit-coreml"
        case .apple: address = "https://developer.apple.com/documentation/speech/speechanalyzer"
        case .groq: address = "https://console.groq.com/keys"
        case .openRouter: address = "https://openrouter.ai/keys"
        case .gemini: address = "https://aistudio.google.com/apikey"
        case .openAI: address = "https://platform.openai.com/api-keys"
        }
        return URL(string: address)!
    }
    var whisperVariant: String? {
        switch self {
        case .whisperTiny: "tiny"
        case .whisperBase: "base"
        case .whisperTurbo: "large-v3-v20240930_626MB"
        default: nil
        }
    }
    var parakeetVersion: AsrModelVersion { .v3 }
}

enum GroqTranscriptionModel: String, CaseIterable, Identifiable {
    case turbo = "whisper-large-v3-turbo"
    case largeV3 = "whisper-large-v3"

    private static let key = "groqTranscriptionModel"
    static var current: GroqTranscriptionModel {
        get { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .turbo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .turbo: "Near-instant transcription"
        case .largeV3: "Maximum accuracy"
        }
    }
    var label: String {
        switch self {
        case .turbo: "Whisper Large V3 Turbo (faster)"
        case .largeV3: "Whisper Large V3 (more accurate)"
        }
    }
}

enum CredentialStore {
    private static let service = "com.useacento.acento.speech-api"

    static func get(_ model: SpeechModel) -> String? {
        get(model.id)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, for model: SpeechModel) throws {
        try set(key, for: model.id)
    }

    static func set(_ key: String, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if key.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
            guard result == errSecSuccess else { throw SpeechFailure(L10n.format("Could not update the key in Keychain (%ld).", Int(result))) }
            return
        }
        var newItem = query
        newItem[kSecValueData as String] = Data(key.utf8)
        let result = SecItemAdd(newItem as CFDictionary, nil)
        guard result == errSecSuccess else { throw SpeechFailure(L10n.format("Could not save the key to Keychain (%ld).", Int(result))) }
    }
}

enum SpeechLanguagePreferences {
    private static func key(for model: SpeechModel) -> String { "autoDetectSpeechLanguage.\(model.id)" }

    static func autoDetect(for model: SpeechModel) -> Bool {
        let name = key(for: model)
        return UserDefaults.standard.object(forKey: name) == nil || UserDefaults.standard.bool(forKey: name)
    }

    static func setAutoDetect(_ enabled: Bool, for model: SpeechModel) {
        UserDefaults.standard.set(enabled, forKey: key(for: model))
    }
}

nonisolated struct SpeechFailure: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { L10n.text(reason) }
}

nonisolated private final class SpeechRecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

@MainActor
final class SpeechModelStore: ObservableObject {
    @Published var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedSpeechModel") }
    }
    @Published private(set) var installed = Set<String>()
    @Published private(set) var busy = Set<String>()
    @Published private(set) var progress: [String: Double] = [:]
    @Published var error: String?
    /// The Apple speech model for this Mac's language can be downloaded but is not installed yet.
    @Published private(set) var appleModelDownloadable = false
    /// The system already has the Apple speech model; "downloading" only reserves it for Acento.
    @Published private(set) var appleModelOnDisk = false
    /// Identifier of the Apple speech model's language, e.g. "es-MX".
    @Published private(set) var appleModelLocale: String?

    private var whisperFolders: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "whisperModelFolders") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModelFolders") }
    }

    private static let appleReleasedKey = "appleSpeechReleased"
    /// Set once the Apple model was installed for Acento; survives restarts so a slow or transient
    /// AssetInventory answer at launch never asks the user to pick a model again.
    private static let appleInstalledKey = "appleSpeechInstalled"
    private static let installedCacheKey = "installedSpeechModels"
    private static let offlineFallbackKey = "offlineLocalFallback"
    private var appleRestoreAttempted = false
    private var refreshRetries = 0

    /// Without internet, an API model hands the recording to an installed local model so the text still gets pasted.
    @Published var offlineFallbackEnabled: Bool {
        didSet { UserDefaults.standard.set(offlineFallbackEnabled, forKey: Self.offlineFallbackKey) }
    }

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedSpeechModel")
        offlineFallbackEnabled = UserDefaults.standard.object(forKey: Self.offlineFallbackKey) as? Bool ?? true
        // Start from the last known state so a dictation right after launch never waits for the async check.
        installed = Self.cachedInstalled()
        refresh()
    }

    /// Last known installed models, trusting only what can be re-checked synchronously.
    private static func cachedInstalled() -> Set<String> {
        let defaults = UserDefaults.standard
        var cached = Set(defaults.stringArray(forKey: installedCacheKey) ?? [])
        if appleWasInstalled { cached.insert(SpeechModel.apple.id) }
        for model in SpeechModel.allCases where !model.isLocal && cached.contains(model.id) {
            if (CredentialStore.get(model) ?? "").isEmpty { cached.remove(model.id) }
        }
        return cached
    }

    /// The user installed Apple Dictation for Acento and has not removed it. Selecting it also
    /// counts, so installs made before this flag existed are remembered too.
    private static var appleWasInstalled: Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: appleReleasedKey) else { return false }
        return defaults.bool(forKey: appleInstalledKey)
            || defaults.string(forKey: "selectedSpeechModel") == SpeechModel.apple.id
    }

    var selected: SpeechModel? { selectedID.flatMap(SpeechModel.init(rawValue:)) }
    var isReady: Bool { selected.map { installed.contains($0.id) } ?? false }
    /// First installed local model, in catalog order (Apple, Parakeet, then Whisper).
    var installedLocalModel: SpeechModel? { SpeechModel.allCases.first { $0.isLocal && installed.contains($0.id) } }
    var offlineFallback: SpeechModel? { offlineFallbackEnabled ? installedLocalModel : nil }

    func refresh() {
        Task { await refreshAvailability() }
    }

    /// Called after macOS wakes from sleep so any dropped Apple Speech reservation is restored proactively.
    func refreshAfterWake() {
        appleRestoreAttempted = false
        refresh()
    }

    private func refreshAvailability() async {
        var available = Set<String>()
        var needsRetry = false
        for model in SpeechModel.allCases {
            if !model.isLocal {
                if let key = CredentialStore.get(model), !key.isEmpty { available.insert(model.id) }
            } else if model == .apple {
                let status = await AppleSpeechAssets.status()
                let appleLocale = await AppleSpeechAssets.supportedLocale()
                appleModelLocale = appleLocale?.identifier(.bcp47)
                appleModelOnDisk = status == .installed || appleLocale.map(AppleSpeechAssets.isOnDisk) == true
                if UserDefaults.standard.bool(forKey: Self.appleReleasedKey) {
                    appleModelDownloadable = status != nil
                    continue
                }
                appleModelDownloadable = status == .supported || status == .downloading
                if status == .installed {
                    available.insert(model.id)
                    UserDefaults.standard.set(true, forKey: Self.appleInstalledKey)
                } else if Self.appleWasInstalled {
                    // Installed before but not reported now: after a restart the system can briefly
                    // answer "supported" or nothing at all. Keep it usable and quietly reserve it again.
                    available.insert(model.id)
                    appleModelDownloadable = false
                    if status == nil { needsRetry = true }
                    else { restoreAppleReservation() }
                } else if status == nil, let recognizer = SFSpeechRecognizer(locale: Locale.current),
                          recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                    available.insert(model.id)
                }
            } else if model == .parakeetV3 {
                if AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: model.parakeetVersion), version: model.parakeetVersion) {
                    available.insert(model.id)
                }
            } else if let folder = whisperFolders[model.id],
                      FileManager.default.fileExists(atPath: folder) {
                available.insert(model.id)
            }
        }
        installed = available
        UserDefaults.standard.set(Array(available).sorted(), forKey: Self.installedCacheKey)
        if needsRetry, refreshRetries < 5 {
            refreshRetries += 1
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.refresh()
            }
        } else if !needsRetry {
            refreshRetries = 0
        }
    }

    /// Re-reserves the Apple model in the background. When the files are still on disk this is
    /// instant; otherwise macOS downloads them again without asking the user to pick a model.
    private func restoreAppleReservation() {
        guard !appleRestoreAttempted, !busy.contains(SpeechModel.apple.id) else { return }
        appleRestoreAttempted = true
        Task { @MainActor [weak self] in
            do {
                try await AppleSpeechAssets.install { _ in }
            } catch {
                self?.error = "\(SpeechModel.apple.title): \(error.localizedDescription)"
            }
            self?.refresh()
        }
    }

    /// Makes sure the Apple model is reserved before transcribing with it.
    private func ensureAppleReserved() async {
        guard await AppleSpeechAssets.status() != .installed, Self.appleWasInstalled else { return }
        try? await AppleSpeechAssets.install { _ in }
    }

    /// Re-subscribes the `SpeechTranscriber` asset in the background after `SFSpeechRecognizer` runs,
    /// because `SFSpeechRecognizer` overwrites the app's UAF subscriptions with `hammer`/`assistant`.
    private func scheduleAppleReservationRestore() {
        guard Self.appleWasInstalled else { return }
        appleRestoreAttempted = false
        restoreAppleReservation()
    }

    func download(_ model: SpeechModel) async {
        guard model.isLocal, !busy.contains(model.id) else { return }
        busy.insert(model.id)
        progress[model.id] = 0
        error = nil
        defer { busy.remove(model.id); progress.removeValue(forKey: model.id); refresh() }
        do {
            if model == .apple {
                let id = model.id
                try await AppleSpeechAssets.install { value in
                    Task { @MainActor [weak self] in self?.progress[id] = value }
                }
                UserDefaults.standard.set(false, forKey: Self.appleReleasedKey)
                UserDefaults.standard.set(true, forKey: Self.appleInstalledKey)
            } else if model == .parakeetV3 {
                let id = model.id
                try await AsrModels.download(version: model.parakeetVersion) { [weak self] value in
                    Task { @MainActor [weak self] in self?.progress[id] = value.fractionCompleted }
                }
            } else if let variant = model.whisperVariant {
                let base = try RecordingStorage.folder("Models")
                let folder = try await WhisperKit.download(variant: variant, downloadBase: base) { [weak self] value in
                    Task { @MainActor [weak self] in self?.progress[model.id] = value.fractionCompleted }
                }
                _ = try await WhisperKit(modelFolder: folder.path, tokenizerFolder: base, download: false)
                var paths = whisperFolders
                paths[model.id] = folder.path
                whisperFolders = paths
            }
            // Let the bar visibly reach 100% before the card switches to "Selected".
            progress[model.id] = 1
            try? await Task.sleep(nanoseconds: 450_000_000)
            installed.insert(model.id)
            selectedID = model.id
        } catch {
            self.error = "\(model.title): \(error.localizedDescription)"
        }
    }

    func remove(_ model: SpeechModel) {
        guard !busy.contains(model.id), model.isLocal else { return }
        if model == .apple {
            UserDefaults.standard.set(true, forKey: Self.appleReleasedKey)
            UserDefaults.standard.set(false, forKey: Self.appleInstalledKey)
            installed.remove(model.id)
            if selectedID == model.id { selectedID = nil }
            Task { await AppleSpeechAssets.release(); refresh() }
            return
        }
        do {
            if model == .parakeetV3 {
                let folder = AsrModels.defaultCacheDirectory(for: model.parakeetVersion)
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            } else if let folder = whisperFolders[model.id] {
                let base = try RecordingStorage.folder("Models").standardizedFileURL.path
                let target = URL(fileURLWithPath: folder).standardizedFileURL
                guard target.path.hasPrefix(base + "/") else { throw SpeechFailure("Invalid model folder.") }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                var paths = whisperFolders
                paths.removeValue(forKey: model.id)
                whisperFolders = paths
            }
            if selectedID == model.id { selectedID = nil }
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    func transcribe(_ url: URL, using model: SpeechModel, skipAppleReserve: Bool = false) async throws -> String {
        guard installed.contains(model.id) else { throw SpeechFailure(L10n.format("Install or configure %@ before recording.", model.title)) }
        let text: String
        switch model {
        case .parakeetV3:
            let folder = AsrModels.defaultCacheDirectory(for: model.parakeetVersion)
            let models = try await AsrModels.load(from: folder, version: model.parakeetVersion)
            let manager = AsrManager()
            try await manager.initialize(models: models)
            text = try await manager.transcribe(url, source: .system).text
        case .whisperTiny, .whisperBase, .whisperTurbo:
            guard let folder = whisperFolders[model.id] else { throw SpeechFailure("Model files are missing.") }
            let engine = try await WhisperKit(modelFolder: folder, tokenizerFolder: RecordingStorage.folder("Models"), download: false)
            let segments: [TranscriptionResult] = try await engine.transcribe(audioPath: url.path)
            text = segments.map(\.text).joined(separator: " ")
        case .apple:
            if !skipAppleReserve {
                await ensureAppleReserved()
            }
            if await AppleSpeechAssets.status() == .installed {
                text = try await transcribeWithApple(url)
            } else {
                text = try await Self.legacyAppleTranscription(url)
                scheduleAppleReservationRestore()
            }
        case .groq, .openRouter, .gemini, .openAI:
            guard let key = CredentialStore.get(model), !key.isEmpty else { throw SpeechFailure(L10n.format("Add an API key for %@.", model.title)) }
            text = try await CloudTranscriber.transcribe(url, provider: model, key: key,
                                                         autoDetectLanguage: SpeechLanguagePreferences.autoDetect(for: model))
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw SpeechFailure("No speech was detected. The recording was kept for retry.") }
        return cleaned
    }

    /// Uses SpeechAnalyzer on the saved WAV file, resetting cached models if the result is empty or truncated,
    /// and falls back to on-device SFSpeechRecognizer if SpeechAnalyzer fails on a recording with audible speech.
    private func transcribeWithApple(_ url: URL) async throws -> String {
        let hasAudibleSpeech = (try? Data(contentsOf: url)).map { WAVSpeechCheck.evaluate($0) == .speech } ?? true
        var analyzerError: Error?
        var best = AppleTranscript.empty
        do {
            best = try await AppleSpeechAssets.transcript(url)
            if best.isComplete { return best.text }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            analyzerError = error
            await AppleSpeechAssets.resetCachedModels()
            if let retried = try? await AppleSpeechAssets.transcript(url), retried.isBetter(than: best) {
                best = retried
                if best.isComplete { return best.text }
            }
        }
        if hasAudibleSpeech {
            let legacy = try? await Self.legacyAppleTranscription(url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            scheduleAppleReservationRestore()
            if let legacy, !legacy.isEmpty {
                if best.text.isEmpty || legacy.count > Int(Double(best.text.count) * 1.35) {
                    return legacy
                }
            }
        }
        if !best.text.isEmpty { return best.text }
        if let analyzerError { throw analyzerError }
        return ""
    }

    private static func legacyAppleTranscription(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw SpeechFailure("On-device Apple speech recognition is unavailable for your Mac language. Change the language in macOS or choose another local model.")
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            throw SpeechFailure("Allow speech recognition in System Settings → Privacy & Security → Speech Recognition.")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        return try await withCheckedThrowingContinuation { continuation in
            let completion = SpeechRecognitionCompletion(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    completion.finish(.success(result.bestTranscription.formattedString))
                } else if let error {
                    completion.finish(.failure(error))
                }
            }
        }
    }
}
