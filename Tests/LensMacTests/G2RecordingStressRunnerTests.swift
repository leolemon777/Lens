import XCTest
@testable import LensMac

final class G2RecordingStressRunnerTests: XCTestCase {
    func testDistributedEvidenceSamplingScalesForEnduranceRuns() {
        XCTAssertEqual(
            G2RecordingAcceptanceResult.requiredDistributedSampleCount(
                for: 60,
                shortCount: 5
            ),
            5
        )
        XCTAssertEqual(
            G2RecordingAcceptanceResult.requiredDistributedSampleCount(
                for: 300,
                shortCount: 5
            ),
            12
        )
        XCTAssertEqual(
            G2RecordingAcceptanceResult.requiredDistributedSampleCount(
                for: 3_600,
                shortCount: 6
            ),
            24
        )
    }

    func testProductionRecordingStillExcludesLensWindowsByDefault() {
        XCTAssertTrue(ScreenRecordingOptions().excludesCurrentProcessWindows)
    }

    func testDynamicVideoAnalyzerObservesChangingEncodedFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LensG2DynamicVideo-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticVideoFactory.makeVideo(
            at: url,
            frameCount: 180,
            framesPerSecond: 30
        )

        let evidence = await G2DynamicVideoAnalyzer.analyze(
            url: url,
            durationSeconds: 6
        )

