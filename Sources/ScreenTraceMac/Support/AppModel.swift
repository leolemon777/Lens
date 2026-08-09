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

    private enum PreferenceKey {
        static let capturesSystemAudio = "recording.capturesSystemAudio"
        static let capturesMicrophone = "recording.capturesMicrophone"
    }

    private let defaults: UserDefaults
    @Published private(set) var recentTrace: RecentTrace?
    @Published var capturesSystemAudio: Bool {
        didSet { defaults.set(capturesSystemAudio, forKey: PreferenceKey.capturesSystemAudio) }
    }
    @Published var capturesMicrophone: Bool {
        didSet { defaults.set(capturesMicrophone, forKey: PreferenceKey.capturesMicrophone) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        capturesSystemAudio = defaults.object(forKey: PreferenceKey.capturesSystemAudio) as? Bool ?? true
        capturesMicrophone = defaults.object(forKey: PreferenceKey.capturesMicrophone) as? Bool ?? false
    }

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
