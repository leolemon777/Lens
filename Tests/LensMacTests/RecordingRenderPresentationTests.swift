import AppKit
import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingRenderPresentationTests: XCTestCase {
    func testVerifiedRenderPublishesReadyStateAndSafeDurationMetric() {
        let saved = makeSavedLens()
        var reloadCount = 0
        var update: (SavedLens, String, QuickAccessDeliveryState)?
        var toasts: [String] = []
        var diagnostics: (String, DiagnosticLevel, [String: String])?
        let presenter = RecordingRenderPresentation(
            reloadLibrary: { reloadCount += 1 },
            deliveryImage: { _ in NSImage(size: CGSize(width: 1, height: 1)) },
            updateQuickAccess: { lens, _, title, state in
                update = (lens, title, state)
            },
            showToast: { title, _, _ in toasts.append(title) },
            recordDiagnostic: { code, level, metadata in
                diagnostics = (code, level, metadata)
            }
        )

        let result = presenter.present(
            makeInput(
                saved: saved,
                updated: saved,
                verification: verifiedReport(),
                elapsedMilliseconds: 1_234.4
            )
        )

        XCTAssertEqual(result, AutoEditPlan())
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(update?.0, saved)
        XCTAssertEqual(update?.1, "成片已可发送 · 1.2 秒")
        XCTAssertEqual(update?.2, .ready)
        XCTAssertTrue(toasts.isEmpty)
        XCTAssertEqual(diagnostics?.0, "preview.completed")
        XCTAssertEqual(diagnostics?.1, .info)
        XCTAssertEqual(diagnostics?.2["durationMilliseconds"], "1234")
        XCTAssertEqual(diagnostics?.2["renderEncodePassCount"], "1")
        XCTAssertEqual(diagnostics?.2["renderMilliseconds"], "322")
        XCTAssertEqual(diagnostics?.2["renderPeakPhysicalFootprintBytes"], "1")
    }

    func testUnverifiedRenderExplainsPreservedTracksAndVerificationFailure() {
        let saved = makeSavedLens(includeCamera: true, includeMicrophone: true)
        var toastDetail = ""
        var updateState: QuickAccessDeliveryState?
        let presenter = RecordingRenderPresentation(
            reloadLibrary: {},
            deliveryImage: { _ in NSImage(size: CGSize(width: 1, height: 1)) },
            updateQuickAccess: { _, _, _, state in updateState = state },
            showToast: { _, detail, _ in toastDetail = detail },
            recordDiagnostic: { _, _, _ in }
        )

        _ = presenter.present(
            makeInput(
                saved: saved,
                updated: saved,
                verification: RenderedEffectVerificationReport(
                    previewPlayable: true,
                    previewDurationSeconds: 1,
                    rawMeasuredFramesPerSecond: 30,
                    previewMeasuredFramesPerSecond: 30,
                    minimumExpectedFramesPerSecond: 30,
                    effects: [RenderedEffectVerification(
                        effect: .cursor,
                        state: .failed
                    )]
                ),
                cameraURL: URL(fileURLWithPath: "/tmp/camera.mov"),
                microphoneURL: URL(fileURLWithPath: "/tmp/mic.caf"),
                microphoneWasMixed: false,
                presenterWasRendered: false,
                elapsedMilliseconds: 10
            )
        )

        XCTAssertEqual(updateState, .needsReview)
        XCTAssertTrue(toastDetail.contains("光标未通过媒体验证"))
        XCTAssertTrue(toastDetail.contains("摄像头、麦克风原始轨已保留"))
    }

    func testCancelledRenderKeepsRawDeliveryAndRecordsCancellation() {
        let saved = makeSavedLens()
        var updateState: QuickAccessDeliveryState?
        var diagnostic: (String, DiagnosticLevel)?
        let presenter = RecordingRenderPresentation(
            reloadLibrary: {},
            deliveryImage: { _ in NSImage(size: CGSize(width: 1, height: 1)) },
            updateQuickAccess: { _, _, _, state in updateState = state },
            showToast: { _, _, _ in XCTFail("Cancellation should not show a failure toast") },
            recordDiagnostic: { code, level, _ in diagnostic = (code, level) }
        )

        presenter.presentCancellation(for: saved, isCurrent: true)

        XCTAssertEqual(updateState, .cancelled)
        XCTAssertEqual(diagnostic?.0, "preview.cancelled")
        XCTAssertEqual(diagnostic?.1, .warning)
    }

    func testStaleRenderFailureRecordsErrorWithoutOverwritingCurrentDelivery() {
        let saved = makeSavedLens()
        var updateCount = 0
        var toastCount = 0
        var diagnostic: (String, DiagnosticLevel, [String: String])?
        let presenter = RecordingRenderPresentation(
            reloadLibrary: {},
            deliveryImage: { _ in NSImage(size: CGSize(width: 1, height: 1)) },
            updateQuickAccess: { _, _, _, _ in updateCount += 1 },
            showToast: { _, _, _ in toastCount += 1 },
            recordDiagnostic: { code, level, metadata in
                diagnostic = (code, level, metadata)
            }
        )

        presenter.presentFailure(
            for: saved,
            isCurrent: false,
            metadata: ["reason": "injected"]
        )

        XCTAssertEqual(updateCount, 0)
        XCTAssertEqual(toastCount, 0)
        XCTAssertEqual(diagnostic?.0, "preview.failed")
        XCTAssertEqual(diagnostic?.1, .error)
        XCTAssertEqual(diagnostic?.2["reason"], "injected")
    }

    private func makeInput(
        saved: SavedLens,
        updated: SavedLens,
        verification: RenderedEffectVerificationReport,
        cameraURL: URL? = nil,
        microphoneURL: URL? = nil,
        microphoneWasMixed: Bool = false,
        presenterWasRendered: Bool = false,
        elapsedMilliseconds: Double
    ) -> RecordingRenderPresentationInput {
        RecordingRenderPresentationInput(
            saved: saved,
            updated: updated,
            plan: AutoEditPlan(),
            pipelineResult: RecordingRenderPipelineResult(
                healthReport: RecordingHealthReport(
                    requestedFramesPerSecond: 30,
                    measuredFramesPerSecond: 30,
                    p95FrameIntervalMilliseconds: nil,
                    droppedFrameCount: 0,
                    videoStatus: .healthy,
                    eventStatus: .notMeasured,
                    pointerEventCount: 0,
                    clickEventCount: 0,
                    keyboardEventCount: 0,
                    windowEventCount: 0,
                    effectiveCameraKeyframeCount: 0,
                    cursorKeyframeCount: 0,
                    clickPulseCount: 0,
                    warnings: []
                ),
                renderedEffectVerification: verification,
                microphoneWasMixed: microphoneWasMixed,
                voiceProcessingFellBack: false,
                audioMixErrorDescription: nil,
                presenterWasRendered: presenterWasRendered,
                renderEncodePassCount: 1,
                renderElapsedMilliseconds: 321.7,
                renderPeakPhysicalFootprintBytes: 1
            ),
            cameraURL: cameraURL,
            microphoneURL: microphoneURL,
            elapsedMilliseconds: elapsedMilliseconds,
            presenterWasRendered: presenterWasRendered
        )
    }

    private func verifiedReport() -> RenderedEffectVerificationReport {
        RenderedEffectVerificationReport(
            previewPlayable: true,
            previewDurationSeconds: 1,
            rawMeasuredFramesPerSecond: 30,
            previewMeasuredFramesPerSecond: 30,
            minimumExpectedFramesPerSecond: 30,
            effects: []
        )
    }

    private func makeSavedLens(
        includeCamera: Bool = false,
        includeMicrophone: Bool = false
    ) -> SavedLens {
        let packageURL = URL(fileURLWithPath: "/tmp/render-presentation-\(UUID().uuidString).lens")
        var assets = [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        if includeCamera {
            assets.append(LensAsset(role: .camera, relativePath: "raw/camera.mov"))
        }
        if includeMicrophone {
            assets.append(LensAsset(role: .microphone, relativePath: "raw/mic.caf"))
        }
        let manifest = LensManifest(
            kind: .recording,
            title: "presentation",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: assets
        )
        return SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            manifest: manifest
        )
    }
}
