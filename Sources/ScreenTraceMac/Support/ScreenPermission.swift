import AppKit
import CoreGraphics

enum ScreenPermission {
    static var hasAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func requestOrExplain() {
        if CGRequestScreenCaptureAccess() {
            return
        }

        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "屏迹只会在你主动截图或录屏时读取屏幕。请在系统设置中允许屏迹，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
