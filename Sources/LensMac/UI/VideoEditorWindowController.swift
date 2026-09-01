import AppKit
@preconcurrency import AVFoundation
import LensCore
import SwiftUI
import UniformTypeIdentifiers

enum VideoEditorWindowError: LocalizedError {
    case sourceUnavailable
    case durationUnavailable
    case previewVerificationFailed(String)
    case stepDocumentUnavailable
    case stepDocumentExportFailed(String)
    case narrationDraftFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "录屏原始文件不存在，无法打开编辑器。"
        case .durationUnavailable: "录屏时长尚不可用，请先完成或恢复原始录制。"
        case let .previewVerificationFailed(detail):
            "最终成片尚未通过媒体验证：\(detail)"
        case .stepDocumentUnavailable:
            "缺少可用的点击事件或原始画面，无法生成步骤文档。"
        case let .stepDocumentExportFailed(detail):
            "步骤文档导出失败：\(detail)"
        case let .narrationDraftFailed(detail):
            "配音草稿生成失败：\(detail)"
        }
    }
}

enum RenderedPreviewExportGate {
    static func failureDescription(
        for report: RecordingHealthReport?,
        expectedPlanDigest: String?
    ) -> String? {
        guard let expectedPlanDigest, !expectedPlanDigest.isEmpty else {
            return "无法生成当前编辑方案摘要"
        }
        guard let verification = report?.renderedEffectVerification else {
            return "缺少编码结果验证，请先重新生成预览"
        }
        guard let renderedPlanDigest = report?.renderedPlanDigest else {
            return "预览尚未绑定当前编辑方案，请重新生成"
        }
        guard renderedPlanDigest == expectedPlanDigest else {
            return "预览对应旧编辑方案，请重新生成"
        }
        guard verification.previewPlayable else {
            return "预览视频不可解码"
        }
        var failures = verification.effects.compactMap { check in
            check.state == .failed || check.state == .inconclusive
                ? check.effect.title
                : nil
        }
        if !verification.isFrameRateVerified {
            failures.append("帧率")
        }
        guard failures.isEmpty else {
            return "\(failures.joined(separator: "、"))未通过开启/关闭对照"
        }
        return nil
    }
}

