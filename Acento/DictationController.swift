import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import Carbon
import CoreMedia
import SwiftUI
import Combine

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case commandRight = "commandRight"
    case controlOptionSpace = "controlOptionSpace"
    case optionSpace = "optionSpace"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .commandRight: "Right Command"
        case .controlOptionSpace: "⌃ Control + ⌥ Option + Space"
        case .optionSpace: "⌥ Option + Space"
        }
    }
    var keyCode: UInt32 { self == .commandRight ? 54 : 49 }
    var modifiers: UInt32 {
        switch self {
        case .commandRight: 0
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .optionSpace: UInt32(optionKey)
        }
    }
}

enum MicrophoneDevices {
    nonisolated static var all: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

enum DictationPhase: Equatable {
    case idle, preparing, recording, transcribing, polishing

    var isCapturing: Bool { self == .preparing || self == .recording }
    var isProcessing: Bool { self == .transcribing || self == .polishing }
}

private final class AudioMeterDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated let onLevel: @Sendable (Double) -> Void
    nonisolated let writer: WaveWriter
    nonisolated let live: AppleLiveTranscription?
    nonisolated(unsafe) private var lastLevelUpdate: TimeInterval = 0 // audioQueue only

    nonisolated init(writer: WaveWriter, live: AppleLiveTranscription?, onLevel: @escaping @Sendable (Double) -> Void) {
        self.writer = writer
        self.live = live
        self.onLevel = onLevel
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.append(sampleBuffer)
        live?.append(sampleBuffer)
        // Throttle before allocating samples or scheduling work on MainActor.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelUpdate >= 1.0 / 30 else { return }
        lastLevelUpdate = now
        guard let buffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let sampleCount = min(CMBlockBufferGetDataLength(buffer) / MemoryLayout<Int16>.size, 2048)
        guard sampleCount > 0 else { return }
        var samples = [Int16](repeating: 0, count: sampleCount)
        let result = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard result == noErr else { return }
        let power = samples.reduce(0.0) { let value = Double($1) / 32768; return $0 + value * value } / Double(sampleCount)
        // Loudness is perceived in decibels: map -50...-12 dBFS to 0...1, curved for more speech contrast.
        let decibels = 10 * log10(max(power, 1e-10))
        onLevel(pow(max(0, min(1, (decibels + 50) / 38)), 1.3))
    }
}

// Accessed exclusively on captureQueue. The stopped session retains device and
// format configuration, but no recording delegate or live microphone capture.
nonisolated private final class CaptureConfigurationCache: @unchecked Sendable {
    var selectedID: String?
    var device: AVCaptureDevice?
    var session: AVCaptureSession?
    var output: AVCaptureAudioDataOutput?
    var activeID: UUID?
}

struct BarNotice: Equatable {
    var id = UUID()
    let text: String
    let symbol: String
    var action: (() -> Void)?

