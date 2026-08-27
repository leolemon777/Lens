import AppKit
import LensCore
import SwiftUI

@MainActor
final class LensLibraryWindowController {
    private let store: LensProjectStore
    private let model: LensLibraryModel
    private let window: LensLibraryWindow

    var onAnnotateRequested: ((SavedLens, NSImage) -> Void)?
    var onOCRRequested: ((LensLibraryEntry) -> Void)?
    var onEditRecordingRequested: ((LensLibraryEntry) -> Void)?
    var onTranscriptionRequested: ((LensLibraryEntry) -> Void)?
    var onOrganizationRequested: ((LensLibraryEntry) -> Void)?
    var onInsightsCustomizationRequested: ((LensLibraryEntry, LensInsightsCustomization?) -> Void)?
    var onCopyResult: ((Bool) -> Void)?
    /// A rebuilt recording is handed back as `processing` so the ordinary
    /// post-processing path regenerates its preview and plan for the new length.
    var onRecordingRepaired: ((LensLibraryEntry, RebuiltRecording) -> Void)?

    init(store: LensProjectStore) {
        self.store = store
        model = LensLibraryModel(store: store)
        window = LensLibraryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureWindow()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        model.reload()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    func reloadIfVisible() {
        guard isVisible else { return }
        model.reload()
    }

    func setTranscribing(_ isTranscribing: Bool, lensID: UUID) {
        model.setTranscribing(isTranscribing, id: lensID)
    }

    func setOrganizing(_ isOrganizing: Bool, lensID: UUID) {
        model.setOrganizing(isOrganizing, id: lensID)
    }

    private func configureWindow() {
        window.title = "Lens 库"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 580)
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenPrimary]
        window.onEscape = { [weak self] in self?.hide() }

        let root = LensLibraryView(
            model: model,
            onOpen: { [weak self] in self?.open($0) },
            onReveal: { [weak self] in self?.reveal($0) },
            onCopy: { [weak self] in self?.copy($0) },
            onAnnotate: { [weak self] in self?.annotate($0) },
            onShowOCR: { [weak self] in self?.showOCR($0) },
            onTranscribe: { [weak self] in self?.transcribe($0) },
            onOrganize: { [weak self] in self?.organize($0) },
            onSaveInsights: { [weak self] entry, customization in
                self?.saveInsights(entry, customization: customization)
            },
            onDelete: { [weak self] in self?.confirmDelete($0) },
            onRepair: { [weak self] in self?.repairRecoverable($0) },
            onDeleteAll: { [weak self] in self?.confirmDeleteAll() },
            onOpenFolder: { [weak self] in self?.openFolder() },
            onClose: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    private func open(_ entry: LensLibraryEntry) {
        if entry.manifest.kind == .recording {
            onEditRecordingRequested?(entry)
            return
        }
        let url = FileManager.default.fileExists(atPath: entry.displayAssetURL.path)
            ? entry.displayAssetURL
            : entry.packageURL
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ entry: LensLibraryEntry) {
        let url = FileManager.default.fileExists(atPath: entry.displayAssetURL.path)
            ? entry.displayAssetURL
            : entry.packageURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ entry: LensLibraryEntry) {
        guard entry.manifest.kind == .screenshot,
              let image = NSImage(contentsOf: entry.displayAssetURL) else { return }
        onCopyResult?(ImageClipboardWriter.write(image))
    }

    private func annotate(_ entry: LensLibraryEntry) {
        guard entry.manifest.kind == .screenshot,
              let image = NSImage(contentsOf: entry.primaryAssetURL) else { return }
        let lens = SavedLens(
            packageURL: entry.packageURL,
            rawAssetURL: entry.primaryAssetURL,
            manifest: entry.manifest
        )
        onAnnotateRequested?(lens, image)
    }

    private func showOCR(_ entry: LensLibraryEntry) {
        guard entry.ocrText?.isEmpty == false else { return }
        onOCRRequested?(entry)
    }

    private func transcribe(_ entry: LensLibraryEntry) {
        guard entry.manifest.kind == .recording else { return }
        onTranscriptionRequested?(entry)
    }

    private func organize(_ entry: LensLibraryEntry) {
        onOrganizationRequested?(entry)
    }

    private func saveInsights(
        _ entry: LensLibraryEntry,
        customization: LensInsightsCustomization?
    ) {
        onInsightsCustomizationRequested?(entry, customization)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.rootDirectory)
    }

    /// Merging changes the project, so it is confirmed first. The sheet states
    /// what happens to the original files, because the whole reason this
    /// recording needs recovery is that it already lost content once.
    private func repairRecoverable(_ entry: LensLibraryEntry) {
        guard let assessment = model.recoveryAssessment(for: entry.id),
              assessment.canRebuildLongerRecording,
              !model.isRepairing(entry.id) else { return }
        let alert = NSAlert()
        alert.messageText = "把缺失的 \(Self.durationText(assessment.recoverableScreenSeconds))画面并入“\(entry.manifest.title)”？"
        alert.informativeText = """
        成片会从 \(Self.durationText(assessment.presentedScreenSeconds))变成 \
        \(Self.durationText(assessment.availableScreenSeconds))。\
        原始分片会保留在项目内，不会被覆盖或删除；并入后会按新时长重新生成预览。
        """
        alert.addButton(withTitle: "并入")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch await model.repairRecoverableRecording(entry) {
                case let .success(rebuilt):
                    model.reload()
                    onRecordingRepaired?(entry, rebuilt)
                case let .failure(error):
                    showMessage(
                        title: "并入失败",
                        message: "原始文件没有被改动。\(error.localizedDescription)"
                    )
                case nil:
                    break
                }
            }
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        seconds >= 60
            ? String(format: "%d 分 %.0f 秒", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
            : String(format: "%.1f 秒", seconds)
    }

    private func confirmDelete(_ entry: LensLibraryEntry) {
        guard model.canDelete(entry) else {
            showMessage(
                title: "暂时不能删除",
                message: "这条记录仍在录制或处理。完成后即可移到废纸篓。"
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除“\(entry.manifest.title)”？"
        alert.informativeText = "项目会移到废纸篓，原始媒体、标注和转写会一起移动，之后仍可恢复。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trash([entry])
        }
    }

    private func confirmDeleteAll() {
        let deletable = model.entries.filter(model.canDelete)
        guard !deletable.isEmpty else {
            showMessage(
                title: "没有可删除的记录",
                message: "正在录制或处理的项目会受到保护。"
            )
            return
        }
        let protectedCount = model.entries.count - deletable.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除全部 \(deletable.count) 条记录？"
        var detail = "全部项目会移到废纸篓，之后仍可恢复。"
        if protectedCount > 0 {
            detail += " 另有 \(protectedCount) 条正在录制或处理，将自动保留。"
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "全部移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trash(deletable)
        }
    }

    private func trash(_ entries: [LensLibraryEntry]) {
        let targets = entries.map { ($0.id, $0.packageURL) }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var deleted = Set<UUID>()
                var failures: [String] = []
                for (id, url) in targets {
                    do {
                        var resultingURL: NSURL?
                        try FileManager.default.trashItem(
                            at: url,
                            resultingItemURL: &resultingURL
                        )
                        deleted.insert(id)
                    } catch {
                        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                return (deleted, failures)
            }.value
            guard let self else { return }
            model.removeEntries(withIDs: result.0)
            if !result.1.isEmpty {
                showMessage(
                    title: "部分项目未能删除",
                    message: result.1.joined(separator: "\n")
                )
            }
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: window)
    }
}

private final class LensLibraryWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
