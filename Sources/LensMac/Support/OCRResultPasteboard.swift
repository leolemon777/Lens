import AppKit

@MainActor
enum OCRResultPasteboard {
    static func copy(
        _ text: String,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.string(forType: .string) == text
    }
}
