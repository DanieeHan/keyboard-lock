/// Tracks permission requests without calling macOS or depending on UserDefaults.
/// A build can request the native prompt once; rechecks never reopen Settings.
struct PermissionPolicy {
    enum State: Equatable {
        case notRequested, pending, authorized
    }

    enum RequestAction: Equatable {
        case none, promptOnce, recheck
    }

    let buildMarker: String
    private(set) var permissionRequested: Bool
    private(set) var isAuthorized = false

    var state: State {
        isAuthorized ? .authorized : (permissionRequested ? .pending : .notRequested)
    }

    var attemptMarkerToPersist: String? {
        permissionRequested ? buildMarker : nil
    }

    var persistenceKey: String { Self.persistenceKey(for: buildMarker) }

    static func persistenceKey(for buildMarker: String) -> String {
        "KeyboardLock.permissionAttemptBuild." + buildMarker
    }

    init(buildMarker: String, persistedRequest: Bool, legacyAttemptMarker: String? = nil) {
        self.buildMarker = buildMarker
        permissionRequested = persistedRequest || legacyAttemptMarker == buildMarker
    }

    mutating func refresh(trusted: Bool) {
        isAuthorized = trusted
        // A known grant also counts as completed setup. Revoking it must not
        // turn the next ordinary button click into another permission prompt.
        if trusted { permissionRequested = true }
    }

    mutating func request(trusted: Bool) -> RequestAction {
        refresh(trusted: trusted)
        guard !isAuthorized else { return .none }
        guard !permissionRequested else { return .recheck }
        permissionRequested = true
        return .promptOnce
    }
}
