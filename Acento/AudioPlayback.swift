import AVFoundation
import Combine

/// Single shared player for history recordings: one clip at a time, independent of row lifetime.
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    @Published private(set) var entryID: UUID?
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func isActive(_ id: UUID) -> Bool { entryID == id }
    func isPlaying(_ id: UUID) -> Bool { entryID == id && isPlaying }

    /// Plays, pauses or resumes the given recording. Starting another clip stops the current one.
    func toggle(_ id: UUID, url: URL) throws {
        if entryID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                guard player.play() else { throw SpeechFailure("Playback could not start.") }
                isPlaying = true
            }
            return
        }
        stop()
        let next = try AVAudioPlayer(contentsOf: url)
        next.delegate = self
        guard next.prepareToPlay(), next.play() else { throw SpeechFailure("Playback could not start.") }
        player = next
        entryID = id
        isPlaying = true
    }

    /// Stops playback; when `id` is given, only if that recording is the active one.
    func stop(_ id: UUID? = nil) {
        guard id == nil || id == entryID else { return }
        player?.stop()
        player = nil
        entryID = nil
        isPlaying = false
    }

    private func finished(_ identifier: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == identifier else { return }
        stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in self.finished(identifier) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in self.finished(identifier) }
    }
}
