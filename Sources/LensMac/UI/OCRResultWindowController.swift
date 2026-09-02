import AppKit
import LensCore
import SwiftUI

@MainActor
final class OCRResultWindowController {
    private var sessions: [UUID: Session] = [:]
    var onCopyResult: ((Bool) -> Void)?
    var hasVisibleResults: Bool { !sessions.isEmpty }

    func closeAll() {
        sessions.values.forEach { LensPanelPresenter.dismiss($0.panel) }
        sessions.removeAll()
    }

    func beginRecognizing(lensID: UUID, thumbnail: NSImage?) {
        showSession(
            id: lensID,
            model: OCRResultModel(recognizing: thumbnail),
            accessibilityLabel: "OCR 正在识别"
        )
    }

    @discardableResult
    func fulfill(lensID: UUID, document: OCRDocument) -> OCRResultFulfillment {
        guard let session = sessions[lensID] else { return .dismissed }
        let draft = OCRResultDraft(document: document)
        guard draft.hasText else {
            close(id: lensID)
            return .empty
        }
        session.model.apply(document)
        session.panel.title = "OCR 识别"
        session.panel.setAccessibilityLabel("OCR 识别结果")
        return .ready
    }

    func fail(lensID: UUID) {
        close(id: lensID)
    }

    func show(document: OCRDocument, thumbnail: NSImage?) {
        showSession(
            id: UUID(),
            model: OCRResultModel(document: document, thumbnail: thumbnail),
            accessibilityLabel: "OCR 识别结果"
        )
    }

    func thumbnail(for lensID: UUID) -> NSImage? {
        sessions[lensID]?.model.thumbnail
    }

    private func showSession(
        id: UUID,
        model: OCRResultModel,
        accessibilityLabel: String
    ) {
        close(id: id)
        let panel = makePanel(accessibilityLabel: accessibilityLabel)
        let session = Session(id: id, model: model, panel: panel)
        let close: () -> Void = { [weak self] in
            guard let self else { return }
            self.close(id: id)
        }
        panel.onEscape = close
        panel.contentView = NSHostingView(rootView: OCRResultView(
            model: model,
            onCopy: { [weak self] in
                self?.onCopyResult?(model.copy())
            },
            onCopyAndClose: { [weak self] in
                let copied = model.copy()
                self?.onCopyResult?(copied)
                if copied {
                    self?.close(id: id)
                }
            },
            onClose: close
        ))
        panel.setContentSize(NSSize(
            width: 464,
            height: model.thumbnail == nil ? 364 : 452
        ))
        position(panel)
        sessions[id] = session
        NSApp.activate(ignoringOtherApps: true)
        LensPanelPresenter.present(panel, from: .center)
        panel.makeKey()
    }

    private func close(id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        LensPanelPresenter.dismiss(session.panel)
    }

    private func makePanel(accessibilityLabel: String) -> LensGlassPanel {
        let panel = LensGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 464, height: 452),
            placement: .center
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "OCR 识别"
        panel.setAccessibilityLabel(accessibilityLabel)
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let offset = CGFloat(sessions.count) * 28
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width - 24 - offset,
            y: screen.visibleFrame.midY - panel.frame.height / 2 - offset
        ))
    }
}

private struct Session {
    let id: UUID
    let model: OCRResultModel
    let panel: LensGlassPanel
}
