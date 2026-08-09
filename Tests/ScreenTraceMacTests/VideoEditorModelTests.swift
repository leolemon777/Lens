import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class VideoEditorModelTests: XCTestCase {
    func testTimelineEditingSupportsSplitSpeedRemovalUndoAndRedo() throws {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 10,
            hasCameraTrack: true,
            hasMicrophoneTrack: true
        )

        model.split(atOutputTime: 4)
        XCTAssertEqual(model.activeSegments.count, 2)
        XCTAssertEqual(model.activeSegments[0].sourceEndSeconds, 4, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(model.selectedSegment).sourceStartSeconds,
            4,
            accuracy: 0.000_001
        )

        model.setSelectedPlaybackRate(2)
        XCTAssertEqual(model.outputDurationSeconds, 7, accuracy: 0.000_001)
        model.removeSelectedSegment()
        XCTAssertEqual(model.activeSegments.count, 1)
        XCTAssertEqual(model.outputDurationSeconds, 4, accuracy: 0.000_001)
        XCTAssertTrue(model.canUndo)

        model.undo()
        XCTAssertEqual(model.activeSegments.count, 2)
        XCTAssertEqual(model.outputDurationSeconds, 7, accuracy: 0.000_001)
        model.redo()
        XCTAssertEqual(model.activeSegments.count, 1)
        XCTAssertTrue(model.isDirty)
    }

    func testTransitionControlsAreNonDestructiveUndoableAndUpdateOutputDuration() throws {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        model.split(atOutputTime: 4)
        let trailingID = try XCTUnwrap(model.selectedSegmentID)
        let leadingID = try XCTUnwrap(model.activeSegments.first?.id)
        model.selectSegment(leadingID)

        XCTAssertTrue(model.canTransitionFromSelectedSegment)
        XCTAssertEqual(model.selectedTransitionKind, .cut)
        model.setSelectedTransitionKind(.crossDissolve)
        model.setSelectedTransitionDuration(0.8)

        XCTAssertEqual(model.selectedTransitionKind, .crossDissolve)
        XCTAssertEqual(model.selectedTransitionDuration, 0.8)
        XCTAssertEqual(model.outputDurationSeconds, 7.2, accuracy: 0.000_001)
        XCTAssertEqual(model.resolvedTransitions.first?.fromSegmentID, leadingID)
        XCTAssertEqual(model.resolvedTransitions.first?.toSegmentID, trailingID)

        model.undo()
        XCTAssertEqual(model.selectedTransitionDuration, 0.35)
        XCTAssertEqual(model.outputDurationSeconds, 7.65, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.selectedTransitionKind, .cut)
        XCTAssertEqual(model.outputDurationSeconds, 8, accuracy: 0.000_001)

        model.selectSegment(trailingID)
        XCTAssertFalse(model.canTransitionFromSelectedSegment)
        model.setSelectedTransitionKind(.dipToBlack)
        XCTAssertNil(model.selectedSegment?.transitionToNext)
    }

    func testEffectInspectorMutationsRemainUndoableAndRespectMissingCameraTrack() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )

        model.setCameraMotionEnabled(false)
        model.setCursorEnabled(false)
        model.setCanvasPreset(topHex: "#111111", bottomHex: "#222222")
        model.setPresenterEnabled(true)
        model.setDuckingEnabled(false)

        XCTAssertEqual(model.plan.camera.mode, "off")
        XCTAssertEqual(model.plan.cursor.isEnabled, false)
        XCTAssertEqual(model.plan.canvas?.backgroundTopHex, "#111111")
        XCTAssertFalse(model.presenterEnabled)
        XCTAssertEqual(model.plan.audio?.ducksSystemUnderNarration, false)
        XCTAssertTrue(model.isDirty)

        model.resetToAutomaticPlan()
        XCTAssertTrue(model.cameraMotionEnabled)
        XCTAssertTrue(model.cursorEnabled)
        XCTAssertFalse(model.isDirty)

        model.setCameraMotionEnabled(false)
        model.markSaved()
        model.setCursorEnabled(false)
        model.resetToAutomaticPlan()
        XCTAssertTrue(
            model.isDirty,
            "Restoring the originally opened plan must not masquerade as the newer saved plan"
        )
    }

    func testCaptionControlsMaterializeEditableCopyWithoutChangingTranscript() throws {
        let transcript = TranscriptDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 0.5,
                    text: "你好",
                    confidence: 1
                ),
                TranscriptSegment(
                    startSeconds: 0.5,
                    endSeconds: 1,
                    text: "世界！",
                    confidence: 1
                )
            ]
        )
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 4,
            hasCameraTrack: false,
            transcript: transcript
        )

        XCTAssertTrue(model.hasTranscript)
        XCTAssertEqual(model.captionSourceCues.map(\.text), ["你好世界！"])
        model.setCaptionsEnabled(true)
        model.setCaptionStyle(.highContrast)
        model.setCaptionPosition(.top)
        model.setCaptionFontScale(1.35)
        model.setCaptionCueText("你好，屏迹！", at: 0)

        XCTAssertTrue(model.captionsEnabled)
        XCTAssertEqual(model.plan.captions?.style, .highContrast)
        XCTAssertEqual(model.plan.captions?.position, .top)
        XCTAssertEqual(model.plan.captions?.fontScale, 1.35)
        XCTAssertEqual(model.captionSourceCues.first?.text, "你好，屏迹！")
        XCTAssertEqual(transcript.fullText, "你好 世界！")

        model.undo()
        XCTAssertNil(model.plan.captions?.customCues)
        XCTAssertEqual(model.captionSourceCues.first?.text, "你好世界！")
    }

    func testCaptionToggleRequiresTranscript() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 3,
            hasCameraTrack: false
        )

        model.setCaptionsEnabled(true)

        XCTAssertFalse(model.hasTranscript)
        XCTAssertFalse(model.captionsEnabled)
        XCTAssertFalse(model.isDirty)
    }

    func testPresenterDragAndResizeCommitAsOneUndoableInteraction() throws {
        var plan = AutoEditPlan()
        plan.presenterCamera = .init(
            isEnabled: true,
            automaticallyAvoidsContent: false
        )
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 5,
            hasCameraTrack: true
        )

        model.beginPresenterInteraction()
        model.updatePresenterInteraction(
            center: TracePoint(x: 0.6, y: 0.4),
            size: 0.26,
            atOutputTime: 1
        )
        model.updatePresenterInteraction(
            center: TracePoint(x: 0.72, y: 0.32),
            size: 0.31,
            atOutputTime: 1
        )
        model.endPresenterInteraction()

        XCTAssertEqual(try XCTUnwrap(model.plan.presenterCamera?.position).x, 0.72)
        XCTAssertEqual(model.plan.presenterCamera?.size, 0.31)
        XCTAssertTrue(model.canUndo)

        model.undo()

        XCTAssertNil(model.plan.presenterCamera?.position)
        XCTAssertEqual(model.plan.presenterCamera?.size, 0.19)
        XCTAssertFalse(model.canUndo, "A continuous gesture should create only one undo entry")
        XCTAssertTrue(model.canRedo)
    }

    func testPresenterKeyframesUseSourceTimeAcrossCutsAndPlaybackRates() throws {
        let firstID = UUID()
        let secondID = UUID()
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 10,
            segments: [
                VideoEditSegment(
                    id: firstID,
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 4,
                    playbackRate: 2
                ),
                VideoEditSegment(
                    id: secondID,
                    sourceStartSeconds: 6,
                    sourceEndSeconds: 10,
                    playbackRate: 1
                )
            ]
        )
        var plan = AutoEditPlan(timeline: timeline)
        plan.presenterCamera = .init(
            isEnabled: true,
            position: TracePoint(x: 0.25, y: 0.25),
            automaticallyAvoidsContent: false
        )
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 10,
            hasCameraTrack: true
        )

        model.upsertPresenterKeyframe(atOutputTime: 1)
        model.upsertPresenterKeyframe(atOutputTime: 3)

        let keyframes = try XCTUnwrap(model.plan.presenterCamera?.keyframes)
        XCTAssertEqual(keyframes.map(\.sourceTimeSeconds), [2, 7])
        XCTAssertEqual(model.presenterKeyframeOutputTimes, [1, 3])
        XCTAssertEqual(model.previousPresenterKeyframeOutputTime(before: 3), 1)
        XCTAssertEqual(model.nextPresenterKeyframeOutputTime(after: 1), 3)
        XCTAssertTrue(model.hasPresenterKeyframe(nearOutputTime: 3))
        model.setPresenterKeyframeEasing("ease-out", atOutputTime: 3)
        XCTAssertEqual(model.presenterKeyframeEasing(nearOutputTime: 3), "ease-out")
        model.upsertPresenterKeyframe(atOutputTime: 3)
        XCTAssertEqual(
            model.presenterKeyframeEasing(nearOutputTime: 3),
            "ease-out",
            "Updating a keyframe should preserve its selected transition"
        )

        model.beginPresenterInteraction()
        model.updatePresenterInteraction(
            center: TracePoint(x: 0.75, y: 0.28),
            size: 0.27,
            atOutputTime: 3
        )
        model.endPresenterInteraction()

        let updated = try XCTUnwrap(
            model.plan.presenterCamera?.keyframes.first(where: {
                $0.sourceTimeSeconds == 7
            })
        )
        XCTAssertEqual(updated.center.x, 0.75)
        XCTAssertEqual(updated.center.y, 0.28)
        XCTAssertEqual(updated.size, 0.27)
        XCTAssertEqual(model.plan.presenterCamera?.position?.x, 0.25)

        model.removePresenterKeyframe(nearOutputTime: 3)
        XCTAssertEqual(model.presenterKeyframeCount, 1)
    }

    func testDirectManipulationTemporarilySuspendsAutomaticAvoidance() {
        var plan = AutoEditPlan()
        plan.camera.keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1.42,
                center: TracePoint(x: 0.92, y: 0.92),
                easing: "linear",
                reason: .clickFocus
            )
        ]
        plan.presenterCamera = .init(
            isEnabled: true,
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.2
        )
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 3,
            hasCameraTrack: true
        )

        XCTAssertLessThan(model.presenterState(atOutputTime: 0).center.x, 0.5)
        model.beginPresenterInteraction()
        model.updatePresenterInteraction(
            center: TracePoint(x: 0.8, y: 0.2),
            size: 0.2,
            atOutputTime: 0
        )

        XCTAssertGreaterThan(model.presenterState(atOutputTime: 0).center.x, 0.5)
        model.endPresenterInteraction()
        XCTAssertLessThan(model.presenterState(atOutputTime: 0).center.x, 0.5)
        XCTAssertEqual(model.plan.presenterCamera?.position?.x, 0.8)
    }
}
