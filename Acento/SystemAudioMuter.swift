import CoreAudio
import Foundation

/// Silences the Mac's output device while dictating ("Mute audio while dictating") and restores it afterwards.
/// The previous state is persisted, so a crash mid-dictation still gets restored on next launch.
final class SystemAudioMuter {
    static let shared = SystemAudioMuter()
    static let settingKey = "muteAudioWhileDictating"
    private static let pendingKey = "mutedAudioRestore"
    /// Lets the start cue (0.18 s) finish before the output goes silent.
    private static let engageDelay: Duration = .milliseconds(250)

    private struct Restore: Codable {
        var deviceUID: String
        /// nil when the device was silenced with its mute switch; otherwise per-element volumes to restore.
        var volumes: [UInt32: Float32]?
    }

    private var wanted = false
    private var pending: Task<Void, Never>?
    private var restore: Restore?

    private init() {}

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? false }

    /// Restores audio left muted by a previous session that ended unexpectedly.
    func recoverFromPreviousSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingKey),
              let saved = try? JSONDecoder().decode(Restore.self, from: data) else { return }
        restore = saved
        unmute()
    }

    func engage() {
        guard isEnabled else { return }
        wanted = true
        schedule(after: Self.engageDelay)
    }

    func release() {
        wanted = false
        pending?.cancel()
        pending = nil
        unmute()
    }

    /// Briefly lets a cue through while dictation keeps the output muted.
    func allowSound(for duration: Duration) {
        guard wanted else { return }
        pending?.cancel()
        unmute()
        schedule(after: duration)
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.wanted else { return }
            self.mute()
        }
    }

    private func mute() {
        guard restore == nil, let device = Self.defaultOutputDevice(), let uid = Self.uid(of: device) else { return }
        if Self.isSettable(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) {
            // Already muted by the user: leave it alone and don't restore anything later.
            guard Self.getUInt32(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) == 0 else { return }
            save(Restore(deviceUID: uid, volumes: nil))
            Self.setUInt32(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, 1)
            return
        }
        var volumes: [UInt32: Float32] = [:]
        for element in [kAudioObjectPropertyElementMain, 1, 2] where Self.isSettable(device, kAudioDevicePropertyVolumeScalar, element: element) {
            if let value = Self.getFloat(device, kAudioDevicePropertyVolumeScalar, element: element) { volumes[element] = value }
        }
        guard !volumes.isEmpty, volumes.values.contains(where: { $0 > 0 }) else { return }
        save(Restore(deviceUID: uid, volumes: volumes))
        for element in volumes.keys { Self.setFloat(device, kAudioDevicePropertyVolumeScalar, element: element, 0) }
    }

    private func unmute() {
        guard let restore else { return }
        defer { save(nil) }
        guard let device = Self.device(forUID: restore.deviceUID) else { return }
        if let volumes = restore.volumes {
            for (element, value) in volumes { Self.setFloat(device, kAudioDevicePropertyVolumeScalar, element: element, value) }
        } else {
            Self.setUInt32(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, 0)
        }
    }

    private func save(_ value: Restore?) {
        restore = value
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(forUID uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func getUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> UInt32? {
        var address = address(selector, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, _ value: UInt32) {
        var address = address(selector, element: element)
        var value = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func getFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float32? {
        var address = address(selector, element: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, _ value: Float32) {
        var address = address(selector, element: element)
        var value = value
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
