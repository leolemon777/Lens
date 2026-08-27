import AppKit
import SwiftUI
import XCTest
@testable import LensMac

@MainActor
final class PermissionCenterViewTests: XCTestCase {
    func testPermissionCenterRendersEditableShortcutsAndPermissions() throws {
        let suiteName = "LensPermissionViewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = ZStack {
            Color(red: 0.55, green: 0.55, blue: 0.55)
            PermissionCenterView(
                model: PermissionCenterModel(),
                appModel: AppModel(defaults: defaults),
                onShortcutsChanged: {},
                onClose: {}
            )
        }
        .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 678, height: 628)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create permission center snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])
        if let path = ProcessInfo.processInfo.environment[
            "LENS_PERMISSION_CENTER_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 678)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 628)
        XCTAssertGreaterThan(png?.count ?? 0, 20_000)
    }
}
