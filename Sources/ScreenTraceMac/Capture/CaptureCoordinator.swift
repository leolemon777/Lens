import AppKit
import CoreGraphics
import ScreenTraceCore

@MainActor
final class CaptureCoordinator: CaptureOverlayViewDelegate {
    private let store: TraceProjectStore
    private let model: AppModel
    private let quickAccess: QuickAccessWindowController
    private let captureService = ScreenCaptureService()
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var isFinishingCapture = false

    init(
        store: TraceProjectStore,
        model: AppModel,
        quickAccess: QuickAccessWindowController
    ) {
        self.store = store
        self.model = model
        self.quickAccess = quickAccess
    }

    func beginRegionCapture() {
        guard overlayWindows.isEmpty, !isFinishingCapture else { return }
        guard ScreenPermission.hasAccess else {
            ScreenPermission.requestOrExplain()
            return
        }

        overlayWindows = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return CaptureOverlayWindow(screen: screen, displayID: displayID, delegate: self)
        }
        guard !overlayWindows.isEmpty else {
            showError(message: "没有找到可以捕获的显示器。")
            return
        }

        overlayWindows.forEach { $0.orderFrontRegardless() }
        if let pointerWindow = windowUnderPointer() ?? overlayWindows.first {
            pointerWindow.makeKey()
            pointerWindow.makeFirstResponder(pointerWindow.contentView)
        }
    }

    func captureOverlayDidCancel(_ view: CaptureOverlayView) {
        dismissOverlays()
    }

    func captureOverlay(
        _ view: CaptureOverlayView,
        didSelect rect: CGRect,
        displayID: CGDirectDisplayID
    ) {
        guard !isFinishingCapture else { return }
        isFinishingCapture = true
        dismissOverlays()

        let displayBounds = CGDisplayBounds(displayID)
        let globalRect = CGRect(
            x: displayBounds.minX + rect.minX,
            y: displayBounds.minY + rect.minY,
            width: rect.width,
            height: rect.height
        ).integral

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFinishingCapture = false }
            do {
                try await Task.sleep(for: .milliseconds(80))
                let cgImage = try await captureService.capture(globalDisplayRect: globalRect)
                let pngData = try ImageEncoding.pngData(from: cgImage)
                let saved = try store.saveScreenshot(
                    pngData: pngData,
                    width: cgImage.width,
                    height: cgImage.height
                )
                let image = ImageEncoding.nsImage(from: cgImage)
                copyToClipboard(image)
                model.setRecentTrace(saved, thumbnail: image)
                quickAccess.show(trace: saved, image: image)
            } catch {
                showError(message: error.localizedDescription)
            }
        }
    }

    private func dismissOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    private func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func windowUnderPointer() -> CaptureOverlayWindow? {
        let location = NSEvent.mouseLocation
        return overlayWindows.first { $0.frame.contains(location) }
    }

    private func showError(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏迹无法完成截图"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
