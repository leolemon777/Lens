import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingRenderExecutionTests: XCTestCase {
    private struct InjectedFailure: Error, Sendable {}

    func testExecutionForwardsRequestAndResult() async throws {
        let saved = makeSavedLens()
        let generation = UUID()
        let token = RecordingTaskToken(
            id: UUID(),
            packageURL: saved.packageURL,
            kind: .render,
            version: "execution-v1"
        )
        var received: RecordingRenderExecutionRequest?
        let execution = RecordingRenderExecution { request in
            received = request
            return self.makeResult(saved: saved)
        }

        let result = try await execution.run(
            RecordingRenderExecutionRequest(
                saved: saved,
                generation: generation,
                taskToken: token
            )
        )

        XCTAssertEqual(received?.saved, saved)
        XCTAssertEqual(received?.generation, generation)
        XCTAssertEqual(received?.taskToken, token)
        XCTAssertEqual(result.updated, saved)
    }

    func testExecutionPropagatesCancellationAndInjectedFailures() async {
        let saved = makeSavedLens()
        let request = RecordingRenderExecutionRequest(
            saved: saved,
            generation: UUID(),
            taskToken: RecordingTaskToken(
                id: UUID(),
                packageURL: saved.packageURL,
                kind: .render,
                version: "execution-faults"
            )
        )

        let cancelled = RecordingRenderExecution { _ in
            throw CancellationError()
        }
        do {
            _ = try await cancelled.run(request)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let failed = RecordingRenderExecution { _ in
            throw InjectedFailure()
        }
        do {
            _ = try await failed.run(request)
            XCTFail("Expected injected failure to propagate")
        } catch is InjectedFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeSavedLens() -> SavedLens {
        let packageURL = URL(fileURLWithPath: "/tmp/render-execution-\(UUID().uuidString).lens")
        let manifest = LensManifest(
            kind: .recording,
            title: "execution",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        return SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            manifest: manifest
        )
    }

    private func makeResult(saved: SavedLens) -> RecordingRenderExecutionResult {
        let verification = RenderedEffectVerificationReport(
            previewPlayable: true,
            previewDurationSeconds: 1,
            rawMeasuredFramesPerSecond: 30,
            previewMeasuredFramesPerSecond: 30,
            minimumExpectedFramesPerSecond: 30,
            effects: []
        )
        let pipelineResult = RecordingRenderPipelineResult(
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
            microphoneWasMixed: false,
            voiceProcessingFellBack: false,
            audioMixErrorDescription: nil,
            presenterWasRendered: false,
            renderEncodePassCount: 1,
            renderElapsedMilliseconds: 10,
            renderPeakPhysicalFootprintBytes: 1
        )
        return RecordingRenderExecutionResult(
            plan: AutoEditPlan(),
            updated: saved,
            pipelineResult: pipelineResult,
            cameraURL: nil,
            microphoneURL: nil
        )
    }
}
