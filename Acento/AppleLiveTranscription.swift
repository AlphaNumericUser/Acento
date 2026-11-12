@preconcurrency import AVFoundation
import Speech

/// Streams microphone audio into Apple's on-device SpeechAnalyzer while the user speaks,
/// so releasing the shortcut only has to finalize the last moment of speech.
/// The WAV recording is still written in parallel and remains the fallback.
nonisolated final class AppleLiveTranscription: @unchecked Sendable {
    /// Format configured on the capture output (see `prepareCapture`).
    static let microphoneFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let setup: Task<(SpeechAnalyzer, Task<String, Error>), Error>

    init(locale: Locale = .current) {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        setup = Task(priority: .userInitiated) {
            guard SpeechTranscriber.isAvailable,
                  let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw SpeechFailure("Live Apple transcription is unavailable for your Mac language.")
            }
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw SpeechFailure("Download the Apple speech model in Models before recording.")
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber],
                                          options: .init(priority: .userInitiated, modelRetention: .lingering))
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                       considering: Self.microphoneFormat) ?? Self.microphoneFormat
            try await analyzer.prepareToAnalyze(in: format)
            let collector = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal {
                    text += String(result.text.characters)
                }
                return text
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
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Called on the audio queue after the last buffer, so no audio is lost.
    func finishInput() { continuation.finish() }

    func finish() async throws -> String {
        continuation.finish()
        let (analyzer, collector) = try await setup.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func transcribe(_ url: URL, locale: Locale = .current) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFailure("Live Apple transcription is unavailable for your Mac language.")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let file = try AVAudioFile(forReading: url)
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let text = try await collector.value
        withExtendedLifetime(analyzer) {}
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
