import AppKit
import CoreGraphics

enum ScreenPermission {
    static var hasAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func requestOrExplain() {
        if requestAccess() {
            return
        }

        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "Lens 只会在你主动截图或录屏时读取屏幕。请在系统设置中允许 Lens，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}
