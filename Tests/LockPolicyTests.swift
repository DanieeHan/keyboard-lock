import Foundation

@main
struct LockPolicyTests {
    static func main() {
        expect(LockPolicy.boundedDuration(180) == 180, "normal cleaning duration")
        expect(LockPolicy.boundedDuration(60) == 60, "one-minute duration")
        expect(LockPolicy.boundedDuration(300) == 300, "five-minute duration")
        expect(LockPolicy.boundedDuration(60_000) == 600, "safety cap prevents excessive lock")
        expect(LockPolicy.boundedDuration(0.1) == 1, "positive fractions receive a usable minimum")
        expect(LockPolicy.boundedDuration(0) == nil, "zero is rejected")
        expect(LockPolicy.boundedDuration(-1) == nil, "negative duration is rejected")
        expect(LockPolicy.boundedDuration(.infinity) == nil, "unbounded lock is rejected")
        expect(LockPolicy.boundedDuration(.nan) == nil, "invalid duration is rejected")
        expect(LockPolicy.remainingSeconds(deadline: 103, now: 100) == 3, "exact countdown")
        expect(LockPolicy.remainingSeconds(deadline: 103, now: 102.9) == 1, "never display zero while still locked")
        expect(LockPolicy.remainingSeconds(deadline: 103, now: 103) == 0, "deadline expires exactly")
        expect(LockPolicy.remainingSeconds(deadline: 103, now: 104) == 0, "delayed timer still expires")
        expect(LockPolicy.remainingSeconds(deadline: .nan, now: 100) == 0, "malformed deadline fails open")
        expect(LockPolicy.remainingSeconds(deadline: 103, now: .infinity) == 0, "invalid clock fails open")
        expect(LockPolicy.remainingSeconds(deadline: 1e300, now: 1) == 600, "conversion cannot overflow")
        let allEvents: [LockPolicy.EventKind] = [
            .keyDown, .keyUp, .modifiers, .mediaKey, .otherSystem, .pointer, .other, .tapInterrupted
        ]
        for event in allEvents {
            expect(LockPolicy.eventDecision(isLocked: false, kind: event) == .pass, "unlocked input passes unchanged")
        }
        for event: LockPolicy.EventKind in [.keyDown, .keyUp, .modifiers, .mediaKey] {
            expect(LockPolicy.eventDecision(isLocked: true, kind: event) == .suppress, "keyboard input is suppressed")
        }
        expect(LockPolicy.eventDecision(isLocked: true, kind: .pointer) == .removeKeyboardModifiers, "mouse stays usable without accidental Command/Shift clicks")
        expect(LockPolicy.eventDecision(isLocked: true, kind: .otherSystem) == .pass, "non-keyboard system events pass")
        expect(LockPolicy.eventDecision(isLocked: true, kind: .other) == .pass, "unrelated events pass")
        expect(LockPolicy.eventDecision(isLocked: true, kind: .tapInterrupted) == .unlock, "interrupted filtering fails open")
        print("PASS: 32 lock-policy timing and input safety checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
