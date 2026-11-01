import Foundation

@main
struct PermissionPolicyTests {
    private static var checkCount = 0
    private static let legacyKey = "KeyboardLock.permissionAttemptBuild"

    static func main() {
        if CommandLine.arguments.count == 4 {
            persistenceChild(mode: CommandLine.arguments[1], suite: CommandLine.arguments[2], marker: CommandLine.arguments[3])
            return
        }
        var first = PermissionPolicy(buildMarker: "build-a", persistedRequest: false)
        expect(first.state == .notRequested, "first launch does not request permission")
        expect(first.attemptMarkerToPersist == nil, "a silent check is not recorded as an attempt")
        first.refresh(trusted: false)
        expect(first.state == .notRequested, "denied silent checks do not prompt")
        expect(first.request(trusted: false) == .promptOnce, "first explicit click prompts once")
        expect(first.state == .pending, "a request is not mistaken for a grant")
        expect(first.attemptMarkerToPersist == "build-a", "attempt survives process relaunch")
        for _ in 0..<10 {
            expect(first.request(trusted: false) == .recheck, "repeated clicks never request another prompt")
        }

        var storedDefaults: [String: Bool] = [:]
        storedDefaults[first.persistenceKey] = true
        var relaunched = PermissionPolicy(buildMarker: "build-a", persistedRequest: storedDefaults[first.persistenceKey] == true)
        expect(relaunched.state == .pending, "same build restores pending setup")
        expect(relaunched.request(trusted: false) == .recheck, "relaunch does not reset prompt budget")
        relaunched.refresh(trusted: true)
        expect(relaunched.state == .authorized, "fresh grant exits pending state")
        expect(relaunched.request(trusted: true) == .none, "authorized click performs no setup action")

        var staleUI = PermissionPolicy(buildMarker: "build-a", persistedRequest: false)
        expect(staleUI.request(trusted: true) == .none, "fresh permission check overrides stale unauthorized UI")
        expect(staleUI.state == .authorized, "already-authorized first launch is recognized")
        expect(staleUI.attemptMarkerToPersist == "build-a", "existing grant persists completed setup")
        staleUI.refresh(trusted: false)
        expect(staleUI.state == .pending, "revocation never leaves authorized UI")
        expect(staleUI.request(trusted: false) == .recheck, "revoked permission does not trigger prompt loop")

        var nextBuild = PermissionPolicy(buildMarker: "build-b", persistedRequest: false, legacyAttemptMarker: "build-a")
        expect(nextBuild.state == .notRequested, "new code identity allows explicit new setup")
        expect(nextBuild.request(trusted: false) == .promptOnce, "new build gets only one explicit request")
        expect(nextBuild.request(trusted: false) == .recheck, "new build still cannot repeat prompts")
        expect(nextBuild.attemptMarkerToPersist == "build-b", "new attempt records the current build")
        storedDefaults[nextBuild.persistenceKey] = true
        var firstAgain = PermissionPolicy(buildMarker: "build-a", persistedRequest: storedDefaults[first.persistenceKey] == true)
        expect(firstAgain.request(trusted: false) == .recheck, "A to B to A keeps the first build's request marker")

        var authorizedRelaunch = PermissionPolicy(buildMarker: "build-a", persistedRequest: true)
        authorizedRelaunch.refresh(trusted: true)
        authorizedRelaunch.refresh(trusted: false)
        expect(authorizedRelaunch.request(trusted: false) == .recheck, "revocation across relaunch preserves one-shot prompting")
        var legacy = PermissionPolicy(buildMarker: "legacy-a", persistedRequest: false, legacyAttemptMarker: "legacy-a")
        expect(legacy.request(trusted: false) == .recheck, "a matching legacy marker migrates without prompting")
        expect(legacy.persistenceKey != first.persistenceKey, "different builds have independent persistence keys")

        // Separate OS processes exercise real UserDefaults persistence without any AX calls.
        let suite = "local.keyboardlock.permissiontests." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        child("write", suite: suite, marker: "process-a")
        child("read", suite: suite, marker: "process-a")
        child("write-authorized", suite: suite, marker: "process-b")
        child("read", suite: suite, marker: "process-a")
        child("read", suite: suite, marker: "process-b")
        child("write-legacy", suite: suite, marker: "process-legacy")
        child("migrate-legacy", suite: suite, marker: "process-legacy")
        child("write-legacy", suite: suite, marker: "different-legacy")
        child("read", suite: suite, marker: "process-legacy")
        print("PASS: \(checkCount) permission-flow checks, including 9 isolated persistence processes")
    }

    private static func child(_ mode: String, suite: String, marker: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [mode, suite, marker]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fatalError("Unable to run isolated persistence regression: \(error)")
        }
        expect(process.terminationStatus == 0, "persistence subprocess \(mode) / \(marker)")
    }

    private static func persistenceChild(mode: String, suite: String, marker: String) {
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Missing isolated defaults suite") }
        if mode == "write-legacy" {
            defaults.set(marker, forKey: legacyKey)
            return
        }
        var policy = PermissionPolicy(
            buildMarker: marker,
            persistedRequest: defaults.bool(forKey: PermissionPolicy.persistenceKey(for: marker)),
            legacyAttemptMarker: defaults.string(forKey: legacyKey)
        )
        switch mode {
        case "write":
            expect(policy.request(trusted: false) == .promptOnce, "fresh writer gets one request")
            defaults.set(true, forKey: policy.persistenceKey)
        case "write-authorized":
            policy.refresh(trusted: true)
            defaults.set(policy.permissionRequested, forKey: policy.persistenceKey)
        case "read", "migrate-legacy":
            expect(policy.state == .pending, "new process reads persisted attempt")
            expect(policy.request(trusted: false) == .recheck, "new process cannot repeat permission prompt")
            if mode == "migrate-legacy" { defaults.set(true, forKey: policy.persistenceKey) }
        default:
            fatalError("Unknown persistence test mode")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        checkCount += 1
    }
}
