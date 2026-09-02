import Foundation

enum VideoEditorFormatting {
    static func timeText(_ seconds: Double) -> String {
        let value = max(seconds.isFinite ? seconds : 0, 0)
        let total = Int(value.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func captionTimeText(_ seconds: Double) -> String {
        let value = max(seconds.isFinite ? seconds : 0, 0)
        let minutes = Int(value / 60)
        return String(format: "%d:%04.1f", minutes, value - Double(minutes * 60))
    }
}
