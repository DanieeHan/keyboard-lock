import Foundation

/// Pure time policy; every lock has a finite, monotonic safety deadline.
enum LockPolicy {
    enum EventKind {
        case keyDown, keyUp, modifiers, mediaKey, otherSystem, pointer, other, tapInterrupted
    }

    enum EventDecision {
        case pass, suppress, removeKeyboardModifiers, unlock
    }

    static let maximumDuration: TimeInterval = 600

    static func eventDecision(isLocked: Bool, kind: EventKind) -> EventDecision {
        guard isLocked else { return .pass }
        switch kind {
        case .keyDown, .keyUp, .modifiers, .mediaKey: return .suppress
        case .pointer: return .removeKeyboardModifiers
        case .tapInterrupted: return .unlock
        case .otherSystem, .other: return .pass
        }
    }

    static func boundedDuration(_ requested: TimeInterval) -> TimeInterval? {
        guard requested.isFinite, requested > 0 else { return nil }
        return min(max(requested, 1), maximumDuration)
    }

    static func remainingSeconds(deadline: TimeInterval, now: TimeInterval) -> Int {
        guard deadline.isFinite, now.isFinite else { return 0 }
        let remaining = deadline - now
        guard remaining > 0 else { return 0 }
        return Int(ceil(min(remaining, maximumDuration)))
    }
}
