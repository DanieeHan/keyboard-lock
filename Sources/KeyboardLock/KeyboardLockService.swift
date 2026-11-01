import AppKit
import ApplicationServices
import Carbon
import Combine
import Security

/// Owns the event tap only while cleaning. All methods and callbacks run on the main thread.
final class KeyboardLockService: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var permissionRequested = false
    @Published private(set) var errorMessage: String?

    var formattedRemaining: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var deadline: TimeInterval?
    private var lastPermissionCheck: TimeInterval = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var permissionPolicy: PermissionPolicy
    private var permissionTimer: DispatchSourceTimer?
    private var permissionPollDeadline: TimeInterval?
    private var permissionStatusMessage: String?
    private static let permissionAttemptKey = "KeyboardLock.permissionAttemptBuild"
    private static let permissionRecoveryMessage = "权限未生效，请重新添加此应用后重启"
    private static let permissionPendingMessage = "请在系统设置中开启权限"

    // CGEventType does not expose the AppKit system-defined event by a named case.
    private static let systemDefined = CGEventType(rawValue: 14)!
    private static let keyboardTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, systemDefined]
    private static let requiredKeyboardMask = keyboardTypes.reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << $1.rawValue)
    }
    private static let keyboardModifiers: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn
    ]
    private static let pointerTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
        .rightMouseDragged, .otherMouseDragged, .scrollWheel
    ]

    init() {
        let buildMarker = Self.currentBuildMarker()
        permissionPolicy = PermissionPolicy(
            buildMarker: buildMarker,
            persistedRequest: UserDefaults.standard.bool(forKey: PermissionPolicy.persistenceKey(for: buildMarker)),
            legacyAttemptMarker: UserDefaults.standard.string(forKey: Self.permissionAttemptKey)
        )
        refreshPermission()
        observe(NSApplication.didBecomeActiveNotification, center: .default) { [weak self] in
            self?.refreshPermission()
        }
        observe(NSApplication.willTerminateNotification, center: .default) { [weak self] in
            self?.stopPermissionPolling()
            self?.unlock()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, center: workspace) { [weak self] in
            self?.stopPermissionPolling()
            self?.unlock()
        }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { [weak self] in
            self?.stopPermissionPolling()
            self?.unlock()
        }
    }

    deinit {
        // The AppDelegate retains this service until application termination.
        releaseResources()
        stopPermissionPolling()
        for (center, token) in observers { center.removeObserver(token) }
    }

    func refreshPermission() {
        precondition(Thread.isMainThread)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        permissionPolicy.refresh(trusted: trusted)
        publishPermissionState()
        if hasAccessibilityPermission != trusted { hasAccessibilityPermission = trusted }
        if trusted {
            stopPermissionPolling()
            if let message = permissionStatusMessage, errorMessage == message { errorMessage = nil }
            permissionStatusMessage = nil
        } else if permissionRequested && permissionTimer == nil && errorMessage == nil {
            setPermissionMessage(Self.permissionRecoveryMessage)
        }
        if isLocked && !trusted {
            stop(error: nil)
            setPermissionMessage("权限已关闭，已解锁")
        }
    }

    func requestPermission() {
        precondition(Thread.isMainThread)
        refreshPermission()
        let action = permissionPolicy.request(trusted: hasAccessibilityPermission)
        // Persist before the asynchronous prompt so relaunching cannot repeat it.
        publishPermissionState()
        switch action {
        case .none:
            return
        case .recheck:
            setPermissionMessage(permissionTimer == nil ? Self.permissionRecoveryMessage : Self.permissionPendingMessage)
        case .promptOnce:
            clearError()
            beginPermissionPolling()
            setPermissionMessage(Self.permissionPendingMessage)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            refreshPermission()
        }
    }

    /// Explicit settings navigation. Never raises another native AX request.
    func openPermissionSettings() {
        precondition(Thread.isMainThread)
        refreshPermission()
        if !hasAccessibilityPermission { beginPermissionPolling() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func clearError() {
        errorMessage = nil
        permissionStatusMessage = nil
    }

    func start(duration: TimeInterval) {
        precondition(Thread.isMainThread)
        guard !isLocked else { return }
        clearError()
        refreshPermission()
        guard hasAccessibilityPermission else {
            setPermissionMessage(permissionRequested ? Self.permissionRecoveryMessage : "请开启辅助功能权限")
            return
        }
        guard let safeDuration = LockPolicy.boundedDuration(duration) else {
            errorMessage = "请选择解锁时间"
            return
        }
        guard !IsSecureEventInputEnabled() else {
            errorMessage = "请先退出密码输入"
            return
        }
        // Do not swallow a release whose press was already delivered to another app.
        guard !Self.keysAreHeld() else {
            errorMessage = "请先松开所有按键"
            return
        }

        let types = Self.keyboardTypes + Self.pointerTypes
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            // Use the earliest public interception point. If macOS rejects it,
            // fail unlocked instead of silently weakening coverage with a later tap.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<KeyboardLockService>.fromOpaque(context).takeUnretainedValue()
                return service.filter(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            errorMessage = "无法拦截键盘，请检查权限后重启"
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            errorMessage = "启动失败，请重试"
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // tapCreate can silently remove unauthorized event bits while leaving
        // pointer bits enabled. A non-nil port alone is not proof of a keyboard lock.
        guard CGEvent.tapIsEnabled(tap: tap), Self.installedTapIncludesKeyboard() else {
            releaseResources()
            errorMessage = "无法锁定，请检查权限"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        deadline = now + safeDuration
        lastPermissionCheck = now
        remainingSeconds = LockPolicy.remainingSeconds(deadline: now + safeDuration, now: now)
        isLocked = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func unlock() {
        precondition(Thread.isMainThread)
        stop(error: nil)
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let kind: LockPolicy.EventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .modifiers
        case .tapDisabledByTimeout, .tapDisabledByUserInput: kind = .tapInterrupted
        case Self.systemDefined:
            // NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8 (volume, brightness, playback).
            kind = NSEvent(cgEvent: event)?.subtype.rawValue == 8 ? .mediaKey : .otherSystem
        default:
            kind = Self.pointerTypes.contains(type) ? .pointer : .other
        }
        switch LockPolicy.eventDecision(isLocked: isLocked, kind: kind) {
        case .unlock:
            stop(error: "系统中断，已解锁")
        case .suppress:
            return nil
        case .removeKeyboardModifiers:
            // Keep the pointer usable without Command/Shift/etc. from keys being cleaned.
            event.flags.subtract(Self.keyboardModifiers)
        case .pass:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func tick() {
        guard isLocked, let deadline else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now < deadline else {
            unlock()
            return
        }
        let remaining = LockPolicy.remainingSeconds(deadline: deadline, now: now)
        if remainingSeconds != remaining { remainingSeconds = remaining }
        // Permission and tap queries happen once per second, never in key callbacks.
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            refreshPermission()
            guard isLocked else { return }
            guard let tap = eventTap, CGEvent.tapIsEnabled(tap: tap) else {
                stop(error: "锁定失效，已解锁")
                return
            }
            if IsSecureEventInputEnabled() {
                stop(error: "安全输入已开启，已解锁")
            }
        }
    }

    private func stop(error: String?) {
        isLocked = false
        releaseResources()
        remainingSeconds = 0
        deadline = nil
        if let error { errorMessage = error }
    }

    private func releaseResources() {
        timer?.cancel()
        timer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }

    private static func keysAreHeld() -> Bool {
        if !CGEventSource.flagsState(.hidSystemState).intersection(keyboardModifiers).isEmpty { return true }
        // A one-time physical-state check, not a monitor; nothing is retained or logged.
        return (0..<128).contains { code in
            code != 57 && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
        }
    }

    private static func installedTapIncludesKeyboard() -> Bool {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0, count < 4096 else { return false }
        // Extra slots tolerate another app installing a tap between the two queries.
        var entries = Array(repeating: CGEventTapInformation(), count: Int(count) + 8)
        let capacity = UInt32(entries.count)
        guard CGGetEventTapList(capacity, &entries, &count) == .success else { return false }
        return entries.prefix(Int(min(count, capacity))).contains {
            $0.tappingProcess == ProcessInfo.processInfo.processIdentifier &&
            $0.tapPoint == .cghidEventTap &&
            $0.options == .defaultTap &&
            $0.enabled &&
            ($0.eventsOfInterest & requiredKeyboardMask) == requiredKeyboardMask
        }
    }

    private func publishPermissionState() {
        if permissionRequested != permissionPolicy.permissionRequested {
            permissionRequested = permissionPolicy.permissionRequested
        }
        if permissionPolicy.permissionRequested,
           !UserDefaults.standard.bool(forKey: permissionPolicy.persistenceKey) {
            // Keep each build's marker so launching another app copy cannot erase it.
            // This also migrates a matching legacy single-build marker on first read.
            UserDefaults.standard.set(true, forKey: permissionPolicy.persistenceKey)
        }
    }

    private func setPermissionMessage(_ message: String) {
        permissionStatusMessage = message
        errorMessage = message
    }

    private func beginPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionPollDeadline = ProcessInfo.processInfo.systemUptime + 15
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.refreshPermission()
            guard let deadline = self.permissionPollDeadline else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                self.stopPermissionPolling()
                if !self.hasAccessibilityPermission {
                    self.setPermissionMessage(Self.permissionRecoveryMessage)
                }
            }
        }
        permissionTimer = timer
        timer.resume()
    }

    private func stopPermissionPolling() {
        permissionTimer?.cancel()
        permissionTimer = nil
        permissionPollDeadline = nil
    }

    private static func currentBuildMarker() -> String {
        // Read this executable's public signing metadata; no trust changes or network access.
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        if SecCodeCopySelf([], &ownCode) == errSecSuccess,
           let ownCode,
           SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess,
           let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let dictionary = information as? [String: Any],
           let hash = dictionary[kSecCodeInfoUnique as String] as? Data,
           !hash.isEmpty {
            return "cdhash:" + hash.map { String(format: "%02x", $0) }.joined()
        }
        // A local unsigned development executable still gets a stable per-build marker.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        if let url = Bundle.main.executableURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? NSNumber {
            return "file:\(version):\(modified.timeIntervalSince1970):\(size.int64Value)"
        }
        return "version:\(version)"
    }
}
