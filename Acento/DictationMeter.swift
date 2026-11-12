import Combine
import Foundation

// Only the waveform observes this object. Audio must not invalidate the history,
// settings, or the entire floating panel thirty times a second.
@MainActor
final class DictationMeter: ObservableObject {
    @Published private(set) var levels = Array(repeating: 0.0, count: 10)
    private var level = 0.0
    private var phase = 0.0

    /// `value` is a perceptual 0...1 loudness. Each bar follows it with its own
    /// center-weighted envelope, jitter and slow wave so the bar feels alive.
    func update(_ value: Double) {
        let input = max(0, min(1, value))
        level += (input - level) * (input > level ? 0.7 : 0.2)
        phase += 0.42
        let center = Double(levels.count - 1) / 2
        levels = levels.indices.map { index in
            let distance = abs(Double(index) - center) / center
            let envelope = 1 - 0.6 * distance * distance
            let wave = 0.5 + 0.5 * sin(phase + Double(index) * 1.15)
            let jitter = Double.random(in: 0.55...1)
            let target = min(1, level * envelope * (0.5 * jitter + 0.5 * wave) * 1.35)
            let current = levels[index]
            return current + (target - current) * (target > current ? 0.75 : 0.3)
        }
    }

    func reset() {
        level = 0
        phase = 0
        if levels.contains(where: { $0 != 0 }) {
            levels = Array(repeating: 0, count: 10)
        }
    }
}
