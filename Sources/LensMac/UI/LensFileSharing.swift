import AppKit
import LensCore

/// Presents the native macOS share sheet for a file that Lens has already
/// selected as a trustworthy delivery candidate. No service is contacted until
/// the user chooses one in the system picker.
@MainActor
enum LensFileSharing {
    enum ShareChoiceKind: String, Equatable, Sendable {
        case renderedVideo
        case rawRecording
        case lensProject
    }

    struct ShareChoice: Equatable, Sendable {
        let kind: ShareChoiceKind
        let title: String
        let url: URL
    }

    /// Builds the explicit representations that may enter the system share
    /// picker. Keeping this decision separate from NSAlert makes the privacy
    /// boundary testable: an unverified render can never be presented as a
    /// finished video, while raw and project sharing remain explicit choices.
    static func shareChoices(
        for lens: SavedLens,
        renderedURL: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [ShareChoice] {
        var choices: [ShareChoice] = []
        if let renderedURL, fileExists(renderedURL) {
            choices.append(
                ShareChoice(
                    kind: .renderedVideo,
                    title: "分享成片",
                    url: renderedURL
                )
            )
        }
        if fileExists(lens.rawAssetURL) {
            choices.append(
                ShareChoice(
                    kind: .rawRecording,
                    title: "分享原始录屏",
                    url: lens.rawAssetURL
                )
            )
        }
        if fileExists(lens.packageURL) {
            choices.append(
                ShareChoice(
                    kind: .lensProject,
                    title: "分享 Lens 项目",
                    url: lens.packageURL
                )
            )
        }
        return choices
    }

    static func present(fileURL: URL) {
        let fileURL = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let anchor = NSApp.keyWindow?.contentView
                ?? NSApp.mainWindow?.contentView
                ?? NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(
            relativeTo: anchor.bounds.insetBy(dx: 24, dy: 24),
            of: anchor,
            preferredEdge: .minY
        )
    }

    /// Recordings have two valid user-owned representations. Ask explicitly
    /// before opening the system picker so a stale/attention-needed render can
    /// never be mistaken for the original, and so sharing a whole `.lens`
    /// project is an intentional choice.
    static func present(lens: SavedLens) {
        // A preview that is still processing, failed verification, or no
        // longer matches the current source/plan is not offered as “成片”.
        // The raw recording and the complete project remain explicit choices.
        let renderedURL: URL? = if lens.manifest.state == .ready,
                                   !QuickAccessFileTransfer.previewNeedsReview(for: lens) {
            lens.manifest.assets.first(where: { $0.role == .renderedVideo })
                .map { lens.packageURL.appendingPathComponent($0.relativePath) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        } else {
            nil
        }
        let choices = shareChoices(for: lens, renderedURL: renderedURL)
        guard !choices.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "选择要分享的内容"
        alert.informativeText = "Lens 不会自动上传；发送动作由你在系统分享面板中确认。"
        choices.forEach { alert.addButton(withTitle: $0.title) }
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return }
        present(fileURL: choices[index].url)
    }
}
