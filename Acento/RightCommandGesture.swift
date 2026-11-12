import Foundation

nonisolated struct RightCommandGesture {
    enum Action: Equatable { case none, startHandsFree, finish }
    private var down = false
    private var chord = false
    private var held = false
    private var lastTap: TimeInterval?
    private var startedHandsFree = false

    mutating func press() -> Bool {
        guard !down else { return false }
        down = true
        chord = false
        held = false
        startedHandsFree = false
        return true
    }

    mutating func beginHandsFree(at time: TimeInterval, doubleTap: Bool) -> Bool {
        guard down, !chord, doubleTap, let lastTap, time >= lastTap,
              time - lastTap <= 0.38 else { return false }
        self.lastTap = nil
        startedHandsFree = true
        return true
    }

    mutating func beginHold() -> Bool {
        guard down, !chord, !held else { return false }
        held = true
        lastTap = nil
        return true
    }

    mutating func useInCombination() -> Bool {
        guard down else { lastTap = nil; return false }
        chord = true
        lastTap = nil
        return held
    }

    mutating func release(at time: TimeInterval, handsFree: Bool, doubleTap: Bool) -> Action {
        guard down else { return .none }
        down = false
        defer { chord = false; held = false }
        guard !chord, !startedHandsFree else { return .none }
        if handsFree || held { lastTap = nil; return .finish }
        guard doubleTap else { lastTap = nil; return .none }
        if let lastTap, time - lastTap <= 0.38 {
            self.lastTap = nil
            return .startHandsFree
        }
        lastTap = time
        return .none
    }
}