    static func == (lhs: BarNotice, rhs: BarNotice) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class DictationController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording { SystemAudioMuter.shared.engage() } else { SystemAudioMuter.shared.release() }
        }
    }
    @Published private(set) var phase: DictationPhase = .idle {
        didSet { updateEscapeHotkey() }
    }
    @Published private(set) var isHandsFree = false
    @Published var barExpanded = false
    let audioMeter = DictationMeter()
    @Published private(set) var cancellationVisible = false
    @Published private(set) var canUndoCancellation = false
    @Published var message: String?
    @Published var shortcutStatus: String?
    /// Brief status shown in the floating bar after a dictation, such as a missing connection.
    @Published private(set) var notice: BarNotice?
    /// The current recording uses an API model offline with no local fallback, so it will only be saved.
    @Published var recordingOffline = false
    private var noticeTask: Task<Void, Never>?
    private(set) var shortcutRegistrationFailed = false

    private var activeCapture: PreparedCapture?
    private let captureCache = CaptureConfigurationCache()
    private let audioQueue = DispatchQueue(label: "com.useacento.acento.audio-samples", qos: .userInitiated)
    private var recordingTarget: TextInsertionTarget?
    private var targetCaptureTask: Task<TextInsertionTarget?, Never>?
    private var recordingModel: SpeechModel?
    var selectedModel: (() -> SpeechModel?)?
    var isModelReady: (() -> Bool)?
    var onFinished: (@MainActor (URL, TextInsertionTarget?, SpeechModel, AppleLiveTranscription?) async -> Void)?
    var onWillRecord: (@MainActor (SpeechModel) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenModels: (() -> Void)?
    private let sounds = DictationSoundPlayer()
    private var panel: NSPanel?
    private var barPositioner: DockAwareBarPositioner?
    private var recoveryPanel: NSPanel?
    private var processingTask: Task<Void, Never>?
    private var pendingAudio: URL?
    private var processingContext: (target: TextInsertionTarget?, model: SpeechModel)?
    private var cancelledRecording: (url: URL, target: TextInsertionTarget?, model: SpeechModel)?
    private var cancellationID: UUID?
    private var cancellationTask: Task<Void, Never>?
    private var cancellationStarted: TimeInterval = 0

    private static let cancellationDuration: TimeInterval = 3
    /// Seconds left while the pointer rests on the notice; the countdown is paused meanwhile.
    private var cancellationPausedRemaining: TimeInterval?
    var cancellationRemaining: Double {
        if let paused = cancellationPausedRemaining { return paused / Self.cancellationDuration }
        return max(0, min(1, 1 - (ProcessInfo.processInfo.systemUptime - cancellationStarted) / Self.cancellationDuration))
    }
    private var operationID = UUID()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var lastExternalApplication: NSRunningApplication?
    /// Acento's own text field that had focus when dictation started, if any.
    private weak var ownTextField: NSTextView?
    private let captureQueue = DispatchQueue(label: "com.useacento.acento.capture", qos: .userInitiated)
    private var hotkeys: [EventHotKeyRef] = []
    private var escapeHotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var captureRequestID = UUID()
    private var lastTap: Date?
    private var releaseTask: Task<Void, Never>?
    private var holdingPrimary = false
    private var handsFree = false
    private var ignorePrimaryUntilRelease = false
    var isEditingShortcut = false {
        didSet {
            guard oldValue != isEditingShortcut else { return }
            configureShortcut()
        }
    }
    private var commandGesture = RightCommandGesture()
    private var commandHoldTask: Task<Void, Never>?
    private var modifierShortcutDown = false

    func configureShortcut() {
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "rightCommandShortcutMigrated") {
            defaults.set(54, forKey: "shortcutKeyCode")
            defaults.set(0, forKey: "shortcutModifiers")
            defaults.set("Right Command", forKey: "shortcutLabel")
            defaults.set(true, forKey: "doubleTapFreeMode")
            defaults.set(true, forKey: "rightCommandShortcutMigrated")
        }
        commandHoldTask?.cancel()
        commandGesture = RightCommandGesture()
        modifierShortcutDown = false
        if defaults.object(forKey: "shortcutKeyCode") == nil {
            let legacy = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .commandRight
            defaults.set(Int(legacy.keyCode), forKey: "shortcutKeyCode")
            defaults.set(Int(legacy.modifiers), forKey: "shortcutModifiers")
            defaults.set(legacy.title.replacingOccurrences(of: "Hold ", with: ""), forKey: "shortcutLabel")
        }
        if handler == nil {
            var eventTypes = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let context = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let context, let event else { return noErr }
                let controller = Unmanaged<DictationController>.fromOpaque(context).takeUnretainedValue()
                var id = EventHotKeyID(signature: 0, id: 0)
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard result == noErr else { return result }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let hotkeyID = id.id
                Task { @MainActor in
                    controller.handleHotkey(id: hotkeyID, pressed: pressed)
                }
                return noErr
            }, eventTypes.count, &eventTypes, context, &handler)
        }
        var primary: EventHotKeyRef?
        let primaryStatus = (usesMonitoredShortcut || isEditingShortcut) ? noErr : RegisterEventHotKey(
            UInt32(defaults.integer(forKey: "shortcutKeyCode")),
            UInt32(defaults.integer(forKey: "shortcutModifiers")),
            EventHotKeyID(signature: OSType(0x53575052), id: 1),
            GetApplicationEventTarget(), 0, &primary
        )
        if let primary { hotkeys.append(primary) }
        shortcutRegistrationFailed = primaryStatus != noErr
        shortcutStatus = primaryStatus == noErr ? nil : "That shortcut is already in use. Press Change to choose another."
        if usesMonitoredShortcut, !isEditingShortcut, !AXIsProcessTrusted() {
            shortcutStatus = "Allow Accessibility access to use modifier shortcuts in other apps."
            if !defaults.bool(forKey: "rightCommandAccessPrompted") {
                defaults.set(true, forKey: "rightCommandAccessPrompted")
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        }
        installObservers()
        refreshBarVisibility()
        if defaults.object(forKey: "soundsEnabled") as? Bool ?? true {
            sounds.prepare(DictationSound.allCases.compactMap { AudioCatalog.url(for: $0.resource) })
        }
    }

    private var usesModifierShortcut: Bool {
        ShortcutKey.modifierNames[UInt16(UserDefaults.standard.integer(forKey: "shortcutKeyCode"))] != nil
    }

    private var usesMonitoredShortcut: Bool {
        usesModifierShortcut || UserDefaults.standard.integer(forKey: "shortcutModifiers") & ShortcutKey.fnModifier != 0
    }

    private func handleCommandEvent(_ event: NSEvent) {
        guard usesMonitoredShortcut, !isEditingShortcut, !phase.isProcessing else { return }
        let key = UInt16(UserDefaults.standard.integer(forKey: "shortcutKeyCode"))
        let modifiers = UserDefaults.standard.integer(forKey: "shortcutModifiers")
        if !usesModifierShortcut {
            if event.type == .keyDown, event.keyCode == key, !event.isARepeat,
               ShortcutKey.capturedModifiers(event) == modifiers {
                handleHotkey(id: 1, pressed: true)
            } else if event.type == .keyUp, event.keyCode == key {
                handleHotkey(id: 1, pressed: false)
            } else if event.type == .flagsChanged, holdingPrimary,
                      !event.modifierFlags.contains(.function) {
                handleHotkey(id: 1, pressed: false)
            }
            return
        }
        if key == 57, event.type == .flagsChanged, event.keyCode == key {
            if ShortcutKey.capturedModifiers(event) == modifiers { toggle() }
            return
        }
        if event.type == .keyDown || (event.type == .flagsChanged && event.keyCode != key) {
            if event.type == .flagsChanged, modifierShortcutDown,
               ShortcutKey.capturedModifiers(event) & modifiers != modifiers {
                finishModifierGesture()
                return
            }
            commandHoldTask?.cancel()
            if commandGesture.useInCombination(), phase.isCapturing, !handsFree {
                stop(cancelled: true)
            }
            return
        }
        guard event.type == .flagsChanged, event.keyCode == key,
              let mask = ShortcutKey.deviceMasks[key] else { return }
        let pressed = event.modifierFlags.rawValue & mask != 0
        if pressed {
            guard commandGesture.press() else { return }
            if ShortcutKey.capturedModifiers(event) != modifiers {
                _ = commandGesture.useInCombination()
                return
            }
            modifierShortcutDown = true
            guard !handsFree else { return }
            if commandGesture.beginHandsFree(at: ProcessInfo.processInfo.systemUptime,
                doubleTap: UserDefaults.standard.object(forKey: "doubleTapFreeMode") as? Bool ?? true) {
                handsFree = true
                start()
                return
            }
            commandHoldTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 120_000_000) }
                catch { return }
                guard let self, !self.isEditingShortcut, self.commandGesture.beginHold(), self.phase == .idle else { return }
                self.holdingPrimary = true
                self.start()
            }
        } else {
            finishModifierGesture()
        }
    }

    private func finishModifierGesture() {
        modifierShortcutDown = false
        commandHoldTask?.cancel()
        commandHoldTask = nil
        let action = commandGesture.release(at: ProcessInfo.processInfo.systemUptime,
            handsFree: handsFree, doubleTap: UserDefaults.standard.object(forKey: "doubleTapFreeMode") as? Bool ?? true)
        holdingPrimary = false
        switch action {
        case .none: break
        case .startHandsFree:
            handsFree = true
            start()
        case .finish:
            if phase.isCapturing { stop() }
        }
    }

    private func updateEscapeHotkey() {
        if let escapeHotkey {
            UnregisterEventHotKey(escapeHotkey)
            self.escapeHotkey = nil
        }
        guard phase != .idle else { return }
        guard UserDefaults.standard.integer(forKey: "shortcutKeyCode") != 53
            || UserDefaults.standard.integer(forKey: "shortcutModifiers") != 0 else { return }
        // Register only during dictation so Escape keeps its normal behavior at rest.
        // Carbon delivery also works when global NSEvent monitoring is unavailable.
        RegisterEventHotKey(53, 0, EventHotKeyID(signature: OSType(0x53575052), id: 3),
                            GetApplicationEventTarget(), 0, &escapeHotkey)
    }

    private func handleEscape(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, phase != .idle,
              !isEditingShortcut else { return false }
        if UserDefaults.standard.integer(forKey: "shortcutKeyCode") == 53,
           ShortcutKey.capturedModifiers(event) == UserDefaults.standard.integer(forKey: "shortcutModifiers") { return false }
        commandHoldTask?.cancel()
        commandGesture = RightCommandGesture()
        stop(cancelled: true)
        return true
    }

    private func handleHotkey(id: UInt32, pressed: Bool) {
        guard !isEditingShortcut else { return }
        if id == 3 {
            if pressed, phase != .idle, !isEditingShortcut {
                commandHoldTask?.cancel()
                commandGesture = RightCommandGesture()
                stop(cancelled: true)
            }
            return
        }
        if id == 1, !pressed, ignorePrimaryUntilRelease {
            ignorePrimaryUntilRelease = false
            holdingPrimary = false
            return
        }
        guard !phase.isProcessing else { return }
        guard id == 1 else { return }
        if pressed {
            guard !ignorePrimaryUntilRelease else { return }
            guard !holdingPrimary else { return }
            if handsFree {
                ignorePrimaryUntilRelease = true
                stop()
                return
            }
            let now = Date()
            releaseTask?.cancel()
            releaseTask = nil
            if (UserDefaults.standard.object(forKey: "doubleTapFreeMode") as? Bool ?? true),
               let lastTap, now.timeIntervalSince(lastTap) < 0.38 {
                self.lastTap = nil
                holdingPrimary = false
                handsFree = true
                if phase.isCapturing {
                    isHandsFree = isRecording
                    if isRecording { playSound(.lock) }
                } else { start() }
            } else {
                lastTap = now
                holdingPrimary = true
                start()
            }
        } else {
            if ignorePrimaryUntilRelease {
                ignorePrimaryUntilRelease = false
                return
            }
            if holdingPrimary {
                holdingPrimary = false
                if !handsFree {
                    if UserDefaults.standard.object(forKey: "doubleTapFreeMode") as? Bool ?? true {
                        releaseTask = Task { @MainActor [weak self] in
                            do { try await Task.sleep(nanoseconds: 380_000_000) }
                            catch { return }
                            guard let self, !self.handsFree, self.phase.isCapturing else { return }
                            self.stop()
                        }
                    } else { stop() }
                }
            }
        }
    }

    func toggle() {
        if phase.isCapturing { stop() }
        else if phase == .idle { handsFree = true; start() }
    }

    func start() {
        guard phase == .idle else { return }
        guard let model = selectedModel?(), isModelReady?() == true else {
            message = "Choose and install a dictation model in Models before recording."
            playSound(.error)
            handsFree = false
            showSetupNotice()
            return
        }
        clearCancellation()
        clearNotice()
        recordingModel = model
        recordingOffline = false
        onWillRecord?(model)
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Dictating while Acento itself is in front targets Acento: its focused text field, or the copy panel.
        let acentoInFront = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let destination = acentoInFront ? nil : frontmost
        ownTextField = acentoInFront ? Self.focusedOwnTextView() : nil
        operationID = UUID()
        phase = .preparing
        refreshBarVisibility()
        message = nil
        let currentOperation = operationID
        recordingTarget = nil
        targetCaptureTask = Task { @MainActor [weak self] in
            let target = await TextInserter.captureAsync(application: destination)
            if let self, self.operationID == currentOperation, self.phase.isCapturing {
                self.recordingTarget = target
                if let destination { self.lastExternalApplication = destination }
            }
            return target
        }
        let requestID = UUID()
        captureRequestID = requestID
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            beginCapture()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self, self.captureRequestID == requestID else { return }
                guard granted else {
                    self.message = "Allow microphone access in System Settings → Privacy & Security → Microphone."
                    self.resetCaptureState()
                    self.playSound(.error)
                    return
                }
                self.beginCapture()
            }
        }
    }

    nonisolated private struct PreparedCapture: @unchecked Sendable {
        // Constructed on captureQueue, then handed to the main actor once.
        let session: AVCaptureSession
        let output: AVCaptureAudioDataOutput
        let meter: AudioMeterDelegate
        let id: UUID
    }

    nonisolated private static func prepareCapture(selected: String, id: UUID, cache: CaptureConfigurationCache,
                                                   live: AppleLiveTranscription?,
                                                   audioQueue: DispatchQueue,
                                                   onLevel: @escaping @Sendable (Double) -> Void) throws -> PreparedCapture {
        let device: AVCaptureDevice?
        if !selected.isEmpty, cache.selectedID == selected, let cached = cache.device, cached.isConnected {
            device = cached
        } else if selected.isEmpty {
            device = AVCaptureDevice.default(for: .audio)
        } else {
            device = MicrophoneDevices.all.first { $0.uniqueID == selected }
                ?? AVCaptureDevice.default(for: .audio)
        }
        guard let device else { throw SpeechFailure("No microphone is available.") }
        let capture: AVCaptureSession
        let audio: AVCaptureAudioDataOutput
        if cache.device?.uniqueID == device.uniqueID, let session = cache.session, let output = cache.output {
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
            capture = session
            audio = output
        } else {
            cache.output?.setSampleBufferDelegate(nil, queue: nil)
            if cache.session?.isRunning == true { cache.session?.stopRunning() }
            let input = try AVCaptureDeviceInput(device: device)
            capture = AVCaptureSession()
            audio = AVCaptureAudioDataOutput()
            audio.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                                   AVLinearPCMBitDepthKey: 16,
                                   AVLinearPCMIsFloatKey: false,
                                   AVLinearPCMIsBigEndianKey: false,
                                   AVNumberOfChannelsKey: 1,
                                   AVSampleRateKey: 16000]
            guard capture.canAddInput(input), capture.canAddOutput(audio) else {
                throw SpeechFailure("Unable to start microphone capture.")
            }
            capture.beginConfiguration()
            capture.addInput(input)
            capture.addOutput(audio)
            capture.commitConfiguration()
            cache.device = device
            cache.session = capture
            cache.output = audio
        }
        cache.selectedID = selected
        let writer = try WaveWriter()
        let meter = AudioMeterDelegate(writer: writer, live: live, onLevel: onLevel)
        cache.activeID = id
        audio.setSampleBufferDelegate(meter, queue: audioQueue)
        capture.startRunning()
        guard capture.isRunning else {
            audio.setSampleBufferDelegate(nil, queue: nil)
            cache.activeID = nil
            cache.session = nil
            cache.output = nil
            live?.cancel()
            audioQueue.async {
                _ = try? writer.finish()
                RecordingStorage.delete(writer.url.lastPathComponent)
            }
            throw SpeechFailure("Unable to start microphone capture.")
        }
        return PreparedCapture(session: capture, output: audio, meter: meter, id: id)
    }

    nonisolated private static func endCapture(_ prepared: PreparedCapture, cache: CaptureConfigurationCache) {
        // A delayed cancellation must never stop a newer recording reusing the session.
        guard cache.activeID == prepared.id else { return }
        prepared.output.setSampleBufferDelegate(nil, queue: nil)
        if prepared.session.isRunning { prepared.session.stopRunning() }
        cache.activeID = nil
    }

    private func beginCapture() {
        let selected = UserDefaults.standard.string(forKey: "micID") ?? ""
        let currentOperation = operationID
        let requestID = captureRequestID
        let onLevel: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == currentOperation, self.isRecording else { return }
                self.audioMeter.update(value)
            }
        }
        let audioQueue = self.audioQueue
        let captureQueue = self.captureQueue
        let cache = captureCache
        // Apple's on-device model loads while the microphone starts and the user speaks.
        let live = recordingModel == .apple ? AppleLiveTranscription() : nil
        Task { @MainActor [weak self] in
            do {
                let prepared: PreparedCapture = try await withCheckedThrowingContinuation { continuation in
                    captureQueue.async {
                        do { continuation.resume(returning: try Self.prepareCapture(selected: selected, id: requestID, cache: cache, live: live,
                                                                                  audioQueue: audioQueue, onLevel: onLevel)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                guard let self, self.captureRequestID == requestID, self.phase == .preparing else {
                    live?.cancel()
                    captureQueue.async {
                        Self.endCapture(prepared, cache: cache)
                        audioQueue.async {
                            _ = try? prepared.meter.writer.finish()
                            RecordingStorage.delete(prepared.meter.writer.url.lastPathComponent)
                        }
                    }
                    return
                }
                self.activeCapture = prepared
                self.isRecording = true
                self.phase = .recording
                self.isHandsFree = self.handsFree
                self.message = nil
                self.playSound(.start)
                self.refreshBarVisibility()
            } catch {
                live?.cancel()
                guard let self, self.captureRequestID == requestID, self.phase == .preparing else { return }
                self.message = error.localizedDescription
                self.resetCaptureState()
                self.playSound(.error)
            }
        }
    }

    func stop(cancelled: Bool = false) {
        releaseTask?.cancel()
        releaseTask = nil
        lastTap = nil
        if phase.isProcessing {
            guard cancelled else { return }
            showCancellation()
            if let pendingAudio, let processingContext {
                cancelledRecording = (pendingAudio, processingContext.target, processingContext.model)
                canUndoCancellation = true
            } else if let pendingAudio {
                RecordingStorage.delete(pendingAudio.lastPathComponent)
            }
            operationID = UUID()
            processingTask?.cancel()
            processingTask = nil
            pendingAudio = nil
            processingContext = nil
            phase = .idle
            message = nil
            playSound(.cancel)
            return
        }
        captureRequestID = UUID()
        handsFree = false
        if holdingPrimary { ignorePrimaryUntilRelease = true }
        holdingPrimary = false
        guard isRecording else {
            let wasPreparing = phase == .preparing
            if phase == .preparing {
                message = nil
                if cancelled { playSound(.cancel) }
            }
            resetCaptureState()
            if cancelled && wasPreparing { showCancellation() }
            return
        }
        isRecording = false
        audioMeter.reset()
        let prepared = activeCapture
        activeCapture = nil
        let writer = prepared?.meter.writer
        let live = prepared?.meter.live
        if cancelled { live?.cancel() }
        let target = recordingTarget
        recordingTarget = nil
        let targetTask = targetCaptureTask
        targetCaptureTask = nil
        let model = recordingModel
        recordingModel = nil
        isHandsFree = false
        phase = cancelled ? .idle : .transcribing
        let currentOperation = operationID
        if cancelled {
            operationID = UUID()
            showCancellation()
        }
        let cancelledID = cancellationID
        playSound(cancelled ? .cancel : .stop)
        message = nil
        let cache = captureCache
        let audioQueue = self.audioQueue
        captureQueue.async { [weak self] in
            // Detach before the queue fence so no audio can arrive after finish(). Stopping the
            // session is slow and synchronous, so it runs after the recording is handed off.
            if let prepared, cache.activeID == prepared.id { prepared.output.setSampleBufferDelegate(nil, queue: nil) }
            defer { if let prepared { Self.endCapture(prepared, cache: cache) } }
            audioQueue.async { [weak self] in
                guard let writer else { return }
                do {
                    let url = try writer.finish()
                    live?.finishInput()
                    Task { @MainActor [weak self] in
                        let resolvedTarget = await targetTask?.value ?? target
                        guard let self, !cancelled, self.operationID == currentOperation, let model else {
                            live?.cancel()
                            if let self, cancelled, let model, let cancelledID,
                               self.cancellationID == cancelledID, self.cancellationVisible {
                                self.cancelledRecording = (url, resolvedTarget, model)
                                self.canUndoCancellation = true
                                return
                            }
                            RecordingStorage.delete(url.lastPathComponent)
                            return
                        }
                        self.processRecording(url, target: resolvedTarget, model: model, live: live)
                    }
                } catch {
                    live?.cancel()
                    RecordingStorage.delete(writer.url.lastPathComponent)
                    if !cancelled {
                        Task { @MainActor [weak self] in
                            guard let self, self.operationID == currentOperation else { return }
                            self.message = error.localizedDescription
                            self.phase = .idle
                            self.playSound(.error)
                        }
                    }
                }
            }
        }
    }

    private func processRecording(_ url: URL, target: TextInsertionTarget?, model: SpeechModel,
                                  live: AppleLiveTranscription? = nil) {
        pendingAudio = url
        processingContext = (target, model)
        phase = .transcribing
        let currentOperation = operationID
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onFinished?(url, target, model, live)
            guard self.operationID == currentOperation else { return }
            self.pendingAudio = nil
            self.processingContext = nil
            self.processingTask = nil
            self.phase = .idle
        }
    }

    private func clearCancellation(deleteAudio: Bool = true) {
        cancellationTask?.cancel()
        cancellationTask = nil
        cancellationID = nil
        cancellationPausedRemaining = nil
        if deleteAudio, let cancelledRecording {
            RecordingStorage.delete(cancelledRecording.url.lastPathComponent)
        }
        cancelledRecording = nil
        canUndoCancellation = false
        cancellationVisible = false
    }

    private func showCancellation() {
        clearCancellation()
        clearNotice()
        let id = UUID()
        cancellationID = id
        cancellationStarted = ProcessInfo.processInfo.systemUptime
        cancellationVisible = true
        barExpanded = false
        scheduleCancellationDismissal(after: Self.cancellationDuration)
    }

    private func scheduleCancellationDismissal(after seconds: TimeInterval) {
        guard let id = cancellationID else { return }
        cancellationTask?.cancel()
        cancellationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.cancellationID == id else { return }
            self.clearCancellation()
        }
    }

    /// Hovering the notice pauses its countdown so Undo is never lost while reaching for it.
    func setCancellationHover(_ hovering: Bool) {
        guard cancellationVisible, cancellationID != nil else { return }
        if hovering, cancellationPausedRemaining == nil {
            cancellationPausedRemaining = cancellationRemaining * Self.cancellationDuration
            cancellationTask?.cancel()
        } else if !hovering, let remaining = cancellationPausedRemaining {
            cancellationPausedRemaining = nil
            cancellationStarted = ProcessInfo.processInfo.systemUptime - (Self.cancellationDuration - remaining)
            scheduleCancellationDismissal(after: max(0.8, remaining))
        }
    }

    func undoCancellation() {
        guard phase == .idle, let cancelledRecording, canUndoCancellation else { return }
        clearCancellation(deleteAudio: false)
        operationID = UUID()
        message = nil
        processRecording(cancelledRecording.url, target: cancelledRecording.target, model: cancelledRecording.model)
    }

    func markPolishing() { phase = .polishing }

    func showNotice(_ text: String, symbol: String = "wifi.slash", duration: TimeInterval = 4,
                    action: (() -> Void)? = nil) {
        noticeTask?.cancel()
        notice = BarNotice(text: text, symbol: symbol, action: action)
        noticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            catch { return }
            self?.notice = nil
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    func retainRecording() { pendingAudio = nil }

    /// The paste reached the destination: hide the spinner while delivery is still being verified.
    func markDelivered() {
        guard phase.isProcessing else { return }
        pendingAudio = nil
        processingContext = nil
        phase = .idle
    }

    func playSound(_ cue: DictationSound) {
        guard UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true,
              let url = AudioCatalog.url(for: cue.resource) else { return }
        // Cues during a muted dictation (e.g. hands-free lock) briefly lift the mute so they stay audible.
        if isRecording { SystemAudioMuter.shared.allowSound(for: .milliseconds(cue == .start || cue == .lock ? 250 : 1000)) }
        sounds.play(url, volume: cue == .cancel ? 0.55 : 0.8)
    }

    func refreshBarVisibility() {
        guard UserDefaults.standard.object(forKey: "showBar") as? Bool ?? true else {
            barExpanded = false
            panel?.orderOut(nil)
            barPositioner?.stop()
            return
        }
        if panel == nil { showBar() }
        else { positionBar(); panel?.orderFrontRegardless(); barPositioner?.start() }
    }

    private func resetCaptureState() {
        audioMeter.reset()
        targetCaptureTask?.cancel()
        targetCaptureTask = nil
        phase = .idle
        isRecording = false
        isHandsFree = false
        handsFree = false
        recordingTarget = nil
        recordingModel = nil
        if holdingPrimary { ignorePrimaryUntilRelease = true }
        holdingPrimary = false
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = app
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.handleEscape(event) else { return }
                self.handleCommandEvent(event)
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if self.handleEscape(event) { return true }
                self.handleCommandEvent(event)
                return false
            }
            return consumed ? nil : event
        }) { monitors.append(monitor) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.restoreBarOrder()
                if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self?.lastExternalApplication = app
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.positionBar() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionBar()
                self?.restoreBarOrder()
            }
        })
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.restoreBarOrder() }
            })
        }

    }

    private func positionBar() {
        barPositioner?.requestReposition()
    }

    private func restoreBarOrder() {
        guard UserDefaults.standard.object(forKey: "showBar") as? Bool ?? true else { return }
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
        barPositioner?.start()
    }

    private static func focusedOwnTextView() -> NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return textView
    }

    /// Types the dictation into the Acento text field focused at start, if it still has focus.
    func insertIntoOwnTextField(_ text: String) -> Bool {
        defer { ownTextField = nil }
        guard !text.isEmpty, NSApp.isActive, let textView = ownTextField,
              textView.window?.isKeyWindow == true, textView.window?.firstResponder === textView else { return false }
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    func showRecovery(text: String, target: TextInsertionTarget?, result: TextInsertionResult) {
        guard result != .cancelled else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        presentPanel(text: text, title: L10n.text("Recovered dictation")) { [weak self] recovery in
            DictationRecoveryView(text: text, initialResult: result, retry: { [weak self, weak recovery] in
            guard let self else { return .noTarget }
            let frontmost = NSWorkspace.shared.frontmostApplication
            let destination = await TextInserter.captureAsync(application:
                frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    ? frontmost : self.lastExternalApplication ?? target?.application)
            let result = await TextInserter.insert(text, into: destination)
            if result.succeeded {
                self.playSound(.paste)
                recovery?.close()
            } else if result != .cancelled { self.playSound(.error) }
            return result
            }, close: { [weak recovery] in recovery?.close() })
        }
    }

    /// Shown in place of a recording when no dictation model or API key is ready.
    func showSetupNotice() {
        let text = L10n.text("Choose a local model or add an API key in Models to start dictating.")
        presentPanel(text: text, title: L10n.text("Set up a dictation model first")) { [weak self] recovery in
            DictationRecoveryView(text: text, initialResult: .noTarget, retry: { .noTarget },
                                  close: { [weak recovery] in recovery?.close() },
                                  notice: "Set up a dictation model first",
                                  action: ("Open Models", { [weak self] in self?.onOpenModels?() }))
        }
    }

    private func presentPanel(text: String, title: String,
                              content: (DictationRecoveryPanel) -> DictationRecoveryView) {
        recoveryPanel?.close()
        let recovery = DictationRecoveryPanel(contentRect: NSRect(origin: .zero, size: DictationRecoveryView.size(for: text)),
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        recovery.title = title
        recovery.isReleasedWhenClosed = false
        recovery.isOpaque = false
        recovery.backgroundColor = .clear
        recovery.appearance = NSAppearance(named: .darkAqua)
        recovery.animationBehavior = .none
        recovery.hasShadow = true
        recovery.hidesOnDeactivate = false
        recovery.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        recovery.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        recovery.contentView = NSHostingView(rootView: content(recovery))
        let screen = panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        recovery.setFrameOrigin(NSPoint(x: screen.midX - recovery.frame.width / 2, y: screen.minY + 8))
        recoveryPanel = recovery
        recovery.orderFrontRegardless()
    }

    private func showBar() {
        let size = NSSize(width: 260, height: 96)
        let screen = NSScreen.main?.frame ?? .zero
        let rect = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 12, width: size.width, height: size.height)
        let bar = DictationBarPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = false
        bar.hidesOnDeactivate = false
        bar.animationBehavior = .none
        bar.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        bar.isFloatingPanel = true
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        bar.contentView = DictationBarHostingView(recorder: self)
        panel = bar
        barPositioner = DockAwareBarPositioner(panel: bar)
        barPositioner?.start()
        bar.orderFrontRegardless()
    }
}