        XCTAssertEqual(evidence.sampledFrameCount, 6)
        XCTAssertGreaterThanOrEqual(evidence.distinctFrameSignatureCount, 3)
    }

    func testDynamicVideoAnalyzerRejectsFrozenEncodedFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LensG2FrozenVideo-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticVideoFactory.makeVideo(
            at: url,
            frameCount: 180,
            framesPerSecond: 30,
            style: .greenCamera
        )

        let evidence = await G2DynamicVideoAnalyzer.analyze(
            url: url,
            durationSeconds: 6
        )

        XCTAssertEqual(evidence.sampledFrameCount, 6)
        // An H.264 encoder may render the first keyframe a few values away
        // from later identical frames. It must still remain below the gate's
        // three-signature minimum for genuinely dynamic content.
        XCTAssertLessThan(evidence.distinctFrameSignatureCount, 3)
    }

    func testAcceptanceRejectsShortAudioDespiteHealthyVideo() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput(
            systemAudioDurationSeconds: 1.25,
            systemAudioObservedTimelineSeconds: 1.25,
            routerAudioCallbackCount: 63,
            deliveredAudioCallbackCount: 63,
            receivedAudioSampleCount: 63,
            appendedAudioSampleCount: 63
        ))

        XCTAssertFalse(result.systemAudioSynchronized)
        XCTAssertFalse(result.systemAudioTimelineComplete)
        XCTAssertFalse(result.systemAudioCallbacksComplete)
        XCTAssertFalse(result.passed)
    }

    func testAcceptanceRequiresBoundedMemoryAndStopLatency() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput(
            peakPhysicalFootprintBytes: 700 * 1_024 * 1_024,
            endPhysicalFootprintBytes: 300 * 1_024 * 1_024,
            stopToPlayableMilliseconds: 12_000
        ))

        XCTAssertFalse(result.memoryBounded)
        XCTAssertFalse(result.stopLatencyMet)
        XCTAssertFalse(result.passed)
    }

    func testAcceptanceRejectsUnresponsiveMainActor() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput(
            p95MainActorSchedulingDelayMilliseconds: 65,
            maximumMainActorSchedulingDelayMilliseconds: 420
        ))

        XCTAssertFalse(result.mainActorResponsive)
        XCTAssertFalse(result.passed)
    }

    func testAcceptanceRejectsVisuallyFrozenRecording() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput(
            sampledVideoFrameCount: 6,
            distinctVideoFrameSignatureCount: 1
        ))

        XCTAssertFalse(result.dynamicContentVerified)
        XCTAssertFalse(result.passed)
    }

    func testAcceptanceRejectsSparseVideoFrameCount() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput(
            writtenVideoFrameCount: 120
        ))

        XCTAssertFalse(result.videoFrameCountComplete)
        XCTAssertFalse(result.passed)
    }

    func testAcceptanceRejectsMissingControlledAudioStimulus() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput(
            generatedToneDurationSeconds: 1
        ))

        XCTAssertFalse(result.audioStimulusComplete)
        XCTAssertFalse(result.passed)
    }

    func testAcceptancePassesCompleteSynchronizedCapture() {
        let result = G2RecordingAcceptanceResult(makeAcceptanceInput())

        XCTAssertTrue(result.passed)
    }

    func testSourceInterruptionConfigurationParsesInstalledFaultGate() throws {
        let configuration = try XCTUnwrap(G2SourceInterruptionConfiguration(
            arguments: [
                "Lens",
                "--g2-source-interruption",
                "--close-after-seconds", "9",
                "--callback-timeout-seconds", "14",
                "--report", "/tmp/source-interruption.json"
            ]
        ))

        XCTAssertEqual(configuration.closeAfterSeconds, 9)
        XCTAssertEqual(configuration.callbackTimeoutSeconds, 14)
        XCTAssertEqual(
            configuration.reportURL.path,
            "/tmp/source-interruption.json"
        )
    }

    func testSourceHostConfigurationRequiresExplicitWindowAndReadyMarker() throws {
        XCTAssertNil(G2SourceHostConfiguration(arguments: [
            "Lens", "--g2-source-host"
        ]))
        let configuration = try XCTUnwrap(G2SourceHostConfiguration(arguments: [
            "Lens",
            "--g2-source-host",
            "--window-title", "Disposable source",
            "--ready-marker", "/tmp/source-host.ready"
        ]))

        XCTAssertEqual(configuration.windowTitle, "Disposable source")
        XCTAssertEqual(configuration.readyMarkerURL.path, "/tmp/source-host.ready")
    }

    func testSystemAudioProbeConfigurationParsesInstalledBoundaryRun() throws {
        let configuration = try XCTUnwrap(G2SystemAudioProbeConfiguration(arguments: [
            "Lens",
            "--g2-system-audio-probe",
            "--duration-seconds", "12",
            "--report", "/tmp/audio-probe.json"
        ]))
        XCTAssertEqual(configuration.durationSeconds, 12)
        XCTAssertEqual(configuration.reportURL.path, "/tmp/audio-probe.json")
    }

    func testConfigurationParsesFullHourGate() throws {
        let configuration = try XCTUnwrap(G2RecordingStressConfiguration(arguments: [
            "Lens",
            "--g2-recording-stress",
            "--duration-seconds", "3600",
            "--fps", "60",
            "--report", "/tmp/g2.json"
        ]))

        XCTAssertEqual(configuration.durationSeconds, 3_600)
        XCTAssertEqual(configuration.framesPerSecond, 60)
        XCTAssertEqual(configuration.reportURL.path, "/tmp/g2.json")
        XCTAssertNil(configuration.workRootURL)
        XCTAssertNil(configuration.readyMarkerURL)
    }

    func testConfigurationClampsUnsafeValuesAndNormalizesFPS() throws {
        let configuration = try XCTUnwrap(G2RecordingStressConfiguration(arguments: [
            "Lens",
            "--g2-recording-stress",
            "--duration-seconds", "1",
            "--fps", "24"
        ]))

        XCTAssertEqual(configuration.durationSeconds, 5)
        XCTAssertEqual(configuration.framesPerSecond, 30)
    }

    func testConfigurationIgnoresUnrelatedLaunch() {
        XCTAssertNil(G2RecordingStressConfiguration(arguments: ["Lens"]))
    }

    func testCrashRecoveryConfigurationRequiresWorkRootAndParsesEvidenceInputs() throws {
        XCTAssertNil(G2RecordingRecoveryConfiguration(arguments: [
            "Lens", "--g2-recording-recovery"
        ]))
        let configuration = try XCTUnwrap(G2RecordingRecoveryConfiguration(arguments: [
            "Lens",
            "--g2-recording-recovery",
            "--work-root", "/tmp/crash-work",
            "--expected-duration-seconds", "17",
            "--report", "/tmp/recovery.json"
        ]))
        XCTAssertEqual(configuration.workRootURL.path, "/tmp/crash-work")
        XCTAssertEqual(configuration.expectedDurationSeconds, 17)
        XCTAssertEqual(configuration.fault, "SIGKILL")
        XCTAssertTrue(configuration.enforcesFragmentLossBoundary)
        XCTAssertTrue(configuration.requiresNewlyInterruptedCandidate)
        XCTAssertEqual(configuration.reportURL.path, "/tmp/recovery.json")

        let diskConfiguration = try XCTUnwrap(G2RecordingRecoveryConfiguration(
            arguments: [
                "Lens",
                "--g2-recording-recovery",
                "--work-root", "/tmp/disk-work",
                "--fault", "ENOSPC",
                "--allow-early-writer-failure",
                "--accept-already-interrupted"
            ]
        ))
        XCTAssertEqual(diskConfiguration.fault, "ENOSPC")
        XCTAssertFalse(diskConfiguration.enforcesFragmentLossBoundary)
        XCTAssertFalse(diskConfiguration.requiresNewlyInterruptedCandidate)
    }

    private func makeAcceptanceInput(
        systemAudioDurationSeconds: Double = 60,
        systemAudioObservedTimelineSeconds: Double = 60,
        generatedToneDurationSeconds: Double = 60,
        routerAudioCallbackCount: Int = 3_000,
        deliveredAudioCallbackCount: Int = 3_000,
        receivedAudioSampleCount: Int = 3_000,
        appendedAudioSampleCount: Int = 3_000,
        peakPhysicalFootprintBytes: UInt64 = 100 * 1_024 * 1_024,
        endPhysicalFootprintBytes: UInt64 = 42 * 1_024 * 1_024,
        stopToPlayableMilliseconds: Double = 500,
        p95MainActorSchedulingDelayMilliseconds: Double = 2,
        maximumMainActorSchedulingDelayMilliseconds: Double = 15,
        writtenVideoFrameCount: Int = 3_600,
        sampledVideoFrameCount: Int = 6,
        distinctVideoFrameSignatureCount: Int = 6
    ) -> G2RecordingAcceptanceInput {
        G2RecordingAcceptanceInput(
            requestedDurationSeconds: 60,
            actualDurationSeconds: 60.05,
            requestedFramesPerSecond: 60,
            measuredFramesPerSecond: 60,
            receivedCompleteVideoFrameCount: 600,
            writtenVideoFrameCount: writtenVideoFrameCount,
            videoTrackPresent: true,
            videoHealthy: true,
            droppedFrameCount: 0,
            physicalTracksVerified: true,
            systemAudioRMS: 0.08,
            minimumSystemAudioWindowRMS: 0.07,
            sampledSystemAudioWindowCount: 5,
            systemAudioDurationSeconds: systemAudioDurationSeconds,
            systemAudioObservedTimelineSeconds: systemAudioObservedTimelineSeconds,
            generatedToneDurationSeconds: generatedToneDurationSeconds,
            routerAudioCallbackCount: routerAudioCallbackCount,
            deliveredAudioCallbackCount: deliveredAudioCallbackCount,
            receivedAudioSampleCount: receivedAudioSampleCount,
            appendedAudioSampleCount: appendedAudioSampleCount,
            pendingAudioSampleCount: 0,
            startPhysicalFootprintBytes: 25 * 1_024 * 1_024,
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            endPhysicalFootprintBytes: endPhysicalFootprintBytes,
            stopToPlayableMilliseconds: stopToPlayableMilliseconds,
            p95MainActorSchedulingDelayMilliseconds:
                p95MainActorSchedulingDelayMilliseconds,
            maximumMainActorSchedulingDelayMilliseconds:
                maximumMainActorSchedulingDelayMilliseconds,
            sampledVideoFrameCount: sampledVideoFrameCount,
            distinctVideoFrameSignatureCount: distinctVideoFrameSignatureCount
        )
    }
}
