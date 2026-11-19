@preconcurrency import AVFoundation
import Speech

/// Final text from SpeechAnalyzer together with how much of the audio its results cover.
/// A lingering in-process model has been seen returning only the last segment of a long
/// recording (e.g. 20–28 s of a 28 s dictation); coverage makes that detectable.
nonisolated struct AppleTranscript: Sendable, Equatable {
    var text: String
    /// Sum of the final results' audio ranges, in seconds.
    var coveredSeconds: Double
    /// Start of the earliest final result, in seconds; nil without results.
    var firstStart: Double?
    /// Length of the analyzed audio, in seconds.
    var audioSeconds: Double

    static let empty = AppleTranscript(text: "", coveredSeconds: 0, firstStart: nil, audioSeconds: 0)

    /// Results normally tile the whole recording (0–9.5, 9.5–20.3, 20.3–28.4 s). A transcript is
    /// suspicious when its results skip the beginning or leave most of a long recording uncovered.
    var isComplete: Bool {
        guard !text.isEmpty else { return false }
        guard audioSeconds >= 4 else { return true }
        if let firstStart, firstStart > max(3, audioSeconds * 0.25) { return false }
        return coveredSeconds >= audioSeconds * 0.6
    }

    /// Prefers complete transcripts, then the one covering more audio, then the longer text.
    func isBetter(than other: AppleTranscript) -> Bool {
        if isComplete != other.isComplete { return isComplete }
        if abs(coveredSeconds - other.coveredSeconds) > 0.5 { return coveredSeconds > other.coveredSeconds }
        return text.count > other.text.count
    }
}

/// Accumulates final SpeechTranscriber results and their time ranges.
nonisolated struct AppleTranscriptCollector {
    private(set) var text = ""
    private(set) var covered = 0.0
    private(set) var firstStart: Double?

    mutating func add(text piece: String, start: Double, duration: Double) {
        text += piece
        if start.isFinite, duration.isFinite, duration > 0 {
            covered += duration
            firstStart = min(firstStart ?? start, start)
        }
    }

    func transcript(audioSeconds: Double) -> AppleTranscript {
        AppleTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), coveredSeconds: covered,
                        firstStart: firstStart, audioSeconds: audioSeconds)
    }
}

/// Streams microphone audio into Apple's on-device SpeechAnalyzer while the user speaks,
/// so releasing the shortcut only has to finalize the last moment of speech.
/// The WAV recording is still written in parallel and remains the fallback.
nonisolated final class AppleLiveTranscription: @unchecked Sendable {
    /// Format configured on the capture output (see `prepareCapture`).
    static let microphoneFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let setup: Task<(SpeechAnalyzer, Task<AppleTranscriptCollector, Error>), Error>
    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var appendedSeconds = 0.0 // guarded by lock; written on the audio queue
    private let reservationUnavailableFlag: AtomicFlag

    /// True when the Apple model is on disk, an install/reservation attempt finished,
    /// yet AssetInventory still did not report `.installed` (signature of a stale XPC 4099 state).
    var didFailReservation: Bool { reservationUnavailableFlag.isSet }

    init(locale: Locale = .current, autoReserve: Bool = true) {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        let unavailableFlag = AtomicFlag()
        self.reservationUnavailableFlag = unavailableFlag
        setup = Task(priority: .userInitiated) {
            guard SpeechTranscriber.isAvailable,
                  let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw SpeechFailure("Live Apple transcription is unavailable for your Mac language.")
            }
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            var status = await AssetInventory.status(forModules: [transcriber])
            if status != .installed, autoReserve, AppleSpeechAssets.isOnDisk(supported) {
                try? await AppleSpeechAssets.install(locale: supported) { _ in }
                status = await AssetInventory.status(forModules: [transcriber])
                if status != .installed {
                    unavailableFlag.set()
                }
            }
            guard status == .installed else {
                throw SpeechFailure("Download the Apple speech model in Models before recording.")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber],
                                          options: .init(priority: .userInitiated, modelRetention: .lingering))
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                       considering: Self.microphoneFormat) ?? Self.microphoneFormat
            try await analyzer.prepareToAnalyze(in: format)
            let collector = Task {
                var collected = AppleTranscriptCollector()
                for try await result in transcriber.results where result.isFinal {
                    collected.add(text: String(result.text.characters),
                                  start: result.range.start.seconds, duration: result.range.duration.seconds)
                }
                return collected
            }
            let converter = BufferConverter(target: format)
            try await analyzer.start(inputSequence: stream.compactMap { converter.convert($0) })
            return (analyzer, collector)
        }
    }

    /// Called on the audio queue for every captured buffer.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        lock.lock()
        if format.sampleRate > 0 { appendedSeconds += Double(frames) / format.sampleRate }
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Called on the audio queue after the last buffer, so no audio is lost.
    func finishInput() { continuation.finish() }

    func finish() async throws -> AppleTranscript {
        continuation.finish()
        let (analyzer, collector) = try await setup.value
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Never leave a half-finished analyzer holding the shared model.
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        lock.lock()
        let seconds = appendedSeconds
        lock.unlock()
        return try await collector.value.transcript(audioSeconds: seconds)
    }

    func cancel() {
        continuation.finish()
        let setup = setup
        Task {
            guard let (analyzer, collector) = try? await setup.value else { return }
            await analyzer.cancelAndFinishNow()
            collector.cancel()
        }
    }
}

