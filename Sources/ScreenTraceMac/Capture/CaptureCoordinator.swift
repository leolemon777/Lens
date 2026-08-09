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
    private var windowTargets: [CGWindowID: WindowCaptureTarget] = [:]
    private var isPreparingCapture = false
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
        guard canBeginCapture(), ensurePermission() else { return }
        showOverlays(mode: .region)
    }

    func beginWindowCapture() {
        guard canBeginCapture(), ensurePermission() else { return }
        isPreparingCapture = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPreparingCapture = false }
            do {
                let targets = try await captureService.availableWindowTargets(
                    excludingProcessID: ProcessInfo.processInfo.processIdentifier
                )
                windowTargets = Dictionary(
                    uniqueKeysWithValues: targets.map { ($0.candidate.id, $0) }
                )
                showOverlays(mode: .window(candidates: targets.map(\.candidate)))
            } catch {
                windowTargets.removeAll()
                showError(message: error.localizedDescription)
            }
        }
    }

    func beginDisplayCapture() {
        guard canBeginCapture(), ensurePermission() else { return }
        guard let screen = screenUnderPointer(), let displayID = screen.displayID else {
            showError(message: "没有找到可以捕获的显示器。")
            return
        }

        let displayBounds = CGDisplayBounds(displayID)
        finishCapture {
            try await self.captureService.capture(globalDisplayRect: displayBounds)
        }
    }

    private func showOverlays(mode: CaptureOverlayMode) {
        overlayWindows = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return CaptureOverlayWindow(
                screen: screen,
                displayID: displayID,
                displayBounds: CGDisplayBounds(displayID),
                mode: mode,
                delegate: self
            )
        }
        guard !overlayWindows.isEmpty else {
            windowTargets.removeAll()
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
        windowTargets.removeAll()
    }

    func captureOverlay(
        _ view: CaptureOverlayView,
        didSelect rect: CGRect,
        displayID: CGDirectDisplayID
    ) {
        let displayBounds = CGDisplayBounds(displayID)
        let globalRect = CaptureGeometry.globalRect(
            fromLocalRect: rect,
            displayBounds: displayBounds
        ).integral
        finishCapture {
            try await self.captureService.capture(globalDisplayRect: globalRect)
        }
    }

    func captureOverlay(_ view: CaptureOverlayView, didSelectWindow windowID: CGWindowID) {
        guard let target = windowTargets[windowID] else {
            dismissOverlays()
            windowTargets.removeAll()
            showError(message: "所选窗口已经关闭，请重新选择。")
            return
        }
        finishCapture {
            try await self.captureService.capture(window: target.window)
        }
    }

    private func finishCapture(
        operation: @escaping @MainActor () async throws -> CGImage
    ) {
        guard !isFinishingCapture else { return }
        isFinishingCapture = true
        dismissOverlays()
        windowTargets.removeAll()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isFinishingCapture = false }
            do {
                // Allow the action center or selection overlay to leave the compositor first.
                try await Task.sleep(for: .milliseconds(90))
                let cgImage = try await operation()
                try persistCapturedImage(cgImage)
            } catch {
                showError(message: error.localizedDescription)
            }
        }
    }

    private func persistCapturedImage(_ cgImage: CGImage) throws {
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
    }

    private func canBeginCapture() -> Bool {
        overlayWindows.isEmpty && !isPreparingCapture && !isFinishingCapture
    }

    private func ensurePermission() -> Bool {
        guard ScreenPermission.hasAccess else {
            ScreenPermission.requestOrExplain()
            return false
        }
        return true
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

    private func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
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
