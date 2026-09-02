import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class VideoEditorModelTests: XCTestCase {
    func testVideoAnnotationsUseSourceTimeAndSupportDirectManipulation() throws {
        let timeline = VideoEditTimeline(
            sourceDurationSeconds: 10,
            segments: [
                VideoEditSegment(
                    sourceStartSeconds: 0,
                    sourceEndSeconds: 4,
                    playbackRate: 2
                ),
                VideoEditSegment(
                    sourceStartSeconds: 6,
                    sourceEndSeconds: 10
                )
            ]
        )
        let model = VideoEditorModel(
            plan: AutoEditPlan(timeline: timeline),
            sourceDurationSeconds: 10,
            hasCameraTrack: false
        )
        model.activateVideoAnnotationTool(.arrow)

        XCTAssertTrue(model.commitVideoAnnotationDraft(
            start: LensPoint(x: 0.1, y: 0.2),
            end: LensPoint(x: 0.5, y: 0.6),
            atOutputTime: 1
        ))
        let created = try XCTUnwrap(model.videoAnnotations.first)
        XCTAssertEqual(created.sourceStartSeconds, 2)
        XCTAssertEqual(created.sourceEndSeconds, 4)
        XCTAssertEqual(model.videoAnnotationOutputBands.map(\.range), [
            VideoEditTimeRange(startSeconds: 1, endSeconds: 2)
        ])
        XCTAssertEqual(model.visibleVideoAnnotations(atOutputTime: 1.2).count, 1)
        XCTAssertTrue(model.visibleVideoAnnotations(atOutputTime: 3).isEmpty)

        model.activateVideoAnnotationSelection()
        model.beginVideoAnnotationSelectionInteraction(
            at: LensPoint(x: 0.3, y: 0.4),
            outputTime: 1.2,
            hitTolerance: 0.03,
            handleTolerance: 0.03
        )
        model.updateVideoAnnotationSelectionInteraction(
            to: LensPoint(x: 0.4, y: 0.45)
        )
        model.endVideoAnnotationInteraction()
        let moved = try XCTUnwrap(model.selectedVideoAnnotation)
        XCTAssertEqual(moved.annotation.bounds.x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(moved.annotation.bounds.y, 0.25, accuracy: 0.000_001)

        let movedEnd = try XCTUnwrap(moved.annotation.end)
        model.beginVideoAnnotationSelectionInteraction(
            at: movedEnd,
            outputTime: 1.2,
            hitTolerance: 0.02,
            handleTolerance: 0.04
        )
        model.updateVideoAnnotationSelectionInteraction(
            to: LensPoint(x: 0.82, y: 0.74)
        )
        model.endVideoAnnotationInteraction()
        XCTAssertEqual(model.selectedVideoAnnotation?.annotation.end?.x, 0.82)
        XCTAssertEqual(model.selectedVideoAnnotation?.annotation.end?.y, 0.74)

        model.undo()
        XCTAssertEqual(model.selectedVideoAnnotation?.annotation.end, moved.annotation.end)
        model.undo()
        XCTAssertEqual(model.selectedVideoAnnotation?.annotation.bounds, created.annotation.bounds)
        model.undo()
        XCTAssertTrue(model.videoAnnotations.isEmpty)
    }

    func testVideoAnnotationInspectorChangesAreUndoableAndNormalized() throws {
        let item = VideoAnnotation(
            annotation: ScreenshotAnnotation(
                kind: .text,
                bounds: LensRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1),
                text: "Old"
            ),
            sourceStartSeconds: 4.8,
            sourceEndSeconds: 9
        )
        let model = VideoEditorModel(
            plan: AutoEditPlan(videoAnnotations: [item]),
            sourceDurationSeconds: 5,
            hasCameraTrack: false
        )
        model.activateVideoAnnotationSelection()
        model.beginVideoAnnotationSelectionInteraction(
            at: LensPoint(x: 0.3, y: 0.25),
            outputTime: 4.85,
            hitTolerance: 0.02,
            handleTolerance: 0.01
        )
        model.endVideoAnnotationInteraction()

        let normalized = try XCTUnwrap(model.selectedVideoAnnotation)
        XCTAssertEqual(normalized.sourceEndSeconds, 5)
        model.setSelectedVideoAnnotationDuration(3)
        XCTAssertEqual(model.selectedVideoAnnotation?.sourceEndSeconds, 5)
        model.setSelectedVideoAnnotationFadeDuration(0.4)
        model.setVideoAnnotationColor(.blue)
        model.videoAnnotationTextDraft = "Updated"
        model.applyVideoAnnotationTextDraft()

        XCTAssertEqual(model.selectedVideoAnnotation?.fadeDurationSeconds, 0.4)
        XCTAssertEqual(model.selectedVideoAnnotation?.annotation.style.color, .blue)
        XCTAssertEqual(model.selectedVideoAnnotation?.annotation.text, "Updated")
        XCTAssertTrue(model.isDirty)
    }

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
        model.setCameraMotionBlurStrength(0.7)
        model.setCursorEnabled(false)
        model.setCursorAppearance(.minimalDot)
        model.setCursorAccentColorHex("a3e635")
        model.setCursorMotionEffect(.trail)
        model.setCursorMotionEffectStrength(0.66)
        model.setCursorSmoothingWindowMilliseconds(36)
        model.setCursorHidesWhenIdle(false)
        model.setClickEffect(.spotlight)
        model.setClickEffectStrength(0.74)
        model.setClickPulseScale(1.4)
        model.setClickPulseDuration(0.72)
        model.setClickPulseColorHex("#FF684D")
        model.setCanvasShadowOpacity(0.44)
        model.setCanvasPreset(topHex: "#111111", bottomHex: "#222222")
        model.setPresenterEnabled(true)
        model.setMicrophoneNoiseReductionEnabled(false)
        model.setNoiseReductionAmount(0.8)
        model.setLoudnessNormalizationEnabled(false)
        model.setTargetLoudnessLUFS(-20)
        model.setDuckingEnabled(false)

        XCTAssertEqual(model.plan.camera.mode, "off")
        XCTAssertEqual(model.plan.camera.motionBlurStrength, 0.7)
        XCTAssertEqual(model.plan.cursor.isEnabled, false)
        XCTAssertEqual(model.plan.cursor.appearance, .minimalDot)
        XCTAssertEqual(model.plan.cursor.accentColorHex, "#A3E635")
        XCTAssertEqual(model.plan.cursor.motionEffect, .trail)
        XCTAssertEqual(model.plan.cursor.motionEffectStrength, 0.66)
        XCTAssertEqual(model.plan.cursor.smoothingWindowMilliseconds, 36)
        XCTAssertFalse(model.plan.cursor.hidesWhenIdle)
        XCTAssertEqual(model.plan.interaction?.clickEffect, .spotlight)
        XCTAssertEqual(model.plan.interaction?.clickEffectStrength, 0.74)
        XCTAssertEqual(model.plan.interaction?.clickPulseScale, 1.4)
        XCTAssertEqual(model.plan.interaction?.clickPulseDuration, 0.72)
        XCTAssertEqual(model.plan.interaction?.clickPulseColorHex, "#FF684D")
        XCTAssertEqual(model.plan.canvas?.shadowOpacity, 0.44)
        XCTAssertEqual(model.plan.canvas?.backgroundTopHex, "#111111")
        XCTAssertFalse(model.presenterEnabled)
        XCTAssertFalse(model.microphoneNoiseReductionEnabled)
        XCTAssertEqual(model.plan.audio?.noiseReductionAmount, 0.8)
        XCTAssertFalse(model.loudnessNormalizationEnabled)
        XCTAssertEqual(model.plan.audio?.targetLoudnessLUFS, -20)
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

    func testManualCameraFocusUsesSourceTimeAndIsUndoable() throws {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        model.manualCameraScale = 2.2
        model.manualCameraHoldSeconds = 0.8
        model.activateManualCameraFocusEditing()

        XCTAssertTrue(model.addManualCameraFocus(
            center: LensPoint(x: 0.8, y: 0.2),
            atOutputTime: 2
        ))

        XCTAssertFalse(model.isManualCameraFocusEditing)
        XCTAssertEqual(model.manualCameraFocusCount, 1)
        XCTAssertEqual(model.manualCameraFocusOutputTimes, [2])
        let focus = try XCTUnwrap(model.plan.camera.keyframes.first {
            $0.reason == .manualFocus
        })
        XCTAssertEqual(focus.scale, 2.2, accuracy: 0.000_1)
        XCTAssertLessThan(focus.center.x, 0.8)
        XCTAssertGreaterThan(focus.center.y, 0.2)

        model.undo()
        XCTAssertEqual(model.manualCameraFocusCount, 0)
        model.redo()
        XCTAssertEqual(model.manualCameraFocusCount, 1)
        model.clearManualCameraFocuses()
        XCTAssertEqual(model.manualCameraFocusCount, 0)
        model.undo()
        XCTAssertEqual(model.manualCameraFocusCount, 1)
    }

    func testCompletedOlderPreviewDoesNotMarkNewerInspectorChangesAsSaved() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        model.setAutomaticZoomScale(1.8)
        let planBeingRendered = model.plan
        model.setCameraMotionBlurStrength(0.42)

        model.markSaved(planBeingRendered)

        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.plan.camera.resolvedZoomScale, 1.8, accuracy: 0.000_1)
        XCTAssertEqual(model.plan.camera.motionBlurStrength, 0.42, accuracy: 0.000_1)
        model.resetToAutomaticPlan()
        XCTAssertTrue(
            model.isDirty,
            "The completed older render must remain the saved baseline"
        )
    }

    func testPlanPersistenceCanPrecedePreviewWithoutClearingDirtyState() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        model.setAutomaticZoomScale(1.8)
        let persistedPlan = model.plan

        model.markPlanPersisted(persistedPlan)

        XCTAssertTrue(model.isPlanPersisted)
        XCTAssertTrue(model.isDirty, "preview is still stale until rendering completes")

        model.markSaved(persistedPlan)
        XCTAssertTrue(model.isPlanPersisted)
        XCTAssertFalse(model.isDirty)
    }

    func testBackgroundPreviewAdoptionRequiresUntouchedMatchingPlan() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        let renderedPlan = model.plan

        XCTAssertTrue(model.canAdoptBackgroundPreview(renderedPlan: renderedPlan))

        var stalePlan = renderedPlan
        stalePlan.camera.motionBlurStrength = 0.8
        XCTAssertFalse(model.canAdoptBackgroundPreview(renderedPlan: stalePlan))

        model.beginProcessing()
        XCTAssertFalse(model.canAdoptBackgroundPreview(renderedPlan: renderedPlan))
        model.endProcessing()

        model.beginRegeneratingCamera()
        XCTAssertFalse(model.canAdoptBackgroundPreview(renderedPlan: renderedPlan))
        model.endRegeneratingCamera()

        model.setCameraMotionBlurStrength(0.4)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.canAdoptBackgroundPreview(renderedPlan: renderedPlan))
    }

    func testAutomaticCameraRegenerationPreservesManualFramesAndUndoesAsOneChange() {
        var plan = AutoEditPlan()
        plan.camera.zoomScale = nil
        plan.camera.zoomIntensity = 0.84
        let oldAutomatic = AutoEditPlan.CameraKeyframe(
            time: 1,
            scale: 1.4,
            center: LensPoint(x: 0.3, y: 0.4),
            easing: "cinematic",
            reason: .clickFocus
        )
        let manual = AutoEditPlan.CameraKeyframe(
            time: 3,
            scale: 2.2,
            center: LensPoint(x: 0.7, y: 0.5),
            easing: "cinematic",
            reason: .manualFocus
        )
        plan.camera.keyframes = [oldAutomatic, manual]
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        let regenerated = AutoEditPlan.CameraKeyframe(
            time: 2,
            scale: 1.7,
            center: LensPoint(x: 0.5, y: 0.5),
            easing: "cinematic",
            reason: .pointerFollow
        )

        model.replaceAutomaticCameraKeyframes(with: [regenerated])

        XCTAssertFalse(model.plan.camera.keyframes.contains(oldAutomatic))
        XCTAssertTrue(model.plan.camera.keyframes.contains(regenerated))
        XCTAssertTrue(model.plan.camera.keyframes.contains(manual))
        XCTAssertEqual(try! XCTUnwrap(model.plan.camera.zoomScale), 2.16, accuracy: 0.000_1)
        XCTAssertEqual(model.plan.camera.zoomIntensity, 0.42, accuracy: 0.000_1)
        XCTAssertEqual(
            EffectTimeline.effectiveCameraState(at: 2, camera: model.plan.camera).scale,
            1.7,
            accuracy: 0.000_1
        )
        XCTAssertTrue(model.isDirty)
        model.undo()
        XCTAssertEqual(model.plan.camera.keyframes, [oldAutomatic, manual])
        XCTAssertNil(model.plan.camera.zoomScale)
        XCTAssertEqual(model.plan.camera.zoomIntensity, 0.84, accuracy: 0.000_1)
    }

    func testChangingAutomaticZoomImmediatelyRescalesAutomaticKeyframes() throws {
        var plan = AutoEditPlan()
        plan.camera.zoomScale = nil
        plan.camera.zoomIntensity = 0.84
        plan.camera.keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 1.58,
                center: LensPoint(x: 0.3, y: 0.5),
                easing: "cinematic",
                reason: .clickFocus
            ),
            AutoEditPlan.CameraKeyframe(
                time: 3,
                scale: 2.2,
                center: LensPoint(x: 0.7, y: 0.5),
                easing: "cinematic",
                reason: .manualFocus
            )
        ]
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )

        model.setAutomaticZoomScale(1.60)

        XCTAssertEqual(model.plan.camera.zoomScale, 1.60)
        XCTAssertEqual(model.plan.camera.zoomIntensity, 0.42, accuracy: 0.000_1)
        XCTAssertEqual(
            model.plan.camera.keyframes.first { $0.reason == .clickFocus }?.scale,
            1.60
        )
        XCTAssertEqual(
            model.plan.camera.keyframes.first { $0.reason == .manualFocus }?.scale,
            2.2
        )
        XCTAssertEqual(
            EffectTimeline.effectiveCameraState(at: 1, camera: model.plan.camera).scale,
            1.60,
            accuracy: 0.000_1
        )
        model.undo()
        XCTAssertNil(model.plan.camera.zoomScale)
        XCTAssertEqual(model.plan.camera.zoomIntensity, 0.84, accuracy: 0.000_1)
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
        model.setCaptionCueText("你好，Lens！", at: 0)

        XCTAssertTrue(model.captionsEnabled)
        XCTAssertEqual(model.plan.captions?.style, .highContrast)
        XCTAssertEqual(model.plan.captions?.position, .top)
        XCTAssertEqual(model.plan.captions?.fontScale, 1.35)
        XCTAssertEqual(model.captionSourceCues.first?.text, "你好，Lens！")
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

    func testCaptionTimingSplitMergeDeleteAndExportPresetAreUndoable() throws {
        let transcript = TranscriptDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [TranscriptSegment(
                startSeconds: 0,
                endSeconds: 3,
                text: "原始转写不会改变",
                confidence: 1
            )]
        )
        var plan = AutoEditPlan(timeline: VideoEditTimeline(
            sourceDurationSeconds: 4,
            segments: [VideoEditSegment(
                sourceStartSeconds: 0,
                sourceEndSeconds: 4,
                playbackRate: 2
            )]
        ))
        plan.captions?.customCues = [
            CaptionSourceCue(
                sourceStartSeconds: 0,
                sourceEndSeconds: 2,
                text: "先录制，然后整理"
            ),
            CaptionSourceCue(
                sourceStartSeconds: 2,
                sourceEndSeconds: 3,
                text: "完成"
            )
        ]
        let model = VideoEditorModel(
            plan: plan,
            sourceDurationSeconds: 4,
            hasCameraTrack: false,
            transcript: transcript
        )

        model.selectCaptionCue(at: 0)
        XCTAssertEqual(model.primaryCaptionOutputTime(at: 0), 0)
        XCTAssertTrue(model.canSplitCaptionCue(at: 0, atOutputTime: 0.5))
        XCTAssertTrue(model.splitCaptionCue(at: 0, atOutputTime: 0.5))
        XCTAssertEqual(model.captionSourceCues.count, 3)
        XCTAssertEqual(model.selectedCaptionCueIndex, 1)
        XCTAssertEqual(model.captionSourceCues[0].sourceEndSeconds, 1)
        XCTAssertEqual(model.captionSourceCues[1].sourceStartSeconds, 1)

        XCTAssertTrue(model.mergeCaptionCueWithNext(at: 0))
        XCTAssertEqual(model.captionSourceCues.count, 2)
        XCTAssertEqual(model.captionSourceCues[0].text, "先录制，然后整理")
        model.setCaptionCueEnd(1.6, at: 0)
        XCTAssertEqual(model.captionSourceCues[0].sourceEndSeconds, 1.6)
        model.deleteCaptionCue(at: 1)
        XCTAssertEqual(model.captionSourceCues.count, 1)

        model.setExportPreset(.compact)
        XCTAssertEqual(model.exportPreset, .compact)
        model.undo()
        XCTAssertEqual(model.exportPreset, .balanced)
        model.undo()
        XCTAssertEqual(model.captionSourceCues.count, 2)
        XCTAssertEqual(transcript.fullText, "原始转写不会改变")
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
            center: LensPoint(x: 0.6, y: 0.4),
            size: 0.26,
            atOutputTime: 1
        )
        model.updatePresenterInteraction(
            center: LensPoint(x: 0.72, y: 0.32),
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

    func testContinuousInspectorSliderChangesCommitAsOneUndoableEdit() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 5,
            hasCameraTrack: false
        )
        let originalMargin = model.plan.canvas?.margin ?? 0.055

        model.beginContinuousEdit()
        model.setCanvasMargin(0.08)
        model.setCanvasMargin(0.11)
        model.setCanvasMargin(0.14)
        model.endContinuousEdit()

        XCTAssertEqual(model.plan.canvas?.margin ?? 0, 0.14, accuracy: 0.000_1)
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.plan.canvas?.margin ?? 0.055, originalMargin, accuracy: 0.000_1)
        XCTAssertFalse(model.canUndo)
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
            position: LensPoint(x: 0.25, y: 0.25),
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
            center: LensPoint(x: 0.75, y: 0.28),
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
                center: LensPoint(x: 0.92, y: 0.92),
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
            center: LensPoint(x: 0.8, y: 0.2),
            size: 0.2,
            atOutputTime: 0
        )

        XCTAssertGreaterThan(model.presenterState(atOutputTime: 0).center.x, 0.5)
        model.endPresenterInteraction()
        XCTAssertLessThan(model.presenterState(atOutputTime: 0).center.x, 0.5)
        XCTAssertEqual(model.plan.presenterCamera?.position?.x, 0.8)
    }

    // MARK: - 旁白清理

    private func narrationTrimModel() -> VideoEditorModel {
        VideoEditorModel(
            plan: AutoEditPlan(
                timeline: VideoEditTimeline(sourceDurationSeconds: 12),
                narrationTrims: [
                    NarrationTrimSuggestion(
                        kind: .silence,
                        startSeconds: 4,
                        endSeconds: 6
                    ),
                    NarrationTrimSuggestion(
                        kind: .fillerWord,
                        startSeconds: 8,
                        endSeconds: 8.4,
                        label: "嗯"
                    )
                ]
            ),
            sourceDurationSeconds: 12,
            hasCameraTrack: false
        )
    }

    func testAcceptNarrationTrimRemovesRangeAndMarksDirty() throws {
        let model = narrationTrimModel()
        let silence = try XCTUnwrap(model.narrationTrimSuggestions.first)

        model.acceptNarrationTrim(silence.id)

        XCTAssertEqual(model.narrationTrimSuggestions.first?.status, .accepted)
        XCTAssertEqual(model.outputDurationSeconds, 10, accuracy: 0.000_001)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canUndo)

        model.undo()
        XCTAssertEqual(model.outputDurationSeconds, 12, accuracy: 0.000_001)
        XCTAssertEqual(model.narrationTrimSuggestions.first?.status, .pending)
    }

    func testAcceptAllPendingNarrationTrimsAppliesEveryRange() {
        let model = narrationTrimModel()

        model.acceptAllPendingNarrationTrims()

        XCTAssertTrue(model.pendingNarrationTrims.isEmpty)
        XCTAssertTrue(model.narrationTrimSuggestions.allSatisfy { $0.status == .accepted })
        XCTAssertEqual(model.outputDurationSeconds, 9.6, accuracy: 0.000_001)
    }

    func testRejectAndRestoreOnlyChangeReviewStatus() throws {
        let model = narrationTrimModel()
        let filler = try XCTUnwrap(
            model.narrationTrimSuggestions.first { $0.kind == .fillerWord }
        )

        model.rejectNarrationTrim(filler.id)
        XCTAssertEqual(
            model.narrationTrimSuggestions.first { $0.kind == .fillerWord }?.status,
            .rejected
        )
        XCTAssertEqual(model.outputDurationSeconds, 12, accuracy: 0.000_001)
        XCTAssertEqual(model.pendingNarrationTrims.count, 1)

        model.restoreNarrationTrim(filler.id)
        XCTAssertEqual(
            model.narrationTrimSuggestions.first { $0.kind == .fillerWord }?.status,
            .pending
        )
    }

    func testDetectionSkipsWhenPlanAlreadyCarriesSuggestionsOrNoTrack() {
        // A plan that already carries suggestions must not re-run detection,
        // and a missing microphone URL leaves the state ready without work.
        let model = narrationTrimModel()
        XCTAssertEqual(model.narrationTrimDetectionState, .ready)

        let bare = VideoEditorModel(
            plan: AutoEditPlan(timeline: VideoEditTimeline(sourceDurationSeconds: 5)),
            sourceDurationSeconds: 5,
            hasCameraTrack: false,
            hasMicrophoneTrack: false
        )
        XCTAssertEqual(bare.narrationTrimDetectionState, .ready)
        XCTAssertTrue(bare.narrationTrimSuggestions.isEmpty)
    }

    // MARK: - 一键人声增强

    func testVoiceEnhancementTogglesAllNarrationPolishAtOnce() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 5,
            hasCameraTrack: false
        )

        // Default Audio() enables all three switches at standard strength.
        XCTAssertEqual(model.appliedVoiceEnhancementLevel, .standard)

        model.setVoiceEnhancement(nil)
        XCTAssertNil(model.appliedVoiceEnhancementLevel)
        let disabled = model.plan.audio
        XCTAssertFalse(disabled?.reducesMicrophoneNoise ?? true)
        XCTAssertFalse(disabled?.normalizesLoudness ?? true)
        XCTAssertFalse(disabled?.ducksSystemUnderNarration ?? true)

        model.setVoiceEnhancement(.strong)
        XCTAssertEqual(model.appliedVoiceEnhancementLevel, .strong)
        XCTAssertEqual(model.plan.audio?.noiseReductionAmount ?? 0, 0.75, accuracy: 0.000_1)
        XCTAssertEqual(model.plan.audio?.targetLoudnessLUFS ?? 0, -14, accuracy: 0.000_1)
    }

    func testUnprocessedAuditionRestoresPreviousAudio() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 5,
            hasCameraTrack: false
        )
        model.setVoiceEnhancement(.light)

        model.setUnprocessedAudition(true)
        XCTAssertTrue(model.isAuditioningUnprocessedAudio)
        XCTAssertFalse(model.plan.audio?.reducesMicrophoneNoise ?? true)

        model.setUnprocessedAudition(false)
        XCTAssertFalse(model.isAuditioningUnprocessedAudio)
        XCTAssertEqual(model.appliedVoiceEnhancementLevel, .light)
        XCTAssertEqual(model.plan.audio?.noiseReductionAmount ?? 0, 0.4, accuracy: 0.000_1)
    }

    func testEscapeExitsAnnotationAndFocusModesWithoutChangingThePlan() {
        let model = VideoEditorModel(
            plan: AutoEditPlan(),
            sourceDurationSeconds: 8,
            hasCameraTrack: false
        )
        model.activateVideoAnnotationTool(.arrow)
        XCTAssertTrue(model.isVideoAnnotationEditing)
        XCTAssertTrue(model.escapeCurrentMode())
        XCTAssertFalse(model.isVideoAnnotationEditing)
        XCTAssertFalse(model.escapeCurrentMode())

        model.activateManualCameraFocusEditing()
        XCTAssertTrue(model.isManualCameraFocusEditing)
        XCTAssertTrue(model.escapeCurrentMode())
        XCTAssertFalse(model.isManualCameraFocusEditing)
    }
}
