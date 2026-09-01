import AppKit

/// Presents the native macOS share sheet for a file that Lens has already
/// selected as a trustworthy delivery candidate. No service is contacted until
/// the user chooses one in the system picker.
@MainActor
enum LensFileSharing {
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
}
