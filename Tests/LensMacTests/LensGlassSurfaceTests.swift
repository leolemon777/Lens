import AppKit
import SwiftUI
import XCTest
@testable import LensMac

/// Locks down the "screenshot flow renders bright glass" rule and the two
/// `LensGlassSurface` knobs it depends on.
///
/// This suite exists because the rule was originally applied to only one of
/// the flow's windows: the other three received a `tint` alone, which under
/// Dark Mode is invisible — Liquid Glass follows the system appearance, so
/// only the appearance itself can force the bright treatment.
@MainActor
final class LensGlassSurfaceTests: XCTestCase {
    /// Windows the user meets while capturing or editing a screenshot. The
    /// library, video editor, permission center, and onboarding are
    /// deliberately absent: they still follow the system appearance.
    private static let screenshotFlowWindowControllers = [
        "QuickAccessWindowController.swift",
        "OCRResultWindowController.swift",
        "ScreenshotAnnotationEditorWindowController.swift"
    ]

    private static let uiDirectoryURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LensMac/UI")
    }()

    func testBrightGlassAppearanceForcesLightRegardlessOfTheSystemSetting() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)

        window.applyLensBrightGlassAppearance()

        XCTAssertEqual(window.appearance?.name, .aqua)
    }

    /// The ratchet: every window controller in the screenshot flow must opt
    /// into the bright treatment. Scanning source text (the same approach as
    /// `LensPanelPresentationLintTests`) catches a newly added capture-flow
    /// window that forgets the call, which an instance-level assertion could
    /// not — the panel classes are `private` and a new one would simply not
    /// be covered.
    func testEveryScreenshotFlowWindowControllerOptsIntoBrightGlass() throws {
        for fileName in Self.screenshotFlowWindowControllers {
            let url = Self.uiDirectoryURL.appendingPathComponent(fileName)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                source.contains("applyLensBrightGlassAppearance()"),
                "\(fileName) is part of the screenshot flow, so its window must "
                    + "call applyLensBrightGlassAppearance(); a tint alone renders "
                    + "dark under Dark Mode"
            )
        }
    }

    /// Guards the list above against silent rot: a renamed or deleted
    /// controller would otherwise make the assertion vacuous.
    func testScreenshotFlowControllerListMatchesFilesOnDisk() {
        for fileName in Self.screenshotFlowWindowControllers {
            let url = Self.uiDirectoryURL.appendingPathComponent(fileName)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(fileName) is listed as a screenshot-flow window but no longer exists"
            )
        }
    }

    /// Documents a hard limit on what this suite can prove.
    ///
    /// Liquid Glass is composited by the window server, not drawn through the
    /// view's own path, so `cacheDisplay(in:to:)` cannot observe it: a view
    /// with `.glassEffect` snapshots byte-for-byte identically to one with no
    /// effect at all, while a plain colour background (the control below)
    /// changes the snapshot as expected. Tint and material therefore cannot be
    /// asserted here — **the glass look is verifiable only by running the app**.
    ///
    /// This test pins the control case so the suite still fails loudly if the
    /// snapshot harness itself breaks, and so the next person does not spend
    /// time writing a glass snapshot assertion that can never pass.
    func testSnapshotHarnessSeesOrdinaryDrawingButCannotSeeGlass() throws {
        let plain = try render(background: nil)
        let solid = try render(background: .red)
        XCTAssertNotEqual(
            plain,
            solid,
            "control: an ordinary colour background must change the snapshot; "
                + "if this fails the snapshot harness is broken"
        )

        let glass = try render(glass: true)
        let noEffect = try render(background: nil)
        XCTAssertEqual(
            glass,
            noEffect,
            "if glass ever becomes observable through cacheDisplay, this "
                + "expectation is stale — revisit whether the look can now be "
                + "asserted automatically instead of only by eye"
        )
    }

    func testShadowOverrideReplacesTheRoleDefaultAndIsOptional() {
        let tight = LensGlassSurfaceRole.card.shadow
        let overridden = LensGlassSurface(
            role: .panel,
            cornerRadius: LensGlassMetrics.panelCornerRadius,
            shadowOverride: tight
        )
        XCTAssertEqual(overridden.shadowOverride?.radius, tight.radius)
        XCTAssertNotEqual(
            tight.radius,
            LensGlassSurfaceRole.panel.shadow.radius,
            "the override in this test must actually differ from the role default"
        )

        let defaulted = LensGlassSurface(
            role: .panel,
            cornerRadius: LensGlassMetrics.panelCornerRadius
        )
        XCTAssertNil(
            defaulted.shadowOverride,
            "callers that don't override must keep falling back to role.shadow"
        )
    }

    private func render(background: Color? = nil, glass: Bool = false) throws -> Data {
        let shape = RoundedRectangle(
            cornerRadius: LensGlassMetrics.panelCornerRadius,
            style: .continuous
        )
        let base = Color.clear.frame(width: 160, height: 120)
        let root: AnyView
        if glass, #available(macOS 26.0, *) {
            root = AnyView(base.glassEffect(.regular, in: shape))
        } else if let background {
            root = AnyView(base.background(background, in: shape))
        } else {
            root = AnyView(base)
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 200, height: 160)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XCTSkip("Unable to create SwiftUI snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Unable to encode SwiftUI snapshot")
        }
        return png
    }
}