@MainActor
final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    private let store: LensProjectStore
    private let window: VideoEditorWindow
    private var model: VideoEditorModel?
    private var playback: VideoEditorPlaybackController?
    private var packageURL: URL?
    private var exportTitle = "Lens 视频"
    private var previewRefreshRevision: UInt64 = 0
    private var previewRefreshTask: Task<Void, Never>?
    private var cameraRegenerationRevision: UInt64 = 0
    private var cameraRegenerationTask: Task<Void, Never>?
    private let presenterThumbnailCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 12
        return cache
    }()

    var onSaved: (@MainActor (SavedLens) async -> Void)?
    var onFailure: ((Error) -> Void)?

    init(store: LensProjectStore) {
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

    func show(entry: LensLibraryEntry) {
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
        let requiresPlanMigration = plan.schemaVersion
            != AutoEditPlan.currentSchemaVersion
        let cameraURL = entry.manifest.assets
            .lazy
            .filter { $0.role == .camera }
            .map { entry.packageURL.appendingPathComponent($0.relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let hasCamera = cameraURL != nil
        let microphoneURL = entry.manifest.assets
            .lazy
            .filter { $0.role == .microphone }
            .map { entry.packageURL.appendingPathComponent($0.relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let hasMicrophone = microphoneURL != nil
        let keyboardEventsURL = entry.manifest.assets
            .lazy
            .filter { $0.role == .keyboardEvents }
            .map { entry.packageURL.appendingPathComponent($0.relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let transcript = try? store.loadTranscript(from: entry.packageURL)
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: duration,
            hasCameraTrack: hasCamera,
            hasMicrophoneTrack: hasMicrophone,
            transcript: transcript,
            microphoneURL: microphoneURL,
            keyboardEventsURL: keyboardEventsURL
        )
        let playback = VideoEditorPlaybackController()
        model.onTimelineChanged = { [weak playback] timeline in
            playback?.reload(timeline: timeline)
        }
        self.playback?.stop()
        previewRefreshTask?.cancel()
        previewRefreshTask = nil
        cameraRegenerationTask?.cancel()
        cameraRegenerationTask = nil
        previewRefreshRevision &+= 1
        cameraRegenerationRevision &+= 1
        self.model = model
        self.playback = playback
        packageURL = entry.packageURL
        exportTitle = entry.manifest.title

        window.contentView = NSHostingView(rootView: VideoEditorView(
            model: model,
            playback: playback,
            title: entry.manifest.title,
            onRegenerateCamera: { [weak self] in self?.regenerateAutomaticCamera() },
            onRefreshPreview: { [weak self] in self?.requestPreviewRefresh() },
            onSave: { [weak self] in self?.save() },
            onExport: { [weak self] in self?.exportMP4() },
            onExportStepDocument: { [weak self] in self?.exportStepDocument() },
            onExportNarrationDraft: { [weak self] in self?.exportNarrationDraft() },
            onClose: { [weak self] in self?.requestClose() }
        ))
        let renderedPreviewURL = requiresPlanMigration ? nil : entry.manifest.assets
            .first(where: { $0.role == .renderedVideo })
            .map { entry.packageURL.appendingPathComponent($0.relativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        playback.load(
            sourceURL: entry.primaryAssetURL,
            timeline: model.timeline,
            renderedPreviewURL: renderedPreviewURL
        )
        if requiresPlanMigration {
            requestPreviewRefresh()
        }
        if let cameraURL {
            let cacheKey = cameraURL.standardizedFileURL as NSURL
            if let cached = presenterThumbnailCache.object(forKey: cacheKey) {
                model.setPresenterThumbnail(cached)
            } else {
                loadPresenterThumbnail(from: cameraURL, into: model)
            }
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Makes a newly generated smart preview available without rebuilding the
    /// editor window. Background completion only makes the generated result
    /// selectable; it never changes the active source behind the viewer's back.
    @discardableResult
    func adoptBackgroundPreview(
        entry: LensLibraryEntry,
        renderedPlan: AutoEditPlan
    ) -> Bool {
        guard packageURL?.standardizedFileURL == entry.packageURL.standardizedFileURL,
              let model,
              let playback,
              model.canAdoptBackgroundPreview(renderedPlan: renderedPlan),
              entry.manifest.state == .ready,
              let previewURL = entry.manifest.assets
                .first(where: { $0.role == .renderedVideo })
                .map({ entry.packageURL.appendingPathComponent($0.relativePath) }),
              FileManager.default.fileExists(atPath: previewURL.path) else {
            return false
        }
        playback.updateRenderedPreview(
            url: previewURL,
            timeline: renderedPlan.timeline
                ?? VideoEditTimeline(sourceDurationSeconds: model.sourceDurationSeconds),
            switchesImmediately: false
        )
        return true
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
        window.title = "Lens 编辑器"
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
        let requestedPlan = model.plan
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            _ = await persistAndProcess(
                model: model,
                packageURL: packageURL,
                requestedPlan: requestedPlan
            )
        }
    }

    private func regenerateAutomaticCamera() {
        guard let model,
              let packageURL else { return }
        cameraRegenerationRevision &+= 1
        let requestedRevision = cameraRegenerationRevision
        cameraRegenerationTask?.cancel()
        model.endRegeneratingCamera()
        let store = store
        cameraRegenerationTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            defer {
                if self.model === model,
                   self.cameraRegenerationRevision == requestedRevision {
                    model.endRegeneratingCamera()
                    self.cameraRegenerationTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            while model.isProcessing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled,
                  self.model === model,
                  requestedRevision == self.cameraRegenerationRevision else { return }

            model.beginRegeneratingCamera()
            let camera = model.plan.camera
            let duration = model.sourceDurationSeconds
            do {
                let analysisTask = Task.detached(priority: .userInitiated) {
                    try store.regeneratedAutomaticCameraKeyframes(
                        from: packageURL,
                        durationSeconds: duration,
                        camera: camera
                    )
                }
                let keyframes = try await withTaskCancellationHandler {
                    try await analysisTask.value
                } onCancel: {
                    analysisTask.cancel()
                }
                guard !Task.isCancelled,
                      self.model === model,
                      requestedRevision == self.cameraRegenerationRevision else { return }

                model.replaceAutomaticCameraKeyframes(with: keyframes)
                // Event analysis is complete at this point. Rendering can take
                // longer and is deliberately shown as a separate phase.
                model.endRegeneratingCamera()
                let requestedPlan = model.plan
                _ = await persistAndProcess(
                    model: model,
                    packageURL: packageURL,
                    requestedPlan: requestedPlan
                )
            } catch is CancellationError {
                return
            } catch {
                guard requestedRevision == self.cameraRegenerationRevision else { return }
                onFailure?(error)
            }
        }
    }

    /// Renderer-backed controls are committed automatically after a short quiet
    /// period. A newer edit supersedes a pending one, while an in-flight render
    /// is allowed to finish before the latest plan is rendered.
    private func requestPreviewRefresh() {
        guard let model, let packageURL else { return }
        previewRefreshRevision &+= 1
        let requestedRevision = previewRefreshRevision
        previewRefreshTask?.cancel()
        previewRefreshTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            defer {
                if self.model === model,
                   self.previewRefreshRevision == requestedRevision {
                    self.previewRefreshTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(360))
            } catch {
                return
            }
            while (model.isProcessing || model.isRegeneratingCamera),
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled,
                  self.model === model,
                  requestedRevision == self.previewRefreshRevision else { return }
            let requestedPlan = model.plan
            _ = await persistAndProcess(
                model: model,
                packageURL: packageURL,
                requestedPlan: requestedPlan
            )
        }
    }

    private func persistAndProcess(
        model: VideoEditorModel,
        packageURL: URL,
        requestedPlan: AutoEditPlan
    ) async -> URL? {
        guard !model.isProcessing else { return nil }
        do {
            let saved = try store.writeAutoEditPlan(requestedPlan, to: packageURL)
            // The edit plan is durable before the renderer starts. The UI can
            // now let the user close the editor without suggesting that their
            // change will be lost while the preview is still encoding.
            model.markPlanPersisted(requestedPlan)
            model.beginProcessing()
            await onSaved?(saved)
            guard self.model === model else { return nil }
            let refreshedManifest = try store.loadManifest(from: packageURL)
            guard refreshedManifest.state == .ready else {
                throw VideoEditorWindowError.sourceUnavailable
            }
            let previewURL = packageURL.appendingPathComponent("previews/auto.mp4")
            guard FileManager.default.fileExists(atPath: previewURL.path) else {
                throw VideoEditorWindowError.sourceUnavailable
            }
            model.markSaved(requestedPlan)
            model.endProcessing()
            // Do not flash an older completed preview over newer inspector
            // edits. The coalescing loop will render the latest revision next.
            if model.plan == requestedPlan {
                playback?.updateRenderedPreview(
                    url: previewURL,
                    timeline: requestedPlan.timeline
                        ?? VideoEditTimeline(
                            sourceDurationSeconds: model.sourceDurationSeconds
                        ),
                    switchesImmediately: false
                )
            }
            return previewURL
        } catch {
            model.endProcessing()
            onFailure?(error)
            return nil
        }
    }

    private func exportMP4() {
        guard let model, let packageURL, !model.isProcessing else { return }
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            let previewURL = packageURL.appendingPathComponent("previews/auto.mp4")
            let previousHealthReport = try? store.loadRecordingHealthReport(
                from: packageURL
            )
            let currentTranscript = model.plan.captions?.isEnabled == true
                ? try? store.loadTranscript(from: packageURL)
                : nil
            let expectedPlanDigest = try? RenderedPlanIdentity.digest(
                for: model.plan,
                transcript: currentTranscript
            )
            let mustRegenerate = model.isDirty
                || !FileManager.default.fileExists(atPath: previewURL.path)
                || previousHealthReport?.renderedEffectVerification == nil
                || previousHealthReport?.renderedPlanDigest != expectedPlanDigest
            let readyURL: URL?
            if mustRegenerate {
                readyURL = await persistAndProcess(
                    model: model,
                    packageURL: packageURL,
                    requestedPlan: model.plan
                )
            } else {
                readyURL = previewURL
            }
            guard let readyURL else { return }
            let verifiedHealthReport = try? store.loadRecordingHealthReport(
                from: packageURL
            )
            if let failure = RenderedPreviewExportGate.failureDescription(
                for: verifiedHealthReport,
                expectedPlanDigest: expectedPlanDigest
            ) {
                onFailure?(VideoEditorWindowError.previewVerificationFailed(failure))
                return
            }
            presentExportPanel(sourceURL: readyURL)
        }
    }

    private func exportStepDocument() {
        guard let packageURL, let model, !model.isProcessing else { return }
        let eventsDirectory = packageURL.appendingPathComponent("events", isDirectory: true)
        let clickURL = eventsDirectory.appendingPathComponent("clicks.jsonl")
        let windowURL = eventsDirectory.appendingPathComponent("windows.jsonl")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let package = packageURL
            let duration = model.sourceDurationSeconds
            let document = await Task.detached(priority: .utility) { () -> StepDocument? in
                let clicks = (try? LensEventReader.read(
                    ClickEvent.self,
                    from: clickURL
                )) ?? []
                let windows = (try? LensEventReader.read(
                    WindowEvent.self,
                    from: windowURL
                )) ?? []
                let document = StepDocumentPlanner().document(
                    clicks: clicks,
                    windows: windows,
                    durationSeconds: duration
                )
                return document.steps.isEmpty ? nil : document
            }.value
            guard let document else {
                onFailure?(VideoEditorWindowError.stepDocumentUnavailable)
                return
            }
            guard let rawVideoURL = (try? store.loadManifest(from: package))?
                .assets
                .first(where: { $0.role == .screenVideo })
                .map({ package.appendingPathComponent($0.relativePath) }),
                FileManager.default.fileExists(atPath: rawVideoURL.path) else {
                onFailure?(VideoEditorWindowError.stepDocumentUnavailable)
                return
            }
            presentStepDocumentPanel(document: document, rawVideoURL: rawVideoURL)
        }
    }

    private func presentStepDocumentPanel(document: StepDocument, rawVideoURL: URL) {
        let panel = NSSavePanel()
        panel.title = "导出步骤文档"
        panel.prompt = "导出 Markdown"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "操作步骤.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let exporter = StepDocumentExporter(document: document, videoURL: rawVideoURL)
            Task { @MainActor [weak self] in
                do {
                    try await exporter.write(to: url)
                    NSApp.activate(ignoringOtherApps: true)
                    NSWorkspace.shared.selectFile(
                        url.path,
                        inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                    )
                } catch {
                    self?.onFailure?(
                        VideoEditorWindowError.stepDocumentExportFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func exportNarrationDraft() {
        guard let packageURL, let model, !model.isProcessing else { return }
        let package = packageURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let transcript = try? store.loadTranscript(from: package) else {
                    onFailure?(VideoEditorWindowError.narrationDraftFailed("没有可用的转写文本。"))
                    return
                }
                let script = NarrationSpeechSynthesizer.script(from: transcript)
                let tempURL = try await Task.detached(priority: .utility) {
                    try await NarrationSpeechSynthesizer().synthesize(
                        text: script,
                        language: transcript.localeIdentifier
                    )
                }.value
                let destination = package.appendingPathComponent("previews/narration-draft.caf")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: tempURL, to: destination)
                try? FileManager.default.removeItem(at: tempURL)
                NSApp.activate(ignoringOtherApps: true)
                NSWorkspace.shared.selectFile(
                    destination.path,
                    inFileViewerRootedAtPath: destination.deletingLastPathComponent().path
                )
            } catch {
                onFailure?(VideoEditorWindowError.narrationDraftFailed(
                    error.localizedDescription
                ))
            }
        }
    }

    private func presentExportPanel(sourceURL: URL) {
        let panel = NSSavePanel()
        panel.title = "导出 Lens 视频"
        panel.prompt = "导出 MP4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let safeTitle = exportTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle.isEmpty ? "Lens 视频" : safeTitle).mp4"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
            } catch {
                self?.onFailure?(error)
            }
        }
    }

    private func savedPlanTimeline(_ saved: SavedLens) -> VideoEditTimeline {
        (try? store.loadAutoEditPlan(from: saved.packageURL).timeline)
            ?? VideoEditTimeline(sourceDurationSeconds: saved.manifest.durationSeconds ?? 0)
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
                let image = NSImage(
                    cgImage: frame,
                    size: NSSize(width: frame.width, height: frame.height)
                )
                presenterThumbnailCache.setObject(
                    image,
                    forKey: cameraURL.standardizedFileURL as NSURL
                )
                model.setPresenterThumbnail(image)
            } catch {
                // The live editor remains usable with its native placeholder.
            }
        }
    }

    private func canDiscardUnsavedChanges() -> Bool {
        guard model?.isPlanPersisted == false else { return true }
        let alert = NSAlert()
        alert.messageText = "放弃尚未保存的编辑？"
        alert.informativeText = "原始录屏不会受影响，但本次尚未写入磁盘的调整会丢失。"
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
