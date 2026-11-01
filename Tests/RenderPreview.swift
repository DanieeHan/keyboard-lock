import AppKit
import SwiftUI

@main
struct RenderPreview {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/keyboard-lock-preview"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let variants: [(String, Bool, Bool, Bool, String?)] = [
            ("ready", false, true, false, nil),
            ("locked", true, true, false, nil),
            ("permission", false, false, false, nil),
            ("permission-pending", false, false, true, "权限未生效，请重新添加此应用后重启"),
            ("error", false, true, false, "系统中断，已解锁")
        ]
        for (name, locked, permission, requested, error) in variants {
            let screen = LockScreen(isLocked: locked, hasPermission: permission, permissionRequested: requested, remainingSeconds: 172,
                                    duration: .constant(180), error: error, showsInfo: .constant(false), primaryAction: {}, permissionSettingsAction: {})
            let renderer = ImageRenderer(content: screen)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Cannot render \(name)")
            }
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            print("Rendered \(name)")
        }
    }
}
