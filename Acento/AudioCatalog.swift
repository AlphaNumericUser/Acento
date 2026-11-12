import AVFoundation

/// Original synthesized cues from `Scripts/GenerateSounds.py`, bundled from `Acento/Sounds`.
enum AudioCatalog {
    static let startDefault = "acento-dictation-start.wav"
    static let stopDefault = "acento-dictation-stop.wav"

    static func url(for id: String) -> URL? {
        guard id.hasSuffix(".wav") else { return nil }
        let name = String(id.dropLast(4))
        return Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
    }
}

enum DictationSound: CaseIterable, Equatable {
    case start, stop, cancel, lock, paste, error, alert

    var resource: String {
        switch self {
        case .start: AudioCatalog.startDefault
        case .stop: AudioCatalog.stopDefault
        case .cancel: "acento-cancel.wav"
        case .lock: "acento-lock.wav"
        case .paste: "acento-paste.wav"
        case .error: "acento-error.wav"
        case .alert: "acento-alert.wav"
        }
    }
}

// Player setup and playback stay off the UI thread. Keep only the seven small
// dictation cues, rather than rebuilding an audio player on every key gesture.
nonisolated final class DictationSoundPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.useacento.acento.sounds", qos: .userInitiated)
    private var players: [String: AVAudioPlayer] = [:]
    private var current: AVAudioPlayer?

    func prepare(_ urls: [URL]) {
        queue.async { [self] in
            for url in urls where players[url.path] == nil {
                if let player = try? AVAudioPlayer(contentsOf: url) {
                    player.prepareToPlay()
                    players[url.path] = player
                }
            }
        }
    }

    func play(_ url: URL, volume: Float) {
        queue.async { [self] in
            guard let player = players[url.path] ?? (try? AVAudioPlayer(contentsOf: url)) else { return }
            players[url.path] = player
            current?.stop()
            player.currentTime = 0
            player.volume = volume
            current = player
            player.play()
        }
    }
}
