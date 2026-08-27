import Foundation

/// Editable OCR text shown in a floating result card instead of being copied immediately.
public struct OCRResultDraft: Equatable, Sendable {
    public let originalText: String
    public let blockCount: Int
    public var editedText: String

    public init(originalText: String, blockCount: Int, editedText: String? = nil) {
        self.originalText = originalText
        self.blockCount = max(blockCount, 0)
        self.editedText = editedText ?? originalText
    }

    public init(document: OCRDocument) {
        self.init(originalText: document.fullText, blockCount: document.blocks.count)
    }

    public var isEdited: Bool { editedText != originalText }

    public var hasText: Bool {
        !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func reset() {
        editedText = originalText
    }
}
