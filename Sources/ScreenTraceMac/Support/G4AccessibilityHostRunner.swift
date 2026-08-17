import AppKit
import ScreenTraceCore
import SwiftUI

struct G4AccessibilityHostConfiguration {
    let readyMarkerURL: URL

    init?(arguments: [String]) {
        guard arguments.contains("--g4-accessibility-host"),
              let index = arguments.firstIndex(of: "--ready-marker"),
              arguments.indices.contains(index + 1) else { return nil }
        readyMarkerURL = URL(fileURLWithPath: arguments[index + 1])
            .standardizedFileURL
    }
}

@MainActor
enum G4AccessibilityHostRunner {
    private static var windows: [NSWindow] = []
    private static var playback: VideoEditorPlaybackController?

    static func start(_ configuration: G4AccessibilityHostConfiguration) -> Bool {
        let screenshotModel = ScreenshotAnnotationEditorModel(
            sourceDimensions: TraceDimensions(width: 1_280, height: 720)
        )
        screenshotModel.activateDrawingTool(.blur)
        screenshotModel.setCanvasEnabled(true)
        let screenshotImage = NSImage(size: NSSize(width: 1_280, height: 720))
        screenshotImage.lockFocus()
        NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.28, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1_280, height: 720).fill()
        screenshotImage.unlockFocus()
        let screenshotRoot = ScreenshotAnnotationEditorView(
            model: screenshotModel,
            image: screenshotImage,
            onSave: { _ in },
            onCopy: { _ in },
            onExport: { _, _ in },
            onCancel: {}
        )
        let screenshotWindow = makeWindow(
            title: "G4 截图编辑器无障碍验收",
            size: NSSize(width: 1_080, height: 720),
            rootView: screenshotRoot
        )

        let videoModel = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 18,
            hasCameraTrack: true,
            hasMicrophoneTrack: true,
            transcript: nil
        )
        let playback = VideoEditorPlaybackController()
        self.playback = playback
        let videoRoot = VideoEditorView(
            model: videoModel,
            playback: playback,
            title: "G4 视频编辑器无障碍验收",
            onSave: {},
            onExport: {},
            onClose: {}
        )
        let videoWindow = makeWindow(
            title: "G4 视频编辑器无障碍验收",
            size: NSSize(width: 1_260, height: 780),
            rootView: videoRoot
        )

        windows = [screenshotWindow, videoWindow]
        screenshotWindow.setFrameOrigin(NSPoint(x: 40, y: 40))
        videoWindow.setFrameOrigin(NSPoint(x: 160, y: 100))
        windows.forEach { $0.orderFrontRegardless() }
        screenshotWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        do {
            try Data("ready".utf8).write(
                to: configuration.readyMarkerURL,
                options: .atomic
            )
            return true
        } catch {
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            playback.stop()
            self.playback = nil
            return false
        }
    }

    private static func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        rootView: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        return window
    }
}
