import AppKit
import LensCore

@MainActor
enum ConversationInboxPasteboard {
    /// Copies the POSIX path as plain text so a terminal chat can paste it.
    /// Intentionally does not place an image on the pasteboard.
    static func copyPath(
        _ url: URL,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let path = url.path
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        return pasteboard.string(forType: .string) == path
            && pasteboard.availableType(from: [.png, .tiff]) == nil
    }
}
