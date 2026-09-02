import AppKit
import LensCore
import SwiftUI

package struct G4AccessibilityHostConfiguration {
    let readyMarkerURL: URL

    package init?(arguments: [String]) {
        guard arguments.contains("--g4-accessibility-host"),
              let index = arguments.firstIndex(of: "--ready-marker"),
              arguments.indices.contains(index + 1) else { return nil }
        readyMarkerURL = URL(fileURLWithPath: arguments[index + 1])
            .standardizedFileURL
    }
}

@MainActor
package enum G4AccessibilityHostRunner {
    private static var windows: [NSWindow] = []
    private static var playback: VideoEditorPlaybackController?
    private static var recordingModel: RecordingControlModel?

    package static func start(_ configuration: G4AccessibilityHostConfiguration) -> Bool {
        let screenshotModel = ScreenshotAnnotationEditorModel(
            sourceDimensions: LensDimensions(width: 1_280, height: 720)
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

        let recordingModel = RecordingControlModel()
        recordingModel.reset(
            sourceTitle: "G4 窗口录制",
            capturesSystemAudio: true,
            capturesMicrophone: true,
            capturesCamera: true
        )
        self.recordingModel = recordingModel
        let recordingRoot = RecordingControlView(
            model: recordingModel,
            onHide: {},
            onPauseToggle: {},
            onDiscardAndRestart: {},
            onStop: {}
        )
        let recordingWindow = makeWindow(
            title: "G4 录制浮标无障碍验收",
            size: NSSize(width: 640, height: 160),
            rootView: recordingRoot
        )

        guard let libraryFixture = makeLibraryFixture(
            root: configuration.readyMarkerURL.deletingLastPathComponent()
        ) else {
            [screenshotWindow, videoWindow, recordingWindow].forEach { $0.orderOut(nil) }
            playback.stop()
            self.playback = nil
            self.recordingModel = nil
            return false
        }
        let libraryModel = LensLibraryModel(
            store: LensProjectStore(rootDirectory: libraryFixture.root),
            initialEntries: libraryFixture.entries
        )
        // Give the runtime AX audit a non-empty local query so it can verify
        // both the search field's accessible value and the filtered card.
        libraryModel.query = "视频"
        let libraryRoot = LensLibraryView(
            model: libraryModel,
            onOpen: { _ in },
            onReveal: { _ in },
            onCopy: { _ in },
            onAnnotate: { _ in },
            onShowOCR: { _ in },
            onTranscribe: { _ in },
            onOrganize: { _ in },
            onSaveInsights: { _, _ in },
            onDelete: { _ in },
            onRepair: { _ in },
            onDeleteAll: {},
            onOpenFolder: {},
            onClose: {},
            onStartCapture: {}
        )
        let libraryWindow = makeWindow(
            title: "G4 Lens 库无障碍验收",
            size: NSSize(width: 1_020, height: 690),
            rootView: libraryRoot
        )

        windows = [screenshotWindow, videoWindow, recordingWindow, libraryWindow]
        screenshotWindow.setFrameOrigin(NSPoint(x: 40, y: 40))
        videoWindow.setFrameOrigin(NSPoint(x: 160, y: 100))
        recordingWindow.setFrameOrigin(NSPoint(x: 220, y: 920))
        libraryWindow.setFrameOrigin(NSPoint(x: 80, y: 360))
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
            self.recordingModel = nil
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

    private static func makeLibraryFixture(
        root: URL
    ) -> (root: URL, entries: [LensLibraryEntry])? {
        let fixtureRoot = root.appendingPathComponent("g4-library-fixture", isDirectory: true)
        let screenshotPackage = fixtureRoot.appendingPathComponent(
            "g4-screenshot.lens",
            isDirectory: true
        )
        let screenshotURL = screenshotPackage.appendingPathComponent(
            "raw/screenshot.png"
        )
        let recordingPackage = fixtureRoot.appendingPathComponent(
            "g4-recording.lens",
            isDirectory: true
        )
        let recordingURL = recordingPackage.appendingPathComponent(
            "raw/screen.mp4"
        )
        do {
            try FileManager.default.createDirectory(
                at: screenshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: recordingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let image = NSImage(size: NSSize(width: 960, height: 540))
            image.lockFocus()
            NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.28, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 960, height: 540).fill()
            NSColor.systemTeal.setFill()
            NSRect(x: 120, y: 110, width: 420, height: 210).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            try png.write(to: screenshotURL, options: .atomic)
            try Data("g4 fixture; not opened or played".utf8).write(
                to: recordingURL,
                options: .atomic
            )

            let screenshotManifest = LensManifest(
                kind: .screenshot,
                title: "G4 设计评审截图",
                state: .ready,
                dimensions: LensDimensions(width: 960, height: 540),
                assets: [LensAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )
            let recordingManifest = LensManifest(
                kind: .recording,
                title: "G4 产品演示录屏",
                state: .ready,
                durationSeconds: 12,
                dimensions: LensDimensions(width: 1_280, height: 720),
                assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
            )
            return (
                fixtureRoot,
                [
                    LensLibraryEntry(
                        packageURL: screenshotPackage,
                        manifest: screenshotManifest,
                        primaryAssetURL: screenshotURL,
                        displayAssetURL: screenshotURL,
                        ocrText: "G4 本地拖拽交付",
                        insights: nil
                    ),
                    LensLibraryEntry(
                        packageURL: recordingPackage,
                        manifest: recordingManifest,
                        primaryAssetURL: recordingURL,
                        displayAssetURL: recordingURL,
                        ocrText: nil,
                        transcriptText: "G4 演示步骤",
                        insights: nil
                    )
                ]
            )
        } catch {
            return nil
        }
    }
}
