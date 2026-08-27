import AppKit

@MainActor
enum FileURLPasteboard {
    static func copy(
        _ url: URL,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let fileURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        return copied?.contains {
            $0.standardizedFileURL == fileURL
        } == true
    }
}
