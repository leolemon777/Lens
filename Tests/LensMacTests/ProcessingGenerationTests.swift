import Foundation
import XCTest
@testable import LensMac

final class ProcessingGenerationTests: XCTestCase {
    func testProcessingUsesGenerationGuardBeforePublishingAndSeparatesCancellation() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderPresentation.swift"
                ),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/LensMac/Support/RecordingRenderTaskCoordinator.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(
                "private let recordingRenderTaskRegistry = RecordingRenderTaskRegistry()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "private lazy var recordingRenderTaskCoordinator ="
            )
        )
        XCTAssertTrue(source.contains("recordingRenderTaskCoordinator.process(saved)"))
        XCTAssertTrue(coordinator.contains("RecordingRenderWorkRequest("))
        XCTAssertTrue(coordinator.contains("registry.track("))
        XCTAssertTrue(coordinator.contains("registry.isCurrent("))
        XCTAssertTrue(coordinator.contains("private lazy var defaultWorker"))
        XCTAssertTrue(coordinator.contains("registry.cancel(for: packageKey)"))
        XCTAssertTrue(coordinator.contains("withTaskCancellationHandler"))
        XCTAssertTrue(coordinator.contains("presentation.presentCancellation("))
        XCTAssertTrue(coordinator.contains("presentation.presentFailure("))
        XCTAssertTrue(presentation.contains("presentCancellation("))
        XCTAssertTrue(presentation.contains(".cancelled"))
        XCTAssertFalse(
            presentation.contains("confirmationTitle: \"成片生成已取消\",\n                deliveryState: .failed")
        )
    }
}
