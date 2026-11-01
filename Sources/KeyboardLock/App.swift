import AppKit
import SwiftUI
import Combine
import OfflineGuard

@main
enum KeyboardLockApp {
    static func main() {
        // Apply the network deny policy before any application UI or event handling starts.
        guard keyboard_lock_enforce_offline() == 0 else {
            fputs("键盘锁：无法启用离线保护，应用已退出。\n", stderr)
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let service = KeyboardLockService()
    private var window: NSWindow?
    private var lockObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "键盘锁"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        window.contentView = NSHostingView(rootView: ContentView(service: service))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("KeyboardLockWindow")
        window.setContentSize(NSSize(width: 480, height: 480))
        self.window = window
        lockObservation = service.$isLocked.receive(on: RunLoop.main).sink { [weak window] locked in
            window?.level = locked ? .floating : .normal
            window?.standardWindowButton(.miniaturizeButton)?.isEnabled = !locked
            if locked { window?.makeKeyAndOrderFront(nil) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowWillClose(_ notification: Notification) { service.unlock() }

    func applicationWillTerminate(_ notification: Notification) { service.unlock() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于键盘锁", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏键盘锁", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出键盘锁", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "键盘锁",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ])
    }
}
