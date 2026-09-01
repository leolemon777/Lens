import AppKit
import SwiftUI
import XCTest
@testable import LensMac

@MainActor
final class OnboardingViewTests: XCTestCase {
    func testEveryStepRendersWithoutLosingItsContent() throws {
        for step in OnboardingStep.allCases {
            let png = try renderStep(
                step,
                states: [
                    .screenCapture: .granted,
                    .accessibility: .denied,
                    .inputMonitoring: .notDetermined
                ]
            )
            // A step that failed to lay out collapses to a nearly empty
            // surface, which stays well under this size once encoded.
            XCTAssertGreaterThan(
                png.count,
                12_000,
                "step \(step) rendered an implausibly empty surface"
            )
        }
    }

    func testEssentialsStepShowsTheRelaunchHintOnlyAfterAskingDidNotHelp() throws {
        let quiet = try renderStep(
            .essentials,
            states: [.screenCapture: .denied, .accessibility: .granted],
            didRequestScreenCapture: false
        )
        let hinted = try renderStep(
            .essentials,
            states: [.screenCapture: .denied, .accessibility: .granted],
            didRequestScreenCapture: true
        )

        // The hint adds a warning line and a button, so the rendered surface
        // has to change. Equal bytes would mean the branch never displayed.
        XCTAssertNotEqual(quiet, hinted)
    }

    func testPermissionRowsExposeTargetedActionSemantics() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(source.contains("Label(state.title, systemImage: permissionStateSymbol(state))"))
        XCTAssertTrue(source.contains(".accessibilityValue(state.title)"))
        XCTAssertTrue(source.contains("\\(action)：\\(kind.title)"))
        XCTAssertTrue(source.contains("permissionActionHint(for: state, kind: kind)"))
        XCTAssertTrue(source.contains("请求\\(kind.title)权限"))
        XCTAssertTrue(source.contains("打开系统设置中的\\(kind.title)权限"))
    }

    // MARK: - Rendering

    private func renderStep(
        _ step: OnboardingStep,
        states: [SystemPermissionKind: PermissionAccessState],
        didRequestScreenCapture: Bool = false,
        function: String = #function
    ) throws -> Data {
        let suiteName = "OnboardingViewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OnboardingModel(defaults: defaults, stateProvider: { states })
        model.jump(to: step)
        if didRequestScreenCapture {
            model.noteScreenCaptureRequested()
        }
        let appModel = AppModel(defaults: defaults)

        let root = ZStack {
            Color(red: 0.42, green: 0.45, blue: 0.50)
            OnboardingView(
                model: model,
                appModel: appModel,
                onGrant: { _ in },
                onQuit: {},
                onFinish: {}
            )
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 678, height: 508)
        let snapshotWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.contentView = hostingView
        snapshotWindow.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        snapshotWindow.orderFront(nil)
        defer { snapshotWindow.orderOut(nil) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        if let directory = ProcessInfo.processInfo.environment[
            "LENS_ONBOARDING_SNAPSHOT_DIRECTORY"
        ] {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("onboarding-\(step).png")
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory),
                withIntermediateDirectories: true
            )
            try png.write(to: url, options: .atomic)
        }
        return png
    }
}
