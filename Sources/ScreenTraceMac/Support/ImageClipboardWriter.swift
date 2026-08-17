import AppKit

@MainActor
enum ImageClipboardWriter {
    static func write(
        _ image: NSImage,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else { return false }

        // `writeObjects` only confirms that AppKit accepted the provider. Verify
        // that another app can actually discover an image representation before
        // presenting a successful copy message to the user.
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }
}