/// Converts captured buffers to the analyzer's format; the identity in the usual 16 kHz Int16 case.
nonisolated private final class BufferConverter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    // The analyzer consumes its input sequence serially, so no locking is needed.
    func convert(_ input: AnalyzerInput) -> AnalyzerInput? {
        let buffer = input.buffer
        guard buffer.format != target else { return input }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) let source = buffer
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        return error == nil && output.frameLength > 0 ? AnalyzerInput(buffer: output) : nil
    }
}

enum AppleSpeechAssets {
    /// `nil` when SpeechTranscriber does not support this Mac or its language.
    static func status(locale: Locale = .current) async -> AssetInventory.Status? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        return await AssetInventory.status(forModules: [SpeechTranscriber(locale: supported, preset: .transcription)])
    }

    static func supportedLocale(_ locale: Locale = .current) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Best-effort check of the shared system asset store. AssetInventory only reports this app's
    /// reservation, so after a release it says "supported" even though the files remain on disk.
    /// Used only to label the button; an unknown layout just falls back to "Download".
    static func isOnDisk(_ locale: Locale) -> Bool {
        guard let language = locale.language.languageCode?.identifier else { return false }
        let root = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition")
        let wanted = "com.apple.speech.asr.transcription.\(language)"
        guard let purposes = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return false }
        for purpose in purposes {
            let assets = (try? FileManager.default.contentsOfDirectory(at: purpose, includingPropertiesForKeys: nil)) ?? []
            for asset in assets where asset.pathExtension == "asset" {
                guard let info = NSDictionary(contentsOf: asset.appendingPathComponent("Info.plist")) else { continue }
                let properties = info["MobileAssetProperties"] as? [String: Any]
                if properties?["AssetSpecifier"] as? String == wanted || info["CFBundleName"] as? String == wanted { return true }
            }
        }
        return false
    }

    /// Releases this app's reservation; macOS deletes the assets when no other app needs them.
    static func release() async {
        for locale in await AssetInventory.reservedLocales {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }

    static func install(locale: Locale = .current, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFailure("Live Apple transcription is unavailable for your Mac language.")
        }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [SpeechTranscriber(locale: supported, preset: .transcription)]) else { return }
        let observation = request.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    /// Transcribes a saved recording with SpeechAnalyzer (used for retries and as the live fallback).
    /// If the result skips part of the audio, the cached in-process model is released (what quitting
    /// the app used to fix) and the file is analyzed again with a freshly loaded model.
    static func transcribe(_ url: URL, locale: Locale = .current) async throws -> String {
        try await transcript(url, locale: locale).text
    }

    static func transcript(_ url: URL, locale: Locale = .current) async throws -> AppleTranscript {
        var best = AppleTranscript.empty
        var lastError: Error?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if attempt > 0 { await resetCachedModels() }
            do {
                let result = try await analyzeFile(url, locale: locale)
                if result.isBetter(than: best) { best = result }
                if result.isComplete { return result }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        if best.text.isEmpty, let lastError { throw lastError }
        return best
    }

    /// Drops SpeechAnalyzer models cached in this process; the next analysis loads them again.
    static func resetCachedModels() async {
        await SpeechModels.endRetention()
    }

    private static func analyzeFile(_ url: URL, locale: Locale) async throws -> AppleTranscript {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFailure("Live Apple transcription is unavailable for your Mac language.")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let file = try AVAudioFile(forReading: url)
        let seconds = file.fileFormat.sampleRate > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0
        let collector = Task {
            var collected = AppleTranscriptCollector()
            for try await result in transcriber.results where result.isFinal {
                collected.add(text: String(result.text.characters),
                              start: result.range.start.seconds, duration: result.range.duration.seconds)
            }
            return collected
        }
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        } catch {
            collector.cancel()
            throw error
        }
        let collected = try await withTaskCancellationHandler {
            try await collector.value
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        withExtendedLifetime(analyzer) {}
        return collected.transcript(audioSeconds: seconds)
    }
}
