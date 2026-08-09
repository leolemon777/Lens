import AppKit
@preconcurrency import AVFoundation
import ScreenTraceCore
import SwiftUI

enum VideoEditorWindowError: LocalizedError {
    case sourceUnavailable
    case durationUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "录屏原始文件不存在，无法打开编辑器。"
        case .durationUnavailable: "录屏时长尚不可用，请先完成或恢复原始录制。"
        }
    }
}

@MainActor
final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    private let store: TraceProjectStore
    private let window: VideoEditorWindow
    private var model: VideoEditorModel?
    private var playback: VideoEditorPlaybackController?
    private var packageURL: URL?

    var onSaved: (@MainActor (SavedTrace) async -> Void)?
    var onFailure: ((Error) -> Void)?

    init(store: TraceProjectStore) {
        self.store = store
        window = VideoEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_260, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
    }

    var isVisible: Bool { window.isVisible }

    func show(entry: TraceLibraryEntry) {
        guard entry.manifest.kind == .recording else { return }
        if window.isVisible,
           packageURL?.standardizedFileURL == entry.packageURL.standardizedFileURL {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        if window.isVisible, !canDiscardUnsavedChanges() { return }
        let duration = entry.manifest.durationSeconds ?? 0
        guard duration >= VideoEditTimeline.minimumSegmentDurationSeconds else {
            onFailure?(VideoEditorWindowError.durationUnavailable)
            return
        }
        guard FileManager.default.fileExists(atPath: entry.primaryAssetURL.path) else {
            onFailure?(VideoEditorWindowError.sourceUnavailable)
            return
        }
        let plan = (try? store.loadAutoEditPlan(from: entry.packageURL))
            ?? AutoEditPlan(
                timeline: VideoEditTimeline(sourceDurationSeconds: duration)
            )
        let cameraURL = entry.manifest.assets
            .lazy
            .filter { $0.role == .camera }
            .map { entry.packageURL.appendingPathComponent($0.relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let hasCamera = cameraURL != nil
        let hasMicrophone = entry.manifest.assets.contains {
            $0.role == .microphone
                && FileManager.default.fileExists(
                    atPath: entry.packageURL.appendingPathComponent($0.relativePath).path
                )
        }
        let transcript = try? store.loadTranscript(from: entry.packageURL)
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: duration,
            hasCameraTrack: hasCamera,
            hasMicrophoneTrack: hasMicrophone,
            transcript: transcript
        )
        let playback = VideoEditorPlaybackController()
        model.onTimelineChanged = { [weak playback] timeline in
            playback?.reload(timeline: timeline)
        }
        self.playback?.stop()
        self.model = model
        self.playback = playback
        packageURL = entry.packageURL

        window.contentView = NSHostingView(rootView: VideoEditorView(
            model: model,
            playback: playback,
            title: entry.manifest.title,
            onSave: { [weak self] in self?.save() },
            onClose: { [weak self] in self?.requestClose() }
        ))
        playback.load(sourceURL: entry.primaryAssetURL, timeline: model.timeline)
        if let cameraURL {
            loadPresenterThumbnail(from: cameraURL, into: model)
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        playback?.stop()
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canDiscardUnsavedChanges() else { return false }
        playback?.stop()
        return true
    }

    private func configureWindow() {
        window.delegate = self
        window.title = "屏迹编辑器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1_060, height: 680)
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenPrimary]
        window.onEscape = { [weak self] in self?.requestClose() }
    }

    private func save() {
        guard let model, let packageURL, !model.isProcessing else { return }
        do {
            let saved = try store.writeAutoEditPlan(model.plan, to: packageURL)
            model.markSaved()
            model.beginProcessing()
            Task { @MainActor [weak self, weak model] in
                guard let self else { return }
                await onSaved?(saved)
                guard self.model === model else { return }
                model?.endProcessing()
            }
        } catch {
            onFailure?(error)
        }
    }

    private func requestClose() {
        guard canDiscardUnsavedChanges() else { return }
        hide()
    }

    private func loadPresenterThumbnail(from cameraURL: URL, into model: VideoEditorModel) {
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            let asset = AVURLAsset(url: cameraURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            do {
                let duration = try await asset.load(.duration).seconds
                let safeDuration = duration.isFinite ? max(duration, 0) : 0
                let requestedTime = min(safeDuration * 0.08, 0.35)
                let frame = try await generator.image(at: CMTime(
                    seconds: requestedTime,
                    preferredTimescale: 600
                )).image
                guard self.model === model else { return }
                model.setPresenterThumbnail(NSImage(
                    cgImage: frame,
                    size: NSSize(width: frame.width, height: frame.height)
                ))
            } catch {
                // The live editor remains usable with its native placeholder.
            }
        }
    }

    private func canDiscardUnsavedChanges() -> Bool {
        guard model?.isDirty == true else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃尚未保存的编辑？"
        alert.informativeText = "原始录屏不会受影响，但本次时间线和效果调整会丢失。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃更改")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private final class VideoEditorWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
