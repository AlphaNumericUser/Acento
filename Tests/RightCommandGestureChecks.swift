import Foundation

@main
struct RightCommandGestureChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        var gesture = RightCommandGesture()
        expect(gesture.press(), "First press accepted")
        expect(!gesture.press(), "Repeated key-down ignored")
        expect(!gesture.beginHandsFree(at: 1, doubleTap: true), "Single press does not lock")
        expect(gesture.release(at: 1.05, handsFree: false, doubleTap: true) == .none, "Quick single tap does not record")
        expect(gesture.press(), "Second press accepted")
        expect(gesture.beginHandsFree(at: 1.15, doubleTap: true), "Double tap locks on second press without waiting for release")
        expect(gesture.release(at: 1.2, handsFree: true, doubleTap: true) == .none, "Releasing the locking tap keeps recording")
        expect(gesture.press(), "Finishing tap accepted")
        expect(gesture.release(at: 1.3, handsFree: true, doubleTap: true) == .finish, "Next tap finishes hands-free dictation")

        gesture = RightCommandGesture()
        expect(gesture.press(), "Hold press accepted")
        expect(gesture.beginHold(), "Hold starts recording")
        expect(!gesture.beginHold(), "Hold cannot start twice")
        expect(gesture.release(at: 2, handsFree: false, doubleTap: true) == .finish, "Releasing hold finishes recording")

        gesture = RightCommandGesture()
        _ = gesture.press()
        _ = gesture.useInCombination()
        expect(!gesture.beginHold(), "Command shortcuts cannot start a hold")
        expect(gesture.release(at: 3, handsFree: false, doubleTap: true) == .none, "Command chord is not a tap")
        _ = gesture.press()
        expect(!gesture.beginHandsFree(at: 3.1, doubleTap: true), "Command chord cannot become first half of double tap")
        _ = gesture.beginHold()
        expect(gesture.useInCombination(), "Command chord during a hold requests cancellation")
        expect(gesture.release(at: 3.2, handsFree: false, doubleTap: true) == .none, "Cancelled hold cannot finish and submit")

        gesture = RightCommandGesture()
        _ = gesture.press()
        _ = gesture.release(at: 4, handsFree: false, doubleTap: true)
        _ = gesture.press()
        expect(!gesture.beginHandsFree(at: 4.5, doubleTap: true), "Late second press cannot lock")
        expect(gesture.beginHold(), "Late press can still start a hold")

        gesture = RightCommandGesture()
        _ = gesture.press()
        _ = gesture.release(at: 5, handsFree: false, doubleTap: true)
        _ = gesture.press()
        expect(!gesture.beginHandsFree(at: 5.1, doubleTap: false), "Disabled double tap cannot lock")
        expect(gesture.beginHold(), "Hold remains available without double tap")
        print("Passed \(checks) Right Command gesture checks.")
    }
}
