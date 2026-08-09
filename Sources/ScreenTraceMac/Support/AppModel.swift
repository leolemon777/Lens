import AppKit
import Foundation
import ScreenTraceCore

@MainActor
final class AppModel: ObservableObject {
    struct RecentTrace: Identifiable {
        let id: UUID
        let title: String
        let packageURL: URL
        let imageURL: URL
        let dimensions: TraceDimensions
        let thumbnail: NSImage
    }

    @Published private(set) var recentTrace: RecentTrace?

    func setRecentTrace(_ savedTrace: SavedTrace, thumbnail: NSImage) {
        guard let dimensions = savedTrace.manifest.dimensions else { return }
        recentTrace = RecentTrace(
            id: savedTrace.manifest.id,
            title: savedTrace.manifest.title,
            packageURL: savedTrace.packageURL,
            imageURL: savedTrace.rawAssetURL,
            dimensions: dimensions,
            thumbnail: thumbnail
        )
    }
}
