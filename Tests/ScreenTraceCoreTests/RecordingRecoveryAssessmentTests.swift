import XCTest
@testable import ScreenTraceCore

final class RecordingRecoveryAssessmentTests: XCTestCase {
    private func segment(
        _ index: Int,
        start: Double,
        duration: Double?,
        screen: String,
        microphone: String? = nil
    ) -> RecordingSegment {
        RecordingSegment(
            index: index,
            timelineStartSeconds: start,
            durationSeconds: duration,
            screenRelativePath: screen,
            microphoneRelativePath: microphone
        )
    }

    private func probe(
        _ path: String,
        _ role: TraceAsset.Role,
        _ seconds: Double?
    ) -> RecordingRecoveryProbe {
        RecordingRecoveryProbe(
            relativePath: path,
            role: role,
            measuredSeconds: seconds
        )
    }

    func testHealthyRecordingReportsNothing() {
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 75.23, screen: "raw/screen.mp4")
            ]),
            declaredAssets: [
                TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4")
            ],
            probes: [probe("raw/screen.mp4", .screenVideo, 75.23)]
        )

        XCTAssertFalse(assessment.isDamaged)
        XCTAssertEqual(assessment.recoverableScreenSeconds, 0, accuracy: 0.001)
        XCTAssertFalse(assessment.canRebuildLongerRecording)
    }

    func testContinuationSegmentWithoutADurationIsReportedAsRecoverablePicture() {
        // The real case this was written for: the index recorded no duration
        // for the second segment, so the project presented 3.14 seconds while
        // 12.36 seconds of screen sat on disk.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 3.143, screen: "raw/screen.mp4"),
                segment(
                    1,
                    start: 3.143,
                    duration: nil,
                    screen: "raw/segments/screen-001.mp4"
                )
            ]),
            declaredAssets: [
                TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4")
            ],
            probes: [
                probe("raw/screen.mp4", .screenVideo, 3.143),
                probe("raw/segments/screen-001.mp4", .screenVideoSegment, 9.213)
            ]
        )

        XCTAssertEqual(
            assessment.findings,
            [.unindexedScreenSegment(index: 1, seconds: 9.213)]
        )
        XCTAssertEqual(assessment.presentedScreenSeconds, 3.143, accuracy: 0.001)
        XCTAssertEqual(assessment.availableScreenSeconds, 12.356, accuracy: 0.001)
        XCTAssertEqual(assessment.recoverableScreenSeconds, 9.213, accuracy: 0.001)
        XCTAssertTrue(assessment.canRebuildLongerRecording)
    }

    func testUnwrittenSegmentTooShortToMatterIsNotReported() {
        // A segment opened and abandoned in the same instant is noise, not a
        // recovery opportunity worth putting in front of the user.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 20, screen: "raw/screen.mp4"),
                segment(
                    1,
                    start: 20,
                    duration: nil,
                    screen: "raw/segments/screen-001.mp4"
                )
            ]),
            declaredAssets: [],
            probes: [
                probe("raw/screen.mp4", .screenVideo, 20),
                probe("raw/segments/screen-001.mp4", .screenVideoSegment, 0.04)
            ]
        )

        XCTAssertFalse(assessment.isDamaged)
    }

    // MARK: - Side tracks

    func testOrdinarySideTrackTailIsNotReported() {
        // Devices do not stop on the same instant. Measured across a real
        // library, a camera trailing by a quarter second and a microphone by a
        // few seconds are both routine.
        for tail in [0.24, 1.7, 2.36, 3.67] {
            let screen = 53.73
            let assessment = RecordingRecoveryPlanner.assess(
                index: RecordingSegmentIndex(segments: [
                    segment(0, start: 0, duration: screen, screen: "raw/screen.mp4")
                ]),
                declaredAssets: [],
                probes: [
                    probe("raw/screen.mp4", .screenVideo, screen),
                    probe("raw/microphone.caf", .microphone, screen + tail)
                ]
            )

            XCTAssertFalse(
                assessment.isDamaged,
                "a \(tail)s tail on a \(screen)s recording is not damage"
            )
        }
    }

    func testSideTrackThatOutlivedADeadScreenStreamIsReported() {
        // The screen stream died ten seconds in while the camera and
        // microphone kept writing for another thirty six.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 10.085, screen: "raw/screen.mp4")
            ]),
            declaredAssets: [],
            probes: [
                probe("raw/screen.mp4", .screenVideo, 10.085),
                probe("raw/microphone.caf", .microphone, 46.9),
                probe("raw/camera.mov", .camera, 45.2)
            ]
        )

        XCTAssertEqual(assessment.findings.count, 2)
        // There is no more picture on disk, so a rebuild would not produce a
        // longer recording. Disclosure is the only honest outcome.
        XCTAssertFalse(assessment.canRebuildLongerRecording)
        XCTAssertEqual(assessment.recoverableScreenSeconds, 0, accuracy: 0.001)
    }

    func testBothBoundsMustBeCrossedBeforeReportingASideTrack() {
        // Absolutely large but proportionally small: four seconds on a
        // thirty second recording stays quiet.
        let longRecording = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 31.64, screen: "raw/screen.mp4")
            ]),
            declaredAssets: [],
            probes: [
                probe("raw/screen.mp4", .screenVideo, 31.64),
                probe("raw/microphone.caf", .microphone, 35.8)
            ]
        )
        XCTAssertFalse(longRecording.isDamaged)

        // Proportionally large but absolutely small: two seconds on a five
        // second clip stays quiet too.
        let shortRecording = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 5, screen: "raw/screen.mp4")
            ]),
            declaredAssets: [],
            probes: [
                probe("raw/screen.mp4", .screenVideo, 5),
                probe("raw/microphone.caf", .microphone, 7)
            ]
        )
        XCTAssertFalse(shortRecording.isDamaged)
    }

    func testSideTrackIsComparedAgainstScreenTimeThatExistsNotWhatIsPresented() {
        // Otherwise every unindexed segment would be reported twice: once as
        // lost picture and again as a track that outlived the screen.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 3.143, screen: "raw/screen.mp4"),
                segment(
                    1,
                    start: 3.143,
                    duration: nil,
                    screen: "raw/segments/screen-001.mp4"
                )
            ]),
            declaredAssets: [],
            probes: [
                probe("raw/screen.mp4", .screenVideo, 3.143),
                probe("raw/segments/screen-001.mp4", .screenVideoSegment, 9.213),
                // Far beyond the 3.14s the project presents, but within the
                // 12.36s that exists on disk.
                probe("raw/microphone.caf", .microphone, 12.4)
            ]
        )

        XCTAssertEqual(
            assessment.findings,
            [.unindexedScreenSegment(index: 1, seconds: 9.213)]
        )
    }

    func testPerSegmentSideTrackFilesAreNotComparedAgainstTheWholeRecording() {
        // Assembly clips each segment's audio to that segment's screen
        // duration, so a long source file is not a defect. Reporting it would
        // leave a successfully rebuilt recording still looking broken.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 3.143, screen: "raw/segments/screen-000.mp4"),
                segment(
                    1,
                    start: 3.143,
                    duration: 9.213,
                    screen: "raw/segments/screen-001.mp4"
                )
            ]),
            declaredAssets: [],
            probes: [
                probe("raw/segments/screen-000.mp4", .screenVideoSegment, 3.143),
                probe("raw/segments/screen-001.mp4", .screenVideoSegment, 9.213),
                probe("raw/segments/microphone-001.caf", .microphoneSegment, 28.8),
                probe("raw/microphone.caf", .microphone, 12.356)
            ]
        )

        XCTAssertFalse(assessment.isDamaged)
    }

    // MARK: - Missing files

    func testAFilePromisedByTheManifestButAbsentIsReportedOnce() {
        // System audio is muxed into the screen video, so one absent file can
        // be declared under two roles.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(),
            declaredAssets: [
                TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                TraceAsset(role: .systemAudio, relativePath: "raw/screen.mp4"),
                TraceAsset(role: .camera, relativePath: "raw/camera.mov")
            ],
            probes: [
                probe("raw/screen.mp4", .screenVideo, nil),
                probe("raw/camera.mov", .camera, nil)
            ]
        )

        XCTAssertEqual(assessment.findings.count, 2)
        XCTAssertTrue(assessment.findings.contains(
            .missingDeclaredAsset(relativePath: "raw/screen.mp4", role: .screenVideo)
        ))
        XCTAssertTrue(assessment.findings.contains(
            .missingDeclaredAsset(relativePath: "raw/camera.mov", role: .camera)
        ))
    }

    func testAnAssetThatWasNeverProbedIsNotAssumedMissing() {
        // Event tracks and plans carry no duration and are never probed, so
        // their absence from the probe list must not read as a missing file.
        let assessment = RecordingRecoveryPlanner.assess(
            index: RecordingSegmentIndex(segments: [
                segment(0, start: 0, duration: 12, screen: "raw/screen.mp4")
            ]),
            declaredAssets: [
                TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                TraceAsset(role: .pointerEvents, relativePath: "events/pointer.jsonl")
            ],
            probes: [probe("raw/screen.mp4", .screenVideo, 12)]
        )

        XCTAssertFalse(assessment.isDamaged)
    }
}
