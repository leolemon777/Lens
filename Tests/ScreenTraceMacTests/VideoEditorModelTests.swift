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
}
