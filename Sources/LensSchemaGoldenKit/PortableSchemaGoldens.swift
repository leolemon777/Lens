import CoreGraphics
import Foundation
import LensCore

/// Canonical byte-level samples of every portable `.lens` document.
///
/// These are the cross-language contract. A non-Swift implementation of the
/// open project format is correct when it round-trips each sample byte for
/// byte under the canonical encoding described below.
///
/// The samples are deliberately *fully populated*: every optional field is
/// present so an implementer can see the complete surface. Real projects omit
/// optional fields freely, and readers must tolerate that.
public enum PortableSchemaGoldens {
    /// Frozen instant used by every sample: `2026-01-01T00:00:00Z`.
    public static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)

    /// The exact encoder configuration `LensProjectStore` writes with.
    ///
    /// - `sortedKeys` makes object key order deterministic (lexicographic by
    ///   UTF-8 code unit), which is what makes byte comparison meaningful.
    /// - `withoutEscapingSlashes` keeps `/` literal inside relative paths.
    /// - `prettyPrinted` uses two-space indent and `" : "`-free `": "` separators.
    /// - `.iso8601` renders `Date` as `YYYY-MM-DDThh:mm:ssZ` with no fractional
    ///   seconds. Only manifest/ocr/transcript/insights carry dates.
    public static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Compact, key-sorted encoding used for *cross-language* byte comparison.
    ///
    /// `canonicalEncoder()` is pretty-printed, and Swift's pretty printer emits
    /// `"key" : value` — a space on *both* sides of the colon. Practically every
    /// other JSON library (serde_json, System.Text.Json, Python) emits
    /// `"key": value`, so byte equality against the on-disk form is not
    /// achievable outside Swift. Compact output has no such ambiguity, so this
    /// is the form a conformance test should compare.
    public static func canonicalCompactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func canonicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Deterministic identifiers so regenerating never produces a diff.
    private static func uuid(_ suffix: Int) -> UUID {
        let hex = String(format: "%012x", suffix)
        return UUID(uuidString: "00000000-0000-4000-8000-\(hex)")!
    }

    // MARK: - Samples

    public static func manifest() -> LensManifest {
        LensManifest(
            id: uuid(1),
            kind: .recording,
            createdAt: referenceDate,
            title: "Golden recording",
            state: .ready,
            durationSeconds: 12.5,
            dimensions: LensDimensions(width: 2560, height: 1440),
            captureSource: LensCaptureMetadata(
                mode: .display,
                displayID: 1,
                windowID: 42,
                globalBounds: LensRect(x: 0, y: 0, width: 2560, height: 1440),
                sourceRect: LensRect(x: 100, y: 80, width: 1280, height: 720),
                windowTitle: "Golden window",
                applicationName: "GoldenApp",
                framesPerSecond: 60,
                requestedFramesPerSecond: 60,
                measuredFramesPerSecond: 59.94,
                p95FrameIntervalMilliseconds: 16.7,
                droppedFrameCount: 0
            ),
            screenshotCaptureSource: ScreenshotCaptureMetadata(
                mode: .region,
                displayID: 1,
                windowIDs: [42, 43],
                globalBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                sourceRect: CGRect(x: 100, y: 80, width: 1280, height: 720),
                windowTitle: "Golden window",
                applicationName: "GoldenApp"
            ),
            assets: [
                LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                LensAsset(role: .microphone, relativePath: "raw/microphone.caf"),
                LensAsset(role: .camera, relativePath: "raw/camera.mov"),
                LensAsset(role: .pointerEvents, relativePath: "events/pointer.jsonl"),
                LensAsset(role: .editPlan, relativePath: "edits/edit-plan.json"),
                LensAsset(role: .renderedVideo, relativePath: "previews/auto.mp4")
            ]
        )
    }

    public static func autoEditPlan() -> AutoEditPlan {
        AutoEditPlan(
            preset: "natural",
            cursor: AutoEditPlan.Cursor(
                isEnabled: true,
                appearance: .recorded,
                accentColorHex: "#5BD6FF",
                motionEffect: .halo,
                motionEffectStrength: 0.42,
                smoothing: 0.72,
                smoothingWindowMilliseconds: 48,
                followStyle: .smooth,
                scale: 1.15,
                hidesWhenIdle: false,
                keyframes: [
                    AutoEditPlan.CursorKeyframe(
                        time: 0,
                        position: LensPoint(x: 0.2, y: 0.3),
                        kind: .moved
                    ),
                    AutoEditPlan.CursorKeyframe(
                        time: 1.5,
                        position: LensPoint(x: 0.6, y: 0.55),
                        kind: .dragged
                    )
                ],
                shapeKeyframes: [
                    AutoEditPlan.CursorShapeKeyframe(time: 0, shape: .arrow),
                    AutoEditPlan.CursorShapeKeyframe(time: 1.5, shape: .pointingHand)
                ]
            ),
            camera: AutoEditPlan.Camera(
                mode: "event-driven",
                zoomIntensity: 0.42,
                followPointer: true,
                clickToZoom: true,
                zoomScale: 1.28,
                generationStrength: .balanced,
                motionBlurStrength: 0.12,
                keyframes: [
                    AutoEditPlan.CameraKeyframe(
                        time: 0,
                        scale: 1,
                        center: LensPoint(x: 0.5, y: 0.5),
                        easing: "spring-gentle",
                        reason: .baseline
                    ),
                    AutoEditPlan.CameraKeyframe(
                        time: 2.4,
                        scale: 1.28,
                        center: LensPoint(x: 0.62, y: 0.41),
                        easing: "spring-gentle",
                        reason: .clickFocus
                    )
                ]
            ),
            presenterCamera: AutoEditPlan.PresenterCamera(
                isEnabled: true,
                shape: .circle,
                anchor: .bottomTrailing,
                size: 0.19,
                margin: 0.035,
                cornerRadius: 0.08,
                isMirrored: true,
                shadowOpacity: 0.30,
                position: LensPoint(x: 0.82, y: 0.78),
                automaticallyAvoidsContent: true,
                keyframes: [
                    AutoEditPlan.PresenterCameraKeyframe(
                        sourceTimeSeconds: 0,
                        center: LensPoint(x: 0.82, y: 0.78),
                        size: 0.19,
                        easing: "spring-gentle"
                    )
                ]
            ),
            audio: AutoEditPlan.Audio(),
            canvas: AutoEditPlan.Canvas(),
            interaction: AutoEditPlan.Interaction(
                showsClickPulse: true,
                clickEffect: .ripple,
                clickEffectStrength: 1,
                clickPulseScale: 1.25,
                clickPulseColorHex: "#FF684D",
                clickPulseDuration: 0.62,
                clickPulses: [
                    AutoEditPlan.ClickPulse(
                        time: 2.4,
                        position: LensPoint(x: 0.62, y: 0.41),
                        button: .left,
                        duration: 0.62
                    )
                ],
                showsKeystrokes: true,
                keystrokes: [
                    AutoEditPlan.KeystrokeDisplay(
                        time: 3.1,
                        text: "⌘S",
                        holdSeconds: 1.15
                    )
                ]
            ),
            timeline: VideoEditTimeline(
                sourceDurationSeconds: 12.5,
                segments: [
                    VideoEditSegment(
                        id: uuid(2),
                        sourceStartSeconds: 0,
                        sourceEndSeconds: 6,
                        playbackRate: 1,
                        isEnabled: true,
                        transitionToNext: VideoEditTransition(
                            kind: .crossDissolve,
                            durationSeconds: 0.35
                        )
                    ),
                    VideoEditSegment(
                        id: uuid(3),
                        sourceStartSeconds: 6,
                        sourceEndSeconds: 12.5,
                        playbackRate: 1.5,
                        isEnabled: true,
                        transitionToNext: nil
                    )
                ]
            ),
            captions: AutoEditPlan.Captions(
                isEnabled: true,
                style: .glass,
                position: .bottom,
                fontScale: 1,
                maxCharactersPerCue: 28,
                verticalMargin: 0.065,
                highlightsSpokenWords: true,
                customCues: [
                    CaptionSourceCue(
                        sourceStartSeconds: 0.4,
                        sourceEndSeconds: 2.8,
                        text: "这是一条黄金字幕。"
                    )
                ]
            ),
            videoAnnotations: [
                VideoAnnotation(
                    annotation: ScreenshotAnnotation(
                        id: uuid(4),
                        kind: .rectangle,
                        bounds: LensRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
                        start: LensPoint(x: 0.1, y: 0.1),
                        end: LensPoint(x: 0.4, y: 0.3),
                        points: [LensPoint(x: 0.1, y: 0.1), LensPoint(x: 0.4, y: 0.3)],
                        text: "Golden annotation",
                        style: ScreenshotAnnotationStyle(
                            lineWidth: 0.006,
                            fontSize: 0.045,
                            color: .red,
                            gradientEndColor: .orange,
                            fillColor: .yellow,
                            intensity: 0.035
                        )
                    ),
                    sourceStartSeconds: 1,
                    sourceEndSeconds: 4,
                    fadeDurationSeconds: 0.16
                )
            ],
            export: AutoEditPlan.Export(
                preset: .balanced,
                aspectRatio: .vertical9x16
            ),
            narrationTrims: [
                NarrationTrimSuggestion(
                    id: uuid(5),
                    kind: .silence,
                    startSeconds: 4.2,
                    endSeconds: 5.1,
                    label: nil,
                    status: .pending
                ),
                NarrationTrimSuggestion(
                    id: uuid(6),
                    kind: .fillerWord,
                    startSeconds: 7.4,
                    endSeconds: 7.7,
                    label: "嗯",
                    status: .accepted
                )
            ]
        )
    }

    public static func screenshotEditPlan() -> ScreenshotEditPlan {
        ScreenshotEditPlan(
            sourceDimensions: LensDimensions(width: 1280, height: 720),
            annotations: [
                ScreenshotAnnotation(
                    id: uuid(7),
                    kind: .arrow,
                    bounds: LensRect(x: 0.2, y: 0.25, width: 0.3, height: 0.15),
                    start: LensPoint(x: 0.2, y: 0.25),
                    end: LensPoint(x: 0.5, y: 0.4),
                    points: nil,
                    text: nil,
                    style: ScreenshotAnnotationStyle()
                ),
                ScreenshotAnnotation(
                    id: uuid(8),
                    kind: .text,
                    bounds: LensRect(x: 0.55, y: 0.6, width: 0.3, height: 0.1),
                    start: nil,
                    end: nil,
                    points: nil,
                    text: "标注文字",
                    style: ScreenshotAnnotationStyle(
                        lineWidth: 0.004,
                        fontSize: 0.05,
                        color: .blue,
                        gradientEndColor: nil,
                        fillColor: nil,
                        intensity: 0.035
                    )
                )
            ],
            canvasStyle: ScreenshotCanvasStyle()
        )
    }

    public static func recordingSegments() -> RecordingSegmentIndex {
        RecordingSegmentIndex(segments: [
            RecordingSegment(
                index: 0,
                timelineStartSeconds: 0,
                durationSeconds: 6,
                screenRelativePath: "raw/segments/screen-0.mp4",
                microphoneRelativePath: "raw/segments/microphone-0.caf",
                cameraRelativePath: "raw/segments/camera-0.mov"
            ),
            RecordingSegment(
                index: 1,
                timelineStartSeconds: 6,
                durationSeconds: 6.5,
                screenRelativePath: "raw/segments/screen-1.mp4",
                microphoneRelativePath: "raw/segments/microphone-1.caf",
                cameraRelativePath: "raw/segments/camera-1.mov"
            )
        ])
    }

    public static func scrollingCapture() -> ScrollingCapturePlan {
        ScrollingCapturePlan(
            displayID: 1,
            sourceRect: LensRect(x: 100, y: 80, width: 800, height: 600),
            viewportDimensions: LensDimensions(width: 1600, height: 1200),
            outputDimensions: LensDimensions(width: 1600, height: 3400),
            frames: [
                ScrollingCaptureFrame(
                    index: 0,
                    relativePath: "raw/scrolling/frame-0.png",
                    verticalOffsetPixels: 0,
                    appendedHeightPixels: 1200,
                    overlapDifference: 0
                ),
                ScrollingCaptureFrame(
                    index: 1,
                    relativePath: "raw/scrolling/frame-1.png",
                    verticalOffsetPixels: 1200,
                    appendedHeightPixels: 1100,
                    overlapDifference: 0.012
                )
            ]
        )
    }

    public static func ocr() -> OCRDocument {
        OCRDocument(
            engine: "golden-ocr",
            recognizedAt: referenceDate,
            recognitionLanguages: ["zh-Hans", "en-US"],
            fullText: "第一行\nsecond line",
            blocks: [
                OCRTextBlock(
                    text: "第一行",
                    confidence: 0.97,
                    normalizedBounds: LensRect(x: 0.1, y: 0.1, width: 0.4, height: 0.06)
                ),
                OCRTextBlock(
                    text: "second line",
                    confidence: 0.91,
                    normalizedBounds: LensRect(x: 0.1, y: 0.2, width: 0.5, height: 0.06)
                )
            ]
        )
    }

    public static func transcript() -> TranscriptDocument {
        TranscriptDocument(
            engine: "golden-speech",
            generatedAt: referenceDate,
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .microphone,
            fullText: "这是第一句。 这是第二句。",
            segments: [
                TranscriptSegment(
                    startSeconds: 0.4,
                    endSeconds: 2.8,
                    text: "这是第一句。",
                    confidence: 0.94
                ),
                TranscriptSegment(
                    startSeconds: 3.1,
                    endSeconds: 5.6,
                    text: "这是第二句。",
                    confidence: 0.89
                )
            ]
        )
    }

    public static func insights() -> LensInsightsDocument {
        LensInsightsDocument(
            engine: "golden-organizer",
            generatedAt: referenceDate,
            suggestedTitle: "黄金录屏",
            summary: "这是一段用于跨语言校验的摘要。",
            tags: ["演示", "golden"],
            keyPoints: ["第一个要点", "第二个要点"],
            chapters: [
                LensChapter(
                    index: 0,
                    startSeconds: 0,
                    endSeconds: 6,
                    title: "开场",
                    summary: "开场章节摘要。"
                ),
                LensChapter(
                    index: 1,
                    startSeconds: 6,
                    endSeconds: 12.5,
                    title: "演示",
                    summary: "演示章节摘要。"
                )
            ],
            sensitiveFindings: [
                LensSensitiveFinding(
                    kind: .emailAddress,
                    source: .transcript,
                    startSeconds: 3.1,
                    endSeconds: 5.6,
                    redactedPreview: "a***@example.com",
                    occurrenceCount: 2
                )
            ],
            customization: LensInsightsCustomization(
                title: "人工校正后的标题",
                summary: "人工校正后的摘要。",
                tags: ["校正"]
            )
        )
    }

    // MARK: - Registry

    /// Encodes every portable document with `encoder`, in the same order as
    /// `LensProjectSchema.portableDocuments`.
    public static func encodeAll(
        with encoder: JSONEncoder
    ) throws -> [(name: String, data: Data)] {
        [
            ("manifest.json", try encoder.encode(manifest())),
            ("edit-plan.json", try encoder.encode(autoEditPlan())),
            ("screenshot-edit.json", try encoder.encode(screenshotEditPlan())),
            ("segments.json", try encoder.encode(recordingSegments())),
            ("scrolling-capture.json", try encoder.encode(scrollingCapture())),
            ("ocr.json", try encoder.encode(ocr())),
            ("transcript.json", try encoder.encode(transcript())),
            ("insights.json", try encoder.encode(insights()))
        ]
    }

    /// On-disk form: byte-identical to what `LensProjectStore` writes.
    public static func all() throws -> [(name: String, data: Data)] {
        try encodeAll(with: canonicalEncoder())
    }

    /// Cross-language conformance form. Filenames gain a `.compact.json` suffix.
    public static func allCompact() throws -> [(name: String, data: Data)] {
        try encodeAll(with: canonicalCompactEncoder()).map { document in
            (
                name: document.name.replacingOccurrences(
                    of: ".json",
                    with: ".compact.json"
                ),
                data: document.data
            )
        }
    }
}
